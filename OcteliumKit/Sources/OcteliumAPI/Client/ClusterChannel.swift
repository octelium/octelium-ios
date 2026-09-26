import Foundation
import GRPCCore
import OcteliumCore
import OcteliumProto

#if canImport(Network)
import GRPCNIOTransportHTTP2TransportServices
#else
import GRPCNIOTransportHTTP2Posix
#endif

public let refreshTokenMetadataKey = "x-octelium-refresh-token"

public typealias ChannelFactory = @Sendable (String) throws -> any ClusterChannel

public protocol ClusterChannel: Sendable {
    func authenticateWithAuthenticationToken(
        _ req: Authv1.AuthenticateWithAuthenticationTokenRequest,
        refreshToken: String?,
        timeout: Duration
    ) async throws -> Authv1.SessionToken

    func authenticateWithRefreshToken(refreshToken: String, timeout: Duration) async throws -> Authv1.SessionToken

    func logout(refreshToken: String, timeout: Duration) async throws

    func registerDeviceBegin(
        _ req: Authv1.RegisterDeviceBeginRequest,
        refreshToken: String,
        timeout: Duration
    ) async throws -> Authv1.RegisterDeviceBeginResponse

    func registerDeviceFinish(
        _ req: Authv1.RegisterDeviceFinishRequest,
        refreshToken: String,
        timeout: Duration
    ) async throws

    func getStatus(accessToken: String, timeout: Duration) async throws -> Userv1.GetStatusResponse

    func disconnect(accessToken: String, timeout: Duration) async throws

    func connect(
        accessToken: String,
        requests: AsyncStream<Userv1.ConnectRequest>,
        onResponse: @escaping @Sendable (Userv1.ConnectResponse) -> Void
    ) async throws

    func close()
}

public final class GRPCClusterChannel<Transport: ClientTransport>: ClusterChannel {
    private let client: GRPCClient<Transport>
    private let auth: Octelium_Api_Main_Auth_V1_MainService.Client<Transport>
    private let user: Octelium_Api_Main_User_V1_MainService.Client<Transport>

    public init(transport: Transport) {
        let client = GRPCClient(transport: transport)
        self.client = client
        self.auth = Octelium_Api_Main_Auth_V1_MainService.Client(wrapping: client)
        self.user = Octelium_Api_Main_User_V1_MainService.Client(wrapping: client)

        Task {
            try? await client.runConnections()
        }
    }

    public func authenticateWithAuthenticationToken(
        _ req: Authv1.AuthenticateWithAuthenticationTokenRequest,
        refreshToken: String?,
        timeout: Duration
    ) async throws -> Authv1.SessionToken {
        try await call {
            try await auth.authenticateWithAuthenticationToken(
                req,
                metadata: getRefreshTokenMetadata(refreshToken),
                options: getCallOptions(timeout)
            )
        }
    }

    public func authenticateWithRefreshToken(refreshToken: String, timeout: Duration) async throws -> Authv1.SessionToken {
        try await call {
            try await auth.authenticateWithRefreshToken(
                Authv1.AuthenticateWithRefreshTokenRequest(),
                metadata: getRefreshTokenMetadata(refreshToken),
                options: getCallOptions(timeout)
            )
        }
    }

    public func logout(refreshToken: String, timeout: Duration) async throws {
        _ = try await call {
            try await auth.logout(
                Authv1.LogoutRequest(),
                metadata: getRefreshTokenMetadata(refreshToken),
                options: getCallOptions(timeout)
            )
        }
    }

    public func registerDeviceBegin(
        _ req: Authv1.RegisterDeviceBeginRequest,
        refreshToken: String,
        timeout: Duration
    ) async throws -> Authv1.RegisterDeviceBeginResponse {
        try await call {
            try await auth.registerDeviceBegin(
                req,
                metadata: getRefreshTokenMetadata(refreshToken),
                options: getCallOptions(timeout)
            )
        }
    }

    public func registerDeviceFinish(
        _ req: Authv1.RegisterDeviceFinishRequest,
        refreshToken: String,
        timeout: Duration
    ) async throws {
        _ = try await call {
            try await auth.registerDeviceFinish(
                req,
                metadata: getRefreshTokenMetadata(refreshToken),
                options: getCallOptions(timeout)
            )
        }
    }

    public func getStatus(accessToken: String, timeout: Duration) async throws -> Userv1.GetStatusResponse {
        try await call {
            try await user.getStatus(
                Userv1.GetStatusRequest(),
                metadata: getAuthMetadata(accessToken),
                options: getCallOptions(timeout)
            )
        }
    }

    public func disconnect(accessToken: String, timeout: Duration) async throws {
        _ = try await call {
            try await user.disconnect(
                Userv1.DisconnectRequest(),
                metadata: getAuthMetadata(accessToken),
                options: getCallOptions(timeout)
            )
        }
    }

    public func connect(
        accessToken: String,
        requests: AsyncStream<Userv1.ConnectRequest>,
        onResponse: @escaping @Sendable (Userv1.ConnectResponse) -> Void
    ) async throws {
        try await call {
            try await user.connect(
                metadata: getAuthMetadata(accessToken),
                requestProducer: { writer in
                    for await req in requests {
                        try await writer.write(req)
                    }
                },
                onResponse: { response in
                    for try await msg in response.messages {
                        onResponse(msg)
                    }
                }
            )
        }
    }

    public func close() {
        client.beginGracefulShutdown()
    }

    private func call<T: Sendable>(_ fn: () async throws -> T) async throws -> T {
        do {
            return try await fn()
        } catch let err as RPCError {
            throw getStatusError(err)
        }
    }
}

public func newClusterChannel(_ domain: String) throws -> any ClusterChannel {
    #if canImport(Network)
    let transport = try HTTP2ClientTransport.TransportServices(
        target: .dns(host: getClusterAPIHost(domain), port: clusterAPIPort),
        transportSecurity: .tls,
        config: .defaults { $0.connection.maxIdleTime = clusterIdleTimeout }
    )
    #else
    let transport = try HTTP2ClientTransport.Posix(
        target: .dns(host: getClusterAPIHost(domain), port: clusterAPIPort),
        transportSecurity: .tls,
        config: .defaults { $0.connection.maxIdleTime = clusterIdleTimeout }
    )
    #endif

    return GRPCClusterChannel(transport: transport)
}

private func getAuthMetadata(_ accessToken: String) -> Metadata {
    var ret = Metadata()
    ret.addString(accessToken, forKey: authMetadataKey)
    return ret
}

private func getRefreshTokenMetadata(_ refreshToken: String?) -> Metadata {
    var ret = Metadata()
    if let refreshToken, !refreshToken.isEmpty {
        ret.addString(refreshToken, forKey: refreshTokenMetadataKey)
    }
    return ret
}

private func getCallOptions(_ timeout: Duration) -> CallOptions {
    var ret = CallOptions.defaults
    ret.timeout = timeout
    return ret
}
