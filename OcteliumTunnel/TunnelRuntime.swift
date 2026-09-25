import Foundation
import LibOctelium
import NetworkExtension
import OcteliumCore
import OcteliumProto

let tunnelStartTimeout: Duration = .seconds(60)
let tunnelStopTimeout: Duration = .seconds(10)

actor TunnelRuntime {
    private weak var provider: NEPacketTunnelProvider?
    private let domain: String
    private let logStore = LogStore(capacity: maxTunnelLogs)

    private var lib: LibOctelium?
    private var client: LocalClient?
    private var status: Daemonv1.GetStatusResponse?
    private var pathMonitor: PathMonitor?
    private var networkReporter: NetworkStateReporter?
    private var networkTask: Task<Void, Never>?
    private var connectOperationID: String?
    private var startCompletion: ((Error?) -> Void)?
    private var startTimeoutTask: Task<Void, Never>?
    private var isStarted = false
    private var isShutdown = false

    init(provider: NEPacketTunnelProvider, domain: String) {
        self.provider = provider
        self.domain = domain
    }

    func start(_ completion: @escaping (Error?) -> Void) async {
        startCompletion = completion

        do {
            try await doStart()
        } catch {
            Log.tunnel.error("Could not start the tunnel: \(getErrorMessage(error), privacy: .public)")
            await finishStart(getStartError(error))
        }
    }

    func stop() async {
        if startCompletion != nil {
            await finishStart(getTunnelError(.connectionFailed, "The VPN was stopped before the Connection was established"))
        }

        await shutdown()
    }

    func wake() async {
        guard let pathMonitor else {
            return
        }

        await networkReporter?.update(getNetworkState(pathMonitor.current))
    }

    func handleMessage(_ msg: TunnelMessage) async -> Data? {
        switch msg {
        case .getStatus:
            if let client, let ret = try? await client.getStatus() {
                await handleStatus(ret)
            }

            guard let status else {
                return Data()
            }

            let ret: Data? = try? status.serializedBytes()
            return ret
        case .getLogs:
            return try? encodeLogs(logStore.logs)
        }
    }

    nonisolated func onEvent(_ data: Data) {
        guard let ev = try? Mobilev1.Event(serializedBytes: data) else {
            return
        }

        switch ev.type {
        case .log(let log):
            logStore.add(log)
            writeLibLog(log)
        case .status(let arg):
            Task {
                await self.handleStatus(arg)
            }
        case nil:
            break
        }
    }

    private func doStart() async throws {
        let stateDir = try AppGroup.getStateDir()
        let store = AppGroup.getSecretStore()
        let stateKey = try StateKeyStore(store: store, stateDir: stateDir).get()

        guard let deviceID = try InstallationID(store: store).get() else {
            throw getTunnelError(
                .stateUnavailable,
                "The installation ID of this device does not exist. Open Octelium in order to set it up"
            )
        }

        guard let provider else {
            throw getTunnelError(.internalError, "The packet tunnel provider is not available")
        }

        let callbacks = RuntimeCallbacks { [weak self] data in
            self?.onEvent(data)
        }

        let cfg = getLibConfig(
            stateDir: stateDir,
            stateKey: stateKey,
            deviceID: deviceID,
            deviceName: AppGroup.defaults.string(forKey: AppGroup.deviceNameKey) ?? "iPhone",
            logLevel: getDefaultLogLevel()
        )

        let lib = try LibOctelium.create(cfg, callbacks)
        callbacks.setRequestHandler(
            PlatformRequestHandler(host: TunnelSettingsHost(provider: provider), completer: lib, domain: domain)
        )

        if isShutdown {
            await closeLib(lib)
            return
        }

        self.lib = lib

        let client = LocalClient(lib)
        self.client = client

        let info = try await client.getInfo()
        if let msg = checkInfo(info) {
            throw getTunnelError(.libraryUnavailable, msg)
        }

        Log.tunnel.info("Starting liboctelium \(info.version, privacy: .public)")

        if isShutdown {
            return
        }

        startTimeout()
        await startPathMonitor(client)

        if isShutdown {
            return
        }

        let op = try await client.connect(domain)
        connectOperationID = op.id

        if let ret = try? await client.getStatus() {
            await handleStatus(ret)
        }
    }

    private func getStartError(_ err: Error) -> Error {
        if (err as NSError).domain == tunnelErrorDomain {
            return err
        }

        switch err {
        case let err as StateKeyUnavailableError:
            return getTunnelError(.stateUnavailable, err.message)
        case let err as LibraryUnavailableError:
            return getTunnelError(.libraryUnavailable, err.message)
        case let err as StatusError:
            switch err.code {
            case .unauthenticated, .notFound:
                return getTunnelError(.authenticationRequired, err.message)
            case .invalidArgument:
                return getTunnelError(.invalidConfiguration, err.message)
            case .failedPrecondition, .unavailable:
                return getTunnelError(.connectionFailed, err.message)
            default:
                return getTunnelError(.internalError, err.message)
            }
        default:
            return getTunnelError(.internalError, getErrorMessage(err))
        }
    }

    private func startPathMonitor(_ client: LocalClient) async {
        let reporter = NetworkStateReporter { state in
            do {
                _ = try await client.setNetworkState(state)
                return true
            } catch {
                Log.tunnel.warning("Could not set the network state: \(getErrorMessage(error), privacy: .public)")
                return false
            }
        }
        networkReporter = reporter

        let monitor = PathMonitor()
        pathMonitor = monitor

        var updates = monitor.start().makeAsyncIterator()
        if let info = await updates.next() {
            await reporter.update(getNetworkState(info))
        }

        networkTask = Task { [updates] in
            var updates = updates
            while let info = await updates.next() {
                await reporter.update(getNetworkState(info))
            }
        }
    }

    private func startTimeout() {
        startTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: tunnelStartTimeout)
            if Task.isCancelled {
                return
            }

            await self?.onStartTimeout()
        }
    }

    private func onStartTimeout() async {
        guard startCompletion != nil else {
            return
        }

        if let err = getLastError(getDomainState(status, domain)) {
            await finishStart(getTunnelError(getTunnelErrorCode(err), err.message))
            return
        }

        await finishStart(getTunnelError(.startTimeout, "Timed out waiting for the Connection to be established"))
    }

    private func handleStatus(_ arg: Daemonv1.GetStatusResponse) async {
        guard shouldReplaceStatus(status, arg) else {
            return
        }

        status = arg
        DarwinNotification.post(AppGroup.tunnelStatusNotification)

        let state = getDomainState(arg, domain)

        if startCompletion != nil {
            if state?.connection.state == .connected {
                await finishStart(nil)
                return
            }

            if let op = getLastOperation(state), op.id == connectOperationID,
               op.state == .failed || op.state == .canceled {
                let err = op.hasError ? op.error : nil
                await finishStart(
                    getTunnelError(getTunnelErrorCode(err), err?.message ?? "The Connection could not be established")
                )
            }

            return
        }

        guard isStarted, !isShutdown else {
            return
        }

        switch state?.connection.state {
        case .connecting, .reconnecting:
            provider?.reasserting = true
        case .connected:
            provider?.reasserting = false
        case .disconnecting:
            break
        default:
            let err = getLastError(state)
            Log.tunnel.info("The Connection was closed: \(err?.message ?? "", privacy: .public)")
            provider?.cancelTunnelWithError(
                getTunnelError(getTunnelErrorCode(err), err?.message ?? "The Connection was closed")
            )
        }
    }

    private func finishStart(_ err: Error?) async {
        guard let completion = startCompletion else {
            return
        }

        startCompletion = nil
        startTimeoutTask?.cancel()
        startTimeoutTask = nil

        if let err {
            completion(err)
            await shutdown()
            return
        }

        isStarted = true
        Log.tunnel.info("The tunnel is established")
        completion(nil)
    }

    private func shutdown() async {
        if isShutdown {
            return
        }

        isShutdown = true
        startTimeoutTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        networkTask?.cancel()
        networkTask = nil
        networkReporter = nil

        guard let lib, let client else {
            return
        }

        if connectOperationID != nil {
            do {
                _ = try await client.disconnect(domain)
                await waitForDisconnected()
            } catch {
                Log.tunnel.warning("Could not disconnect: \(getErrorMessage(error), privacy: .public)")
            }
        }

        self.client = nil
        self.lib = nil

        await closeLib(lib)
    }

    private func waitForDisconnected() async {
        let deadline = ContinuousClock.now + tunnelStopTimeout

        while ContinuousClock.now < deadline {
            if !isConnectionActive(getDomainState(status, domain)) {
                return
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
