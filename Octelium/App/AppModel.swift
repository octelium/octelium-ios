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
    @ObservationIgnored private var runtimeTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var networkReporter: NetworkStateReporter?
    @ObservationIgnored private var tunnelRefreshID = 0
    @ObservationIgnored private var lastAuthCallbackURL: String?

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

        AppGroup.defaults.set(getAppDeviceName(), forKey: AppGroup.deviceNameKey)

        let updates = pathMonitor.start()
        networkTask = Task { [weak self] in
            for await info in updates {
                await self?.setNetwork(info)
            }
        }

        vpn.onChange = { [weak self] in
            Task {
                await self?.refreshTunnel()
            }
        }

        tunnelObserver = DarwinObserver(name: AppGroup.tunnelStatusNotification) { [weak self] in
            Task { @MainActor in
                await self?.refreshTunnel()
            }
        }

        runRuntimeTransition {
            await self.vpn.load()
            await self.startRuntime()
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
        runRuntimeTransition {
            await self.startRuntime()
        }
    }

    func resetState() {
        runRuntimeTransition {
            await self.doResetState()
        }
    }

    private func runRuntimeTransition(_ fn: @escaping @MainActor () async -> Void) {
        let prev = runtimeTask
        runtimeTask = Task {
            await prev?.value
            await fn()
        }
    }

    private func doResetState() async {
        runtimeState = .loading

        if let domain = vpn.domain {
            do {
                try await releaseTunnel(domain)
            } catch {
                Log.app.error("Could not stop the VPN to reset the local state: \(getErrorMessage(error), privacy: .public)")
                runtimeState = .failed(
                    message: "Could not stop the VPN before resetting the local state. \(getErrorMessage(error))",
                    isResettable: true
                )
                return
            }

            do {
                try await vpn.remove()
            } catch {
                Log.app.warning("Could not remove the VPN configuration: \(getErrorMessage(error), privacy: .public)")
            }
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

        let deviceName = getAppDeviceName()

        let lib: LibOctelium
        do {
            lib = try await Task.detached(priority: .userInitiated) {
                try createLib(deviceName: deviceName, callbacks: callbacks)
            }.value
        } catch {
            failRuntime(error)
            return
        }

        callbacks.setRequestHandler(PlatformRequestHandler(host: UnsupportedTunnelHost(), completer: lib))

        let client = LocalClient(lib)

        do {
            let info = try await client.getInfo()
            if let msg = checkInfo(info) {
                await closeLib(lib)
                clearRuntime()
                runtimeState = .failed(message: msg, isResettable: false)
                return
            }

            let status = try await client.getStatus()

            self.lib = lib
            self.info = info
            holder.set(client)
            networkReporter = getNetworkReporter(client)
            statusStore.update(status)
            onAppStatusChange()
        } catch {
            await closeLib(lib)
            failRuntime(error)
            return
        }

        runtimeState = .ready

        if let networkInfo {
            await networkReporter?.update(getNetworkState(networkInfo))
        }

        await refreshTunnel()
    }

    private func failRuntime(_ err: Error) {
        clearRuntime()

        switch err {
        case let err as StateKeyUnavailableError:
            Log.app.error("Could not get the state key: \(err.message, privacy: .public)")
            runtimeState = .failed(
                message: "The local Octelium state cannot be decrypted on this device. \(err.message)",
                isResettable: !err.isLocked
            )
        case let err as StateOpenError:
            runtimeState = .failed(message: err.message, isResettable: true)
        default:
            Log.app.error("Could not start liboctelium: \(getErrorMessage(err), privacy: .public)")
            runtimeState = .failed(message: getErrorMessage(err), isResettable: false)
        }
    }

    private func stopRuntime() async {
        holder.set(nil)
        networkReporter = nil

        if let lib {
            self.lib = nil
            await closeLib(lib)
        }

        clearRuntime()
    }

    private func clearRuntime() {
        statusStore = nil
        logStore = nil
        appStatus = nil
        info = nil
        logs = []
        sessionKeys = [:]
    }

    private func getNetworkReporter(_ client: LocalClient) -> NetworkStateReporter {
        NetworkStateReporter { state in
            do {
                _ = try await client.setNetworkState(state)
                return true
            } catch {
                Log.app.warning("Could not set the network state: \(getErrorMessage(error), privacy: .public)")
                return false
            }
        }
    }

    private func setNetwork(_ info: NetworkInfo) async {
        networkInfo = info
        await networkReporter?.update(getNetworkState(info))
    }

    private func getAppDeviceName() -> String {
        getDeviceName(name: UIDevice.current.name, model: UIDevice.current.model, machine: getDeviceModel())
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
        tunnelRefreshID += 1
        let id = tunnelRefreshID

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

        guard id == tunnelRefreshID else {
            return
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

        guard isCallbackURL(arg), !isCompletingAuthentication, arg != lastAuthCallbackURL else {
            return
        }

        lastAuthCallbackURL = arg
        authCallbackError = nil
        isCompletingAuthentication = true

        Task {
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
        let isOnDemand = isOnDemandTarget(domain)
        try await releaseTunnel(domain)

        let client = try getClient()
        _ = try await client.logout(domain)
        cluster.invalidate(domain)
        await refreshAppStatus()

        if isOnDemand {
            await restoreOnDemand(excluding: domain)
        }
    }

    func deleteDomain(_ domain: String) async throws {
        let isOnDemand = isOnDemandTarget(domain)
        try await releaseTunnel(domain)

        let client = try getClient()
        _ = try await client.deleteDomain(domain)
        cluster.invalidate(domain)

        if prefs.primaryDomain == domain {
            selectDomain(nil)
        }

        await refreshAppStatus()

        if isOnDemand {
            await restoreOnDemand(excluding: domain)
        }
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
            let isOnDemand = vpn.isOnDemandEnabled
            try await vpn.setOnDemand(nil)

            if isOnDemand {
                await restoreOnDemand(excluding: domain)
            }
        }

        await refreshTunnel()
    }

    private func isOnDemandTarget(_ domain: String) -> Bool {
        vpn.domain == domain && vpn.isOnDemandEnabled
    }

    private func restoreOnDemand(excluding domain: String) async {
        guard !isVPNActive(vpn.state), let target = getOnDemandDomain(appStatus, prefs.primaryDomain, excluding: domain) else {
            return
        }

        do {
            try await vpn.setOnDemand(target)
        } catch {
            Log.app.warning("Could not enable auto connect for \(target, privacy: .public): \(getErrorMessage(error), privacy: .public)")
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

        if isVPNActive(vpn.state) {
            throw StatusError(.deadlineExceeded, "Timed out waiting for the VPN of \(domain) to disconnect")
        }
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
