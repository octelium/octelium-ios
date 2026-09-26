import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import OcteliumCore
import OcteliumProto
import SwiftProtobuf
import Synchronization

@testable import OcteliumAPI

let testAuthenticationToken = "auth-token"

func getTestGateway(_ id: String, cidr: String = "fdee:1::/64") -> Userv1.Gateway {
    var ret = Userv1.Gateway()
    ret.id = id
    ret.hostname = "\(id).example.com"
    ret.addresses = ["192.0.2.1"]
    ret.cidrs = [cidr]
    ret.wireguard.port = 51820
    ret.wireguard.publicKey = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
    return ret
}

func getTestConnectionState() -> Userv1.ConnectionState {
    var ret = Userv1.ConnectionState()
    ret.mtu = 1280
    ret.x25519Key = Data(repeating: 1, count: 32)
    ret.l3Mode = .v6

    var address = Metav1.DualStackNetwork()
    address.v4 = "100.64.0.5/32"
    address.v6 = "fdee:1::5/128"
    ret.addresses = [address]

    ret.gateways = [getTestGateway("gw-1")]
    ret.dns.servers = ["fdee:1::53"]
    ret.cidr.v4 = "100.64.0.0/10"
    ret.cidr.v6 = "fdee:1::/64"
    return ret
}

private enum SessionMessage: Sendable {
    case response(Userv1.ConnectResponse)
    case close(RPCError?)
}

final class FakeCluster: Sendable {
    private struct State {
        var calls: [(String, Metadata)] = []
        var authenticateRequests: [Authv1.AuthenticateWithAuthenticationTokenRequest] = []
        var registerRequests: [Authv1.RegisterDeviceBeginRequest] = []
        var initRequests: [Userv1.ConnectRequest] = []
        var sessions: [AsyncStream<SessionMessage>.Continuation] = []
        var accessTokens: Set<String> = []
        var refreshTokens: Set<String> = []
        var expiresIn: Int64 = 3600
        var connectionState = getTestConnectionState()
        var userType: Userv1.GetStatusResponse.User.Spec.TypeEnum = .human
        var nextID = 0
    }

    private let state = Mutex(State())
    private let servers = Mutex<[GRPCServer<InProcessTransport.Server>]>([])

    var authenticateRequests: [Authv1.AuthenticateWithAuthenticationTokenRequest] {
        state.withLock { $0.authenticateRequests }
    }

    var registerRequests: [Authv1.RegisterDeviceBeginRequest] {
        state.withLock { $0.registerRequests }
    }

    var initRequests: [Userv1.ConnectRequest] {
        state.withLock { $0.initRequests }
    }

    var sessionCount: Int {
        state.withLock { $0.sessions.count }
    }

    var connectionState: Userv1.ConnectionState {
        state.withLock { $0.connectionState }
    }

    func setExpiresIn(_ arg: Int64) {
        state.withLock { $0.expiresIn = arg }
    }

    func clearRefreshTokens() {
        state.withLock { $0.refreshTokens.removeAll() }
    }

    func getCalls(_ method: String) -> [Metadata] {
        state.withLock { st in
            st.calls.filter { $0.0 == method }.map(\.1)
        }
    }

    func newChannel() -> any ClusterChannel {
        let transport = InProcessTransport()
        let server = GRPCServer(
            transport: transport.server,
            services: [FakeService(cluster: self)],
            interceptors: [FakeInterceptor(cluster: self)]
        )

        servers.withLock { $0.append(server) }

        Task {
            try? await server.serve()
        }

        return GRPCClusterChannel(transport: transport.client)
    }

    func send(_ arg: Userv1.ConnectResponse) {
        state.withLock { $0.sessions.last }?.yield(.response(arg))
    }

    func closeSession(_ err: RPCError?) {
        state.withLock { $0.sessions.last }?.yield(.close(err))
    }

    func close() {
        let servers = self.servers.withLock { $0 }
        for itm in servers {
            itm.beginGracefulShutdown()
        }
    }

    fileprivate func addCall(_ method: String, _ metadata: Metadata) {
        state.withLock { $0.calls.append((method, metadata)) }
    }

    fileprivate func isValidAccessToken(_ arg: String?) -> Bool {
        guard let arg else {
            return false
        }

        return state.withLock { $0.accessTokens.contains(arg) }
    }

    fileprivate func isValidRefreshToken(_ arg: String?) -> Bool {
        guard let arg else {
            return false
        }

        return state.withLock { $0.refreshTokens.contains(arg) }
    }

    fileprivate func issueSessionToken() -> Authv1.SessionToken {
        state.withLock { st in
            st.nextID += 1
            st.accessTokens.insert("access-\(st.nextID)")
            st.refreshTokens.insert("refresh-\(st.nextID)")

            var ret = Authv1.SessionToken()
            ret.accessToken = "access-\(st.nextID)"
            ret.refreshToken = "refresh-\(st.nextID)"
            ret.expiresIn = st.expiresIn
            ret.refreshTokenExpiresIn = 86400
            return ret
        }
    }

    fileprivate func authenticate(_ req: Authv1.AuthenticateWithAuthenticationTokenRequest) throws -> Authv1.SessionToken {
        state.withLock { $0.authenticateRequests.append(req) }

        if req.authenticationToken != testAuthenticationToken {
            throw RPCError(code: .unauthenticated, message: "Invalid authentication Token")
        }

        return issueSessionToken()
    }

    fileprivate func registerDeviceBegin(_ req: Authv1.RegisterDeviceBeginRequest) -> Authv1.RegisterDeviceBeginResponse {
        state.withLock { $0.registerRequests.append(req) }

        var ret = Authv1.RegisterDeviceBeginResponse()
        ret.uid = "register-1"
        return ret
    }

    fileprivate func getStatus() -> Userv1.GetStatusResponse {
        var ret = Userv1.GetStatusResponse()
        ret.user.metadata.name = "alice"
        ret.user.spec.type = state.withLock { $0.userType }
        return ret
    }

    fileprivate func connect(
        _ requests: RPCAsyncSequence<Userv1.ConnectRequest, any Error>,
        _ writer: RPCWriter<Userv1.ConnectResponse>
    ) async throws {
        let (events, cont) = AsyncStream.makeStream(of: SessionMessage.self)

        let initial = state.withLock { st in
            st.sessions.append(cont)

            var ret = Userv1.ConnectResponse()
            ret.state = st.connectionState
            ret.createdAt = Google_Protobuf_Timestamp(date: Date())
            return ret
        }

        let reader = Task {
            do {
                for try await req in requests {
                    self.state.withLock { $0.initRequests.append(req) }
                }
            } catch {
            }
        }

        defer {
            reader.cancel()
        }

        try await writer.write(initial)

        for await ev in events {
            switch ev {
            case .response(let msg):
                try await writer.write(msg)
            case .close(let err):
                if let err {
                    throw err
                }
                return
            }
        }
    }
}

private struct FakeService: RegistrableRPCService {
    let cluster: FakeCluster

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        let cluster = self.cluster

        registerUnary(&router, Octelium_Api_Main_Auth_V1_MainService.Method.AuthenticateWithAuthenticationToken.descriptor) {
            (req: Authv1.AuthenticateWithAuthenticationTokenRequest) in
            try cluster.authenticate(req)
        }

        registerUnary(&router, Octelium_Api_Main_Auth_V1_MainService.Method.AuthenticateWithRefreshToken.descriptor) {
            (_: Authv1.AuthenticateWithRefreshTokenRequest) in
            cluster.issueSessionToken()
        }

        registerUnary(&router, Octelium_Api_Main_Auth_V1_MainService.Method.Logout.descriptor) {
            (_: Authv1.LogoutRequest) in
            Authv1.LogoutResponse()
        }

        registerUnary(&router, Octelium_Api_Main_Auth_V1_MainService.Method.RegisterDeviceBegin.descriptor) {
            (req: Authv1.RegisterDeviceBeginRequest) in
            cluster.registerDeviceBegin(req)
        }

        registerUnary(&router, Octelium_Api_Main_Auth_V1_MainService.Method.RegisterDeviceFinish.descriptor) {
            (_: Authv1.RegisterDeviceFinishRequest) in
            Authv1.RegisterDeviceFinishResponse()
        }

        registerUnary(&router, Octelium_Api_Main_User_V1_MainService.Method.GetStatus.descriptor) {
            (_: Userv1.GetStatusRequest) in
            cluster.getStatus()
        }

        registerUnary(&router, Octelium_Api_Main_User_V1_MainService.Method.Disconnect.descriptor) {
            (_: Userv1.DisconnectRequest) in
            Userv1.DisconnectResponse()
        }

        router.registerHandler(
            forMethod: Octelium_Api_Main_User_V1_MainService.Method.Connect.descriptor,
            deserializer: ProtobufDeserializer<Userv1.ConnectRequest>(),
            serializer: ProtobufSerializer<Userv1.ConnectResponse>(),
            handler: { request, _ in
                StreamingServerResponse { writer in
                    try await cluster.connect(request.messages, writer)
                    return [:]
                }
            }
        )
    }
}

private func registerUnary<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message, Transport: ServerTransport>(
    _ router: inout RPCRouter<Transport>,
    _ descriptor: MethodDescriptor,
    _ fn: @escaping @Sendable (Input) async throws -> Output
) {
    router.registerHandler(
        forMethod: descriptor,
        deserializer: ProtobufDeserializer<Input>(),
        serializer: ProtobufSerializer<Output>(),
        handler: { request, _ in
            let req = try await ServerRequest(stream: request)
            let resp = try await fn(req.message)
            return StreamingServerResponse(single: ServerResponse(message: resp))
        }
    )
}

private struct FakeInterceptor: ServerInterceptor {
    let cluster: FakeCluster

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @Sendable (StreamingServerRequest<Input>, ServerContext) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        let method = context.descriptor.method
        cluster.addCall(method, request.metadata)

        let isValid = if context.descriptor.service.fullyQualifiedService == "octelium.api.main.user.v1.MainService" {
            cluster.isValidAccessToken(request.metadata[stringValues: authMetadataKey].first { _ in true })
        } else if method == "AuthenticateWithRefreshToken" {
            cluster.isValidRefreshToken(request.metadata[stringValues: refreshTokenMetadataKey].first { _ in true })
        } else {
            true
        }

        if !isValid {
            throw RPCError(code: .unauthenticated, message: "Invalid credentials")
        }

        return try await next(request, context)
    }
}

final class FakeTunnel: Tunnel {
    private struct State {
        var configs: [TunnelConfig] = []
        var networkStates: [NetworkState] = []
        var responses: [(UInt64, TunnelResponse)] = []
        var isClosed = false
        var nextID: UInt64 = 0
        var tunnelState = TunnelState.idle
        var applied: NetworkConfig?
    }

    private let handler: any TunnelHandler
    private let state = Mutex(State())

    init(_ handler: any TunnelHandler) {
        self.handler = handler
    }

    var configs: [TunnelConfig] {
        state.withLock { $0.configs }
    }

    var networkStates: [NetworkState] {
        state.withLock { $0.networkStates }
    }

    var responses: [(UInt64, TunnelResponse)] {
        state.withLock { $0.responses }
    }

    var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    func setConfig(_ config: TunnelConfig) throws {
        state.withLock { st in
            st.configs.append(config)

            if st.tunnelState == .idle || st.tunnelState == .failed {
                setStatusLocked(&st, TunnelStatus(state: .connecting))
            }

            st.nextID += 1
            let cfg = getNetworkConfig(config, st.nextID)

            if let applied = st.applied, getNetworkConfig(config, applied.generation) == applied {
                setStatusLocked(&st, TunnelStatus(state: .connected))
                return
            }

            handler.onRequest(st.nextID, .applyNetworkConfig(cfg))
        }
    }

    func setNetworkState(_ arg: NetworkState) {
        state.withLock { $0.networkStates.append(arg) }
    }

    func complete(_ requestID: UInt64, _ response: TunnelResponse) -> Int32 {
        state.withLock { st in
            if st.isClosed {
                return TunnelError.Code.notFound.rawValue
            }

            st.responses.append((requestID, response))

            switch response {
            case .applyNetworkConfig:
                if let config = st.configs.last {
                    st.applied = getNetworkConfig(config, requestID)
                }
                setStatusLocked(&st, TunnelStatus(state: .connected))
            case .error(let code, let message):
                if st.applied == nil {
                    setStatusLocked(&st, TunnelStatus(state: .failed, error: code, message: message))
                }
            case .getAccessToken:
                break
            }

            return 0
        }
    }

    func setStatus(_ arg: TunnelStatus) {
        state.withLock { setStatusLocked(&$0, arg) }
    }

    func requestAccessToken() -> UInt64 {
        state.withLock { st in
            st.nextID += 1
            handler.onRequest(st.nextID, .getAccessToken)
            return st.nextID
        }
    }

    func close() {
        state.withLock { $0.isClosed = true }
    }

    private func setStatusLocked(_ st: inout State, _ arg: TunnelStatus) {
        st.tunnelState = arg.state
        handler.onStatus(arg)
    }

    private func getNetworkConfig(_ config: TunnelConfig, _ generation: UInt64) -> NetworkConfig {
        let state = config.state

        return NetworkConfig(
            generation: generation,
            addresses: state.addresses.flatMap { [$0.v4, $0.v6] }.filter { !$0.isEmpty },
            routes: [state.cidr.v4, state.cidr.v6].filter { !$0.isEmpty },
            dns: DNSConfig(servers: state.dns.servers),
            mtu: 1280
        )
    }
}

final class FakeHost: TunnelHost {
    private struct State {
        var err: (any Error)?
        var specs: [(String, TunnelSpec)] = []
    }

    private let state = Mutex(State())

    var specs: [(String, TunnelSpec)] {
        state.withLock { $0.specs }
    }

    func setError(_ arg: (any Error)?) {
        state.withLock { $0.err = arg }
    }

    func apply(domain: String, generation: UInt64, spec: TunnelSpec) async throws -> Int32? {
        try state.withLock { st in
            if let err = st.err {
                throw err
            }

            st.specs.append((domain, spec))
        }

        return nil
    }
}

final class FakeTunnels: Sendable {
    private let state = Mutex<[FakeTunnel]>([])

    var all: [FakeTunnel] {
        state.withLock { $0 }
    }

    var last: FakeTunnel? {
        state.withLock { $0.last }
    }

    func create(_ handler: any TunnelHandler) -> any Tunnel {
        let ret = FakeTunnel(handler)
        state.withLock { $0.append(ret) }
        return ret
    }
}
