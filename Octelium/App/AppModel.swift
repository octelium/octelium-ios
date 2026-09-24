import Foundation
import LibOctelium
import Observation
import OcteliumAPI
import OcteliumCore
import OcteliumProto
import Synchronization
import UIKit

enum RuntimeState: Equatable {
    case loading
    case ready
    case failed(message: String, isResettable: Bool)
}

struct StateOpenError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

let tunnelReleaseTimeout: Duration = .seconds(10)

private final class ClientHolder: Sendable {
    private let state = Mutex<LocalClient?>(nil)

    var client: LocalClient? {
        state.withLock { $0 }
    }

    func set(_ arg: LocalClient?) {
        state.withLock { $0 = arg }
    }

    func getCredential(_ domain: String) async throws -> Daemonv1.GetAPICredentialResponse {
        guard let client else {
            throw StatusError(.unavailable, "liboctelium is not available")
        }

        return try await client.getAPICredential(domain)
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var runtimeState: RuntimeState = .loading
    private(set) var info: Mobilev1.GetInfoResponse?
    private(set) var appStatus: Daemonv1.GetStatusResponse?
    private(set) var tunnel = TunnelSnapshot()
    private(set) var logs: [Mobilev1.Log] = []
    private(set) var prefs: Prefs
    private(set) var selectedDomain: String?
    private(set) var networkInfo: NetworkInfo?
    private(set) var authCallbackError: String?
    private(set) var isCompletingAuthentication = false
    private(set) var isOnDemandEnabled = false

    var status: Daemonv1.GetStatusResponse? {
        mergeStatus(appStatus, tunnel)
    }

    var isOffline: Bool {
        guard let networkInfo else {
            return false
        }

        return !getNetworkState(networkInfo).isAvailable
    }

    var authCallbackScheme: String? {
        info.flatMap { parseURI($0.authenticationCallbackURL)?.scheme }
    }

    @ObservationIgnored let cluster: ClusterClient

    @ObservationIgnored private let holder: ClientHolder
    @ObservationIgnored private let prefsStore = PrefsStore()
    @ObservationIgnored private let vpn: VPNController
    @ObservationIgnored private let pathMonitor = PathMonitor()
    @ObservationIgnored private var lib: LibOctelium?
    @ObservationIgnored private var statusStore: StatusStore?
    @ObservationIgnored private var logStore: LogStore?
    @ObservationIgnored private var pendingOperationID: String?
    @ObservationIgnored private var tunnelObserver: DarwinObserver?
    @ObservationIgnored private var sessionKeys: [String: String] = [:]
    @ObservationIgnored private var isStarted = false

    init() {
        let holder = ClientHolder()
        self.holder = holder
        self.vpn = VPNController()
        self.prefs = PrefsStore().get()
        self.cluster = ClusterClient(credentials: { try await holder.getCredential($0) })
    }

    func start() {
        if isStarted {
            return
        }

        isStarted = true

        AppGroup.defaults.set(UIDevice.current.name, forKey: AppGroup.deviceNameKey)

        pathMonitor.start { [weak self] info in
            Task { @MainActor in
                self?.networkInfo = info
            }
        }

        vpn.onChange = { [weak self] in
            Task {
                await self?.refreshTunnel()
            }
        }

        tunnelObserver = DarwinObserver(name: tunnelStatusNotification) { [weak self] in
            Task { @MainActor in
                await self?.refreshTunnel()
            }
        }

        Task {
            await vpn.load()
            await startRuntime()
        }
    }

    func onActive() {
        guard isStarted else {
            return
        }

        Task {
            await vpn.load()
            await refreshAppStatus()
            await refreshTunnel()
        }
    }

    func retryStart() {
        Task {
            await startRuntime()
        }
    }

    func resetState() {
        Task {
            runtimeState = .loading

            if let domain = vpn.domain {
                try? await releaseTunnel(domain)
            }

            await stopRuntime()
            cluster.close()
            selectDomain(nil)

            do {
                let stateDir = try AppGroup.getStateDir()
                try StateKeyStore(store: AppGroup.getSecretStore(), stateDir: stateDir).reset()
            } catch {
                Log.app.error("Could not reset the local state: \(getErrorMessage(error), privacy: .public)")
            }

            await startRuntime()
        }
    }

    private func startRuntime() async {
        await stopRuntime()

        runtimeState = .loading

        let statusStore = StatusStore { [weak self] in
            Task { @MainActor in
                self?.onAppStatusChange()
            }
        }

        let logStore = LogStore { [weak self] in
            Task { @MainActor in
                self?.onLogsChange()
            }
        }

        let handler = EventHandler(statusStore: statusStore, logStore: logStore) { writeLibLog($0) }
        let callbacks = RuntimeCallbacks { data in
            handler.handle(data)
        }

        self.statusStore = statusStore
        self.logStore = logStore

        let deviceName = UIDevice.current.name

        do {
            let lib = try await Task.detached(priority: .userInitiated) {
                try createLib(deviceName: deviceName, callbacks: callbacks)
            }.value

            self.lib = lib

            let client = LocalClient(lib)
            let info = try await client.getInfo()

            if let msg = checkInfo(info) {
                runtimeState = .failed(message: msg, isResettable: false)
                return
            }

            self.info = info
            holder.set(client)

            statusStore.update(try await client.getStatus())
            onAppStatusChange()

            runtimeState = .ready

            await refreshTunnel()
        } catch let err as StateKeyUnavailableError {
            Log.app.error("Could not get the state key: \(err.message, privacy: .public)")
            runtimeState = .failed(
                message: "The local Octelium state cannot be decrypted on this device. \(err.message)",
                isResettable: !err.isLocked
            )
        } catch let err as StateOpenError {
            runtimeState = .failed(message: err.message, isResettable: true)
        } catch {
            Log.app.error("Could not start liboctelium: \(getErrorMessage(error), privacy: .public)")
            runtimeState = .failed(message: getErrorMessage(error), isResettable: false)
        }
    }

    private func stopRuntime() async {
        holder.set(nil)

        if let lib {
            self.lib = nil
            await closeLib(lib)
        }

        statusStore = nil
        logStore = nil
        appStatus = nil
        info = nil
        logs = []
        sessionKeys = [:]
    }

    private func getClient() throws -> LocalClient {
        guard let ret = holder.client else {
            throw StatusError(.unavailable, "liboctelium is not available")
        }

        return ret
    }

    private func onAppStatusChange() {
        guard let status = statusStore?.status else {
            return
        }

        appStatus = status

        let keys = getSessionKeys(status)
        for domain in getChangedSessions(sessionKeys, keys) {
            cluster.invalidate(domain)
        }
        sessionKeys = keys

        let next = resolveSelectedDomain(prefs.primaryDomain, self.status, selectedDomain)
        if next != selectedDomain {
            selectedDomain = next
            if prefs.primaryDomain == nil, let next {
                setPrimaryDomain(next)
            }
        }
    }

    private func onLogsChange() {
        logs = logStore?.logs ?? []
    }

    func refreshAppStatus() async {
        guard let client = holder.client, let status = try? await client.getStatus() else {
            return
        }

        statusStore?.update(status)
    }

    func refreshTunnel() async {
        let state = vpn.state
        let domain = vpn.domain
        let previous = tunnel

        isOnDemandEnabled = vpn.isOnDemandEnabled

        var next = TunnelSnapshot(domain: domain, state: state)

        if isVPNActive(state) {
            if let data = await vpn.sendMessage(.getStatus), !data.isEmpty,
               let status = try? Daemonv1.GetStatusResponse(serializedBytes: data) {
                next.status = status
            } else if previous.domain == domain {
                next.status = previous.status
            }
        } else if previous.domain == domain {
            next.error = previous.error

            if isVPNActive(previous.state), let err = await vpn.fetchLastDisconnectError() {
                next.error = getDaemonError(err)
            }
        }

        tunnel = next
        onAppStatusChange()
    }

    func fetchTunnelLogs() async -> [Mobilev1.Log] {
        guard let data = await vpn.sendMessage(.getLogs) else {
            return []
        }

        return (try? decodeLogs(data)) ?? []
    }

    func selectDomain(_ domain: String?) {
        selectedDomain = domain
        setPrimaryDomain(domain)
    }

    func setTheme(_ arg: ThemeMode) {
        prefsStore.setTheme(arg)
        prefs.theme = arg
    }

    func setMultiCluster(_ arg: Bool) {
        prefsStore.setMultiCluster(arg)
        prefs.multiCluster = arg
    }

    private func setPrimaryDomain(_ arg: String?) {
        prefsStore.setPrimaryDomain(arg)
        prefs.primaryDomain = arg
    }

    private func clearTunnelError(_ domain: String) {
        if tunnel.domain == domain && tunnel.error != nil {
            tunnel.error = nil
        }
    }

    func checkClusterAPIHost(_ domain: String) async -> HostCheck {
        await resolveHost(getClusterAPIHost(domain))
    }

    func authenticateBrowser(_ domain: String) async throws -> Daemonv1.Operation {
        let client = try getClient()

        let check = await checkClusterAPIHost(domain)
        if check.resolution == .notFound, let msg = getHostCheckError(check) {
            throw StatusError(.notFound, msg)
        }

        clearTunnelError(domain)

        let ret = try await client.authenticateBrowser(domain)
        pendingOperationID = ret.id
        await refreshAppStatus()
        selectDomain(ret.domain.isEmpty ? domain : ret.domain)

        return ret
    }

    func authenticateToken(_ domain: String, _ authenticationToken: String) async throws -> Daemonv1.Operation {
        let client = try getClient()

        clearTunnelError(domain)

        let ret = try await client.authenticateToken(domain, authenticationToken)
        await refreshAppStatus()
        selectDomain(ret.domain.isEmpty ? domain : ret.domain)

        return ret
    }

    func isCallbackURL(_ url: String) -> Bool {
        guard let info else {
            return false
        }

        return isAuthCallbackURL(url, info.authenticationCallbackURL)
    }

    func completeAuthentication(_ url: String) async throws -> Daemonv1.Operation {
        if !isCallbackURL(url) {
            throw StatusError(.invalidArgument, "The authentication callback is invalid")
        }

        let client = try getClient()
        let status = try await client.getStatus()
        statusStore?.update(status)

        let candidates = getAuthCallbackCandidates(status, pendingOperationID)
        if candidates.isEmpty {
            throw StatusError(
                .failedPrecondition,
                "There is no sign in waiting for the browser. It might have expired or Octelium was restarted in the meantime. Please sign in again."
            )
        }

        var lastErr: Error?

        for id in candidates {
            do {
                let ret = try await client.completeAuthentication(id, url)
                pendingOperationID = nil
                await refreshAppStatus()
                return ret
            } catch let err as StatusError {
                switch err.code {
                case .invalidArgument, .failedPrecondition, .notFound:
                    lastErr = err
                default:
                    throw err
                }
            }
        }

        throw lastErr ?? StatusError(.internal, "Could not complete the authentication")
    }

    func handleAuthCallback(_ url: URL) {
        let arg = url.absoluteString

        Task {
            authCallbackError = nil

            guard isCallbackURL(arg) else {
                return
            }

            isCompletingAuthentication = true
            defer {
                isCompletingAuthentication = false
            }

            do {
                _ = try await completeAuthentication(arg)
            } catch {
                authCallbackError = getErrorMessage(error)
            }
        }
    }

    func dismissAuthCallbackError() {
        authCallbackError = nil
    }

    func setAuthCallbackError(_ arg: String?) {
        authCallbackError = arg
    }

    func cancelAuthentication(_ domain: String) async {
        guard let op = getActiveOperation(getDomainState(appStatus, domain)), op.type == .authenticate else {
            return
        }

        do {
            try await cancelOperation(op)
        } catch {
            Log.app.warning("Could not cancel the authentication: \(getErrorMessage(error), privacy: .public)")
        }
    }

    func connect(_ domain: String) async throws {
        if let active = getTunnelDomainState(status), active.domain != domain {
            throw StatusError(
                .failedPrecondition,
                "The domain \(active.domain) is already connected. Only a single Cluster can be connected at a time on this device."
            )
        }

        clearTunnelError(domain)

        let autoConnect = getDomainState(appStatus, domain)?.settings.autoConnect ?? false
        try await vpn.connect(domain, onDemand: autoConnect)

        await refreshTunnel()
    }

    func disconnect(_ domain: String) async throws {
        guard vpn.domain == domain else {
            return
        }

        try await vpn.disconnect()
        await refreshTunnel()
    }

    func cancelOperation(_ op: Daemonv1.Operation) async throws {
        if op.type == .connect {
            try await disconnect(op.domain)
            return
        }

        let client = try getClient()
        _ = try await client.cancelOperation(op.id)
        await refreshAppStatus()
    }

    func logout(_ domain: String) async throws {
        try await releaseTunnel(domain)

        let client = try getClient()
        _ = try await client.logout(domain)
        cluster.invalidate(domain)
        await refreshAppStatus()
    }

    func deleteDomain(_ domain: String) async throws {
        try await releaseTunnel(domain)

        let client = try getClient()
        _ = try await client.deleteDomain(domain)
        cluster.invalidate(domain)

        if prefs.primaryDomain == domain {
            selectDomain(nil)
        }

        await refreshAppStatus()
    }

    func updateDomainSettings(_ domain: String, _ settings: Daemonv1.DomainSettings) async throws -> Daemonv1.DomainSettings {
        let client = try getClient()
        let ret = try await client.updateDomainSettings(domain, settings)
        await refreshAppStatus()

        do {
            try await syncOnDemand(ret.domain.isEmpty ? domain : ret.domain, autoConnect: ret.autoConnect)
        } catch {
            throw StatusError(
                .failedPrecondition,
                "The settings were saved but auto connect could not be updated: \(getErrorMessage(error))"
            )
        }

        return ret
    }

    private func syncOnDemand(_ domain: String, autoConnect: Bool) async throws {
        if autoConnect {
            if let current = vpn.domain, current != domain, isVPNActive(vpn.state) {
                return
            }

            try await vpn.setOnDemand(domain)
        } else if vpn.domain == domain {
            try await vpn.setOnDemand(nil)
        }

        await refreshTunnel()
    }

    private func releaseTunnel(_ domain: String) async throws {
        guard vpn.domain == domain else {
            return
        }

        if isVPNActive(vpn.state) || vpn.isOnDemandEnabled {
            try await vpn.disconnect()
        }

        let deadline = ContinuousClock.now + tunnelReleaseTimeout
        while isVPNActive(vpn.state) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        await refreshTunnel()
    }
}

private func createLib(deviceName: String, callbacks: RuntimeCallbacks) throws -> LibOctelium {
    let stateDir = try AppGroup.getStateDir()
    let store = AppGroup.getSecretStore()
    let stateKey = try StateKeyStore(store: store, stateDir: stateDir).getOrCreate()
    let deviceID = try InstallationID(store: store).getOrCreate()

    let cfg = getLibConfig(
        stateDir: stateDir,
        stateKey: stateKey,
        deviceID: deviceID,
        deviceName: deviceName,
        logLevel: getDefaultLogLevel()
    )

    do {
        return try LibOctelium.create(cfg, callbacks)
    } catch let err as LibraryUnavailableError {
        throw err
    } catch {
        throw StateOpenError(message: "Could not open the local Octelium state: \(getErrorMessage(error))")
    }
}
