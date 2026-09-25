import Foundation
import GRPCCore
import OcteliumCore
import OcteliumProto
import Synchronization

#if canImport(Network)
import GRPCNIOTransportHTTP2TransportServices
#else
import GRPCNIOTransportHTTP2Posix
#endif

public let authMetadataKey = "x-octelium-auth"
public let clusterAPIPort = 443
public let credentialExpiryMargin: TimeInterval = 30
public let credentialMaxAge: TimeInterval = 300
public let clusterIdleTimeout: Duration = .seconds(300)

public func getClusterAPIHost(_ domain: String) -> String {
    "octelium-api.\(domain)"
}

public typealias CredentialSource = @Sendable (String) async throws -> Daemonv1.GetAPICredentialResponse

public typealias ConnectionFactory = @Sendable (String) throws -> any ClusterConnection

public final class CredentialCache: Sendable {
    private struct Credential {
        let accessToken: String
        let expiresAt: Date
    }

    private struct State {
        var credentials: [String: Credential] = [:]
        var generation: UInt64 = 0
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public var generation: UInt64 {
        state.withLock { $0.generation }
    }

    public func get(_ domain: String) -> String? {
        let at = now()

        return state.withLock { st in
            guard let ret = st.credentials[domain] else {
                return nil
            }

            if at.addingTimeInterval(credentialExpiryMargin) < ret.expiresAt {
                return ret.accessToken
            }

            st.credentials[domain] = nil
            return nil
        }
    }

    @discardableResult
    public func set(_ domain: String, _ arg: Daemonv1.GetAPICredentialResponse, generation: UInt64? = nil) -> Bool {
        let expiresAt = arg.hasExpiresAt ? arg.expiresAt.date : now().addingTimeInterval(credentialMaxAge)
        let ret = Credential(accessToken: arg.accessToken, expiresAt: expiresAt)

        return state.withLock { st in
            if let generation, generation != st.generation {
                return false
            }

            st.credentials[domain] = ret
            return true
        }
    }

    public func remove(_ domain: String) {
        state.withLock { st in
            st.credentials[domain] = nil
            st.generation &+= 1
        }
    }

    public func clear() {
        state.withLock { st in
            st.credentials.removeAll()
            st.generation &+= 1
        }
    }
}

public protocol ClusterConnection: Sendable {
    func getStatus(
        _ req: Userv1.GetStatusRequest,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Userv1.GetStatusResponse

    func listService(
        _ req: Userv1.ListServiceOptions,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Userv1.ServiceList

    func listNamespace(
        _ req: Userv1.ListNamespaceOptions,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Userv1.NamespaceList

    func close()
}

public final class GRPCClusterConnection<Transport: ClientTransport>: ClusterConnection {
    private let client: GRPCClient<Transport>
    private let stub: Octelium_Api_Main_User_V1_MainService.Client<Transport>

    public init(transport: Transport) {
        let client = GRPCClient(transport: transport)
        self.client = client
        self.stub = Octelium_Api_Main_User_V1_MainService.Client(wrapping: client)

        Task {
            try? await client.runConnections()
        }
    }

    public func getStatus(
        _ req: Userv1.GetStatusRequest,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Userv1.GetStatusResponse {
        try await stub.getStatus(req, metadata: metadata, options: options)
    }

    public func listService(
        _ req: Userv1.ListServiceOptions,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Userv1.ServiceList {
        try await stub.listService(req, metadata: metadata, options: options)
    }

    public func listNamespace(
        _ req: Userv1.ListNamespaceOptions,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Userv1.NamespaceList {
        try await stub.listNamespace(req, metadata: metadata, options: options)
    }

    public func close() {
        client.beginGracefulShutdown()
    }
}

public func newClusterConnection(_ domain: String) throws -> any ClusterConnection {
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

    return GRPCClusterConnection(transport: transport)
}

private actor CredentialFetcher {
    private struct Fetch {
        let generation: UInt64
        let task: Task<String, Error>
    }

    private var fetches: [String: Fetch] = [:]

    func get(
        _ domain: String,
        generation: UInt64,
        _ fn: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        if let ret = fetches[domain], ret.generation == generation {
            return try await ret.task.value
        }

        let task = Task { try await fn() }
        fetches[domain] = Fetch(generation: generation, task: task)
        defer {
            if fetches[domain]?.task == task {
                fetches[domain] = nil
            }
        }

        return try await task.value
    }
}

public func getStatusError(_ err: RPCError) -> StatusError {
    getStatusError(code: Int32(err.code.rawValue), message: err.message)
}

public final class ClusterClient: Sendable {
    private let credentials: CredentialSource
    private let connections: ConnectionFactory
    private let callTimeout: Duration
    private let cache: CredentialCache
    private let fetcher = CredentialFetcher()
    private let connectionMap = Mutex<[String: any ClusterConnection]>([:])

    public init(
        credentials: @escaping CredentialSource,
        connections: @escaping ConnectionFactory = newClusterConnection,
        callTimeout: Duration = .seconds(20),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.connections = connections
        self.callTimeout = callTimeout
        self.cache = CredentialCache(now: now)
    }

    public func getStatus(_ domain: String) async throws -> Userv1.GetStatusResponse {
        try await call(domain) { conn, metadata, options in
            try await conn.getStatus(Userv1.GetStatusRequest(), metadata: metadata, options: options)
        }
    }

    public func listService(_ domain: String, _ options: Userv1.ListServiceOptions) async throws -> Userv1.ServiceList {
        try await call(domain) { conn, metadata, callOptions in
            try await conn.listService(options, metadata: metadata, options: callOptions)
        }
    }

    public func listNamespace(
        _ domain: String,
        _ options: Userv1.ListNamespaceOptions
    ) async throws -> Userv1.NamespaceList {
        try await call(domain) { conn, metadata, callOptions in
            try await conn.listNamespace(options, metadata: metadata, options: callOptions)
        }
    }

    public func listAllServices(
        _ domain: String,
        namespace: String = "",
        type: ServiceType = .unset
    ) async throws -> [Userv1.Service] {
        try await listAll { page in
            var options = Userv1.ListServiceOptions()
            options.common = getCommonListOptions(page, allItemsPerPage)
            options.namespace = namespace
            options.type = type

            let resp = try await self.listService(domain, options)
            return (resp.items, resp.hasListResponseMeta ? resp.listResponseMeta : nil)
        }
    }

    public func listAllNamespaces(_ domain: String) async throws -> [Userv1.Namespace] {
        try await listAll { page in
            var options = Userv1.ListNamespaceOptions()
            options.common = getCommonListOptions(page, allItemsPerPage)

            let resp = try await self.listNamespace(domain, options)
            return (resp.items, resp.hasListResponseMeta ? resp.listResponseMeta : nil)
        }
    }

    public func invalidate(_ domain: String) {
        cache.remove(domain)
        connectionMap.withLock { $0.removeValue(forKey: domain) }?.close()
    }

    public func close() {
        cache.clear()
        let conns = connectionMap.withLock { itms in
            let ret = Array(itms.values)
            itms.removeAll()
            return ret
        }
        conns.forEach { $0.close() }
    }

    private func getConnection(_ domain: String) throws -> any ClusterConnection {
        try connectionMap.withLock { itms in
            if let ret = itms[domain] {
                return ret
            }

            let ret = try connections(domain)
            itms[domain] = ret
            return ret
        }
    }

    private func call<T: Sendable>(
        _ domain: String,
        _ fn: @Sendable (any ClusterConnection, Metadata, CallOptions) async throws -> T
    ) async throws -> T {
        let conn = try getConnection(domain)

        var options = CallOptions.defaults
        options.timeout = callTimeout

        do {
            return try await fn(conn, try await getMetadata(domain, renew: false), options)
        } catch let err as RPCError {
            if err.code != .unauthenticated {
                throw getStatusError(err)
            }
        }

        do {
            return try await fn(conn, try await getMetadata(domain, renew: true), options)
        } catch let err as RPCError {
            throw getStatusError(err)
        }
    }

    private func getMetadata(_ domain: String, renew: Bool) async throws -> Metadata {
        var ret = Metadata()
        ret.addString(try await getAccessToken(domain, renew: renew), forKey: authMetadataKey)
        return ret
    }

    private func getAccessToken(_ domain: String, renew: Bool) async throws -> String {
        if !renew, let ret = cache.get(domain) {
            return ret
        }

        let credentials = self.credentials
        let cache = self.cache
        let generation = cache.generation

        return try await fetcher.get(domain, generation: generation) {
            let resp = try await credentials(domain)
            if resp.accessToken.isEmpty {
                throw StatusError(.unauthenticated, "You are not authenticated to the domain \(domain)")
            }

            cache.set(domain, resp, generation: generation)

            return resp.accessToken
        }
    }
}
