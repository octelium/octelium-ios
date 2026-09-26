import Foundation
import OcteliumCore
import OcteliumProto
import SwiftProtobuf
import Synchronization

public enum ConnectEvent: Sendable {
    case connecting((any Error)?)
    case connected(Connection)
    case reconnecting((any Error)?, Connection?)
}

private struct TryConnectResult {
    var err: (any Error)?
    var needsReconnect = false
    var isConnected = false
}

private enum SessionEvent: Sendable {
    case response(Userv1.ConnectResponse)
    case closed((any Error)?)
    case status(TunnelStatus)
    case stateTimeout
}

final class Connector: Sendable {
    private let domain: String
    private let opts: ConnectOptions
    private let channel: @Sendable () throws -> any ClusterChannel
    private let credentials: @Sendable () async throws -> String
    private let tunnels: TunnelFactory
    private let host: any TunnelHost
    private let network: NetworkWatcher
    private let logger: LogWriter
    private let onEvent: @Sendable (ConnectEvent) -> Void
    private let stateTimeout: Duration
    private let keepAliveInterval: Duration

    init(
        domain: String,
        opts: ConnectOptions,
        channel: @escaping @Sendable () throws -> any ClusterChannel,
        credentials: @escaping @Sendable () async throws -> String,
        tunnels: @escaping TunnelFactory,
        host: any TunnelHost,
        network: NetworkWatcher,
        logger: LogWriter,
        onEvent: @escaping @Sendable (ConnectEvent) -> Void,
        stateTimeout: Duration = .seconds(20),
        keepAliveInterval: Duration = .seconds(300)
    ) {
        self.domain = domain
        self.opts = opts
        self.channel = channel
        self.credentials = credentials
        self.tunnels = tunnels
        self.host = host
        self.network = network
        self.logger = logger
        self.onEvent = onEvent
        self.stateTimeout = stateTimeout
        self.keepAliveInterval = keepAliveInterval
    }

    func run() async throws {
        try Task.checkCancellation()

        onEvent(.connecting(nil))

        let handler = Handler(domain: domain, host: host, credentials: credentials, logger: logger)
        let tunnel = try tunnels(handler)
        handler.setTunnel(tunnel)

        let network = self.network
        let networkTask = Task {
            for await itm in network.updates() {
                tunnel.setNetworkState(itm)
            }
        }

        defer {
            networkTask.cancel()
            handler.close()
            tunnel.close()
        }

        try await doRun(tunnel, handler)
    }

    private func doRun(_ tunnel: any Tunnel, _ handler: Handler) async throws {
        var isConnected = false
        var attempt = 0

        while true {
            let ret = await tryConnect(tunnel, handler, wasConnected: isConnected)
            try Task.checkCancellation()

            if !ret.needsReconnect {
                if let err = ret.err {
                    throw err
                }
                return
            }

            if ret.isConnected {
                isConnected = true
                attempt = 0
            }

            onEvent(isConnected ? .reconnecting(ret.err, nil) : .connecting(ret.err))

            if let err = ret.err {
                logger.warn("Could not connect to the domain \(domain): \(getErrorMessage(err)). Reconnecting...")
            }

            attempt += 1
            await network.waitReconnect(attempt)
            try Task.checkCancellation()
        }
    }

    private func tryConnect(_ tunnel: any Tunnel, _ handler: Handler, wasConnected: Bool) async -> TryConnectResult {
        let token: String
        do {
            token = try await credentials()
        } catch {
            return TryConnectResult(err: error, needsReconnect: needsReconnect(error))
        }

        do {
            return try await doTryConnect(token, tunnel, handler, wasConnected: wasConnected)
        } catch {
            return TryConnectResult(err: error, needsReconnect: needsReconnect(error))
        }
    }

    private func doTryConnect(
        _ token: String,
        _ tunnel: any Tunnel,
        _ handler: Handler,
        wasConnected: Bool
    ) async throws -> TryConnectResult {
        let channel = try self.channel()
        let (events, eventsCont) = AsyncStream.makeStream(of: SessionEvent.self)
        let (requests, requestsCont) = AsyncStream.makeStream(of: Userv1.ConnectRequest.self)

        logger.debug("Connecting to the Cluster API of the domain \(domain)")

        requestsCont.yield(getInitializeRequest(opts))
        handler.reset()

        let streamTask = Task {
            do {
                try await channel.connect(accessToken: token, requests: requests) { msg in
                    eventsCont.yield(.response(msg))
                }
                eventsCont.yield(.closed(nil))
            } catch {
                eventsCont.yield(.closed(error))
            }
        }

        let stateTimeout = self.stateTimeout
        let timeoutTask = Task {
            try await Task.sleep(for: stateTimeout)
            eventsCont.yield(.stateTimeout)
        }

        var keepAliveTask: Task<Void, Never>?
        var tunnelStatus = handler.subscribe(eventsCont)

        defer {
            streamTask.cancel()
            timeoutTask.cancel()
            keepAliveTask?.cancel()
            handler.unsubscribe()
            requestsCont.finish()
            eventsCont.finish()
        }

        var iter = events.makeAsyncIterator()
        var initial: Userv1.ConnectResponse?

        waitLoop: while let ev = await iter.next() {
            switch ev {
            case .response(let msg):
                if case .state = msg.event {
                    initial = msg
                    break waitLoop
                }
                logger.debug("Found an initial message that is not a state")
            case .closed(let err):
                throw err ?? getClosedError(nil)
            case .status(let arg):
                tunnelStatus = arg
            case .stateTimeout:
                throw ConnectionClosedError("Could not get the initial state message after a timeout")
            }
        }

        try Task.checkCancellation()

        guard let initial else {
            throw getClosedError(nil)
        }

        timeoutTask.cancel()

        let initAt = initial.hasCreatedAt ? initial.createdAt.date : nil
        var state = initial.state

        try tunnel.setConfig(getTunnelConfig(state))

        let keepAliveInterval = self.keepAliveInterval
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: keepAliveInterval)
                if Task.isCancelled {
                    return
                }

                requestsCont.yield(getKeepAliveRequest())
            }
        }

        var isConnected = false

        func onStatus(_ arg: TunnelStatus) -> TryConnectResult? {
            tunnelStatus = arg

            let err = arg.error.map { TunnelError($0, arg.message) }

            switch arg.state {
            case .connected:
                if !isConnected {
                    logger.info("Connected to the domain \(domain)")
                }
                isConnected = true
                onEvent(.connected(getConnection(state, handler)))
            case .connecting, .reconnecting:
                if isConnected {
                    onEvent(.reconnecting(err, getConnection(state, handler)))
                } else if let err {
                    onEvent(wasConnected ? .reconnecting(err, nil) : .connecting(err))
                }
            case .failed:
                return TryConnectResult(
                    err: err ?? TunnelError(.internal, "The tunnel could not be established"),
                    needsReconnect: true,
                    isConnected: isConnected
                )
            case .idle:
                break
            }

            return nil
        }

        if let ret = onStatus(tunnelStatus) {
            return ret
        }

        while let ev = await iter.next() {
            switch ev {
            case .status(let arg):
                if let ret = onStatus(arg) {
                    return ret
                }
            case .closed(let err):
                return TryConnectResult(err: getClosedError(err), needsReconnect: true, isConnected: isConnected)
            case .stateTimeout:
                break
            case .response(let msg):
                if shouldSkipResponse(msg, initAt) {
                    logger.debug("Skipping an old response message")
                    continue
                }

                if case .disconnect = msg.event {
                    logger.info("Disconnected by the Cluster of the domain \(domain)")
                    return TryConnectResult(isConnected: isConnected)
                }

                guard let next = reduceConnectionState(state, msg) else {
                    continue
                }

                state = next

                do {
                    try tunnel.setConfig(getTunnelConfig(state))
                } catch {
                    logger.error("Could not handle the state: \(getErrorMessage(error))")
                }

                if isConnected && tunnelStatus.state == .connected {
                    onEvent(.connected(getConnection(state, handler)))
                }
            }
        }

        try Task.checkCancellation()

        return TryConnectResult(err: getClosedError(nil), needsReconnect: true, isConnected: isConnected)
    }

    private func getTunnelConfig(_ state: Userv1.ConnectionState) -> TunnelConfig {
        TunnelConfig(
            domain: domain,
            state: state,
            preferences: TunnelPreferences(tunnelMode: opts.tunnelMode, dnsMode: opts.dnsMode, mtu: opts.mtu)
        )
    }

    private func getConnection(_ state: Userv1.ConnectionState, _ handler: Handler) -> Connection {
        Connection(state: state, tunnelMode: opts.tunnelMode, dnsMode: opts.dnsMode, mtu: Int32(handler.mtu))
    }
}

private final class Handler: TunnelHandler {
    private struct State {
        var tunnel: (any Tunnel)?
        var status = TunnelStatus(state: .idle)
        var sink: AsyncStream<SessionEvent>.Continuation?
        var mtu = 0
        var tasks: [UInt64: Task<Void, Never>] = [:]
        var nextTaskID: UInt64 = 0
        var isClosed = false
    }

    private let domain: String
    private let platform: PlatformRequestHandler
    private let credentials: @Sendable () async throws -> String
    private let logger: LogWriter
    private let state = Mutex(State())

    init(
        domain: String,
        host: any TunnelHost,
        credentials: @escaping @Sendable () async throws -> String,
        logger: LogWriter
    ) {
        self.domain = domain
        self.platform = PlatformRequestHandler(host: host)
        self.credentials = credentials
        self.logger = logger
    }

    var mtu: Int {
        state.withLock { $0.mtu }
    }

    func setTunnel(_ arg: any Tunnel) {
        state.withLock { $0.tunnel = arg }
    }

    func reset() {
        state.withLock { st in
            if st.status.state == .idle || st.status.state == .failed {
                st.status = TunnelStatus(state: .connecting)
            }
        }
    }

    func subscribe(_ sink: AsyncStream<SessionEvent>.Continuation) -> TunnelStatus {
        state.withLock { st in
            st.sink = sink
            return st.status
        }
    }

    func unsubscribe() {
        state.withLock { $0.sink = nil }
    }

    func close() {
        let tasks = state.withLock { st in
            st.isClosed = true
            st.sink = nil
            st.tunnel = nil

            let ret = Array(st.tasks.values)
            st.tasks.removeAll()
            return ret
        }

        for itm in tasks {
            itm.cancel()
        }
    }

    func onStatus(_ status: TunnelStatus) {
        let sink = state.withLock { st in
            st.status = status
            return st.sink
        }

        sink?.yield(.status(status))
    }

    func onLog(_ log: LogEntry) {
        logger.log(log)
    }

    func onRequest(_ requestID: UInt64, _ request: TunnelRequest) {
        state.withLock { st in
            if st.isClosed {
                return
            }

            st.nextTaskID += 1
            let id = st.nextTaskID

            st.tasks[id] = Task {
                await self.handle(requestID, request)
                self.state.withLock { _ = $0.tasks.removeValue(forKey: id) }
            }
        }
    }

    private func handle(_ requestID: UInt64, _ request: TunnelRequest) async {
        let resp: TunnelResponse

        switch request {
        case .applyNetworkConfig(let cfg):
            state.withLock { $0.mtu = cfg.mtu }
            resp = await platform.applyNetworkConfig(domain, cfg)
        case .getAccessToken:
            resp = await getAccessTokenResponse()
        }

        _ = state.withLock { $0.tunnel }?.complete(requestID, resp)
    }

    private func getAccessTokenResponse() async -> TunnelResponse {
        do {
            let token = try await credentials()
            return .getAccessToken(token)
        } catch {
            let code: TunnelError.Code = if error is AuthenticationRequiredError {
                .unauthenticated
            } else {
                switch getStatusCode(error) {
                case .unauthenticated: .unauthenticated
                case .unavailable: .unavailable
                case .deadlineExceeded: .timeout
                default: .internal
                }
            }

            return .error(code, getErrorMessage(error))
        }
    }
}

private func getClosedError(_ err: (any Error)?) -> ConnectionClosedError {
    guard let err else {
        return ConnectionClosedError("The Connection was closed by the Cluster")
    }

    return ConnectionClosedError("Abruptly disconnected by the Cluster: \(getErrorMessage(err))", cause: err)
}

private func getKeepAliveRequest() -> Userv1.ConnectRequest {
    var ret = Userv1.ConnectRequest()
    ret.keepAlive.setAt = Google_Protobuf_Timestamp(date: Date())
    return ret
}

private func shouldSkipResponse(_ msg: Userv1.ConnectResponse, _ initAt: Date?) -> Bool {
    guard let initAt, msg.hasCreatedAt else {
        return false
    }

    return msg.createdAt.date < initAt
}

private func needsReconnect(_ err: any Error) -> Bool {
    switch getStatusCode(err) {
    case .invalidArgument, .permissionDenied, .notFound:
        false
    default:
        true
    }
}
