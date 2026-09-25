import Foundation
import GRPCCore
import GRPCInProcessTransport
import OcteliumCore
import OcteliumProto
import SwiftProtobuf
import Synchronization
import XCTest

@testable import OcteliumAPI

private final class ServerState: Sendable {
    let tokens = Mutex<[String?]>([])
    let validTokens = Mutex<Set<String>>([])
    let totalServices = Mutex(250)
    let connections = Atomic<Int>(0)
}

private struct TestService: Octelium_Api_Main_User_V1_MainService.SimpleServiceProtocol {
    let state: ServerState

    func connect(
        request: RPCAsyncSequence<Octelium_Api_Main_User_V1_ConnectRequest, any Error>,
        response: RPCWriter<Octelium_Api_Main_User_V1_ConnectResponse>,
        context: ServerContext
    ) async throws {
        throw RPCError(code: .unimplemented, message: "unimplemented")
    }

    func disconnect(
        request: Octelium_Api_Main_User_V1_DisconnectRequest,
        context: ServerContext
    ) async throws -> Octelium_Api_Main_User_V1_DisconnectResponse {
        throw RPCError(code: .unimplemented, message: "unimplemented")
    }

    func listService(
        request: Userv1.ListServiceOptions,
        context: ServerContext
    ) async throws -> Userv1.ServiceList {
        let total = state.totalServices.withLock { $0 }
        let page = Int(request.common.page)
        let itemsPerPage = Int(request.common.itemsPerPage)
        let start = page * itemsPerPage
        let end = min(start + itemsPerPage, total)

        var ret = Userv1.ServiceList()
        if start < end {
            ret.items = (start..<end).map { idx in
                var svc = Userv1.Service()
                svc.metadata.name = "svc-\(idx).\(request.namespace)"
                return svc
            }
        }
        ret.listResponseMeta.page = UInt32(page)
        ret.listResponseMeta.itemsPerPage = UInt32(itemsPerPage)
        ret.listResponseMeta.totalCount = UInt32(total)
        ret.listResponseMeta.hasMore_p = end < total

        return ret
    }

    func listNamespace(
        request: Userv1.ListNamespaceOptions,
        context: ServerContext
    ) async throws -> Userv1.NamespaceList {
        var ns = Userv1.Namespace()
        ns.metadata.name = "default"

        var ret = Userv1.NamespaceList()
        ret.items = [ns]
        return ret
    }

    func getStatus(
        request: Userv1.GetStatusRequest,
        context: ServerContext
    ) async throws -> Userv1.GetStatusResponse {
        var ret = Userv1.GetStatusResponse()
        ret.domain = "example.com"
        return ret
    }

    func setServiceConfigs(
        request: Octelium_Api_Main_User_V1_SetServiceConfigsRequest,
        context: ServerContext
    ) async throws -> Octelium_Api_Main_User_V1_SetServiceConfigsResponse {
        throw RPCError(code: .unimplemented, message: "unimplemented")
    }

    func getService(
        request: Octelium_Api_Main_Meta_V1_GetOptions,
        context: ServerContext
    ) async throws -> Userv1.Service {
        throw RPCError(code: .notFound, message: "not found")
    }
}

private struct AuthInterceptor: ServerInterceptor {
    let state: ServerState

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @Sendable (StreamingServerRequest<Input>, ServerContext) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        let token = request.metadata[stringValues: authMetadataKey].first { _ in true }
        state.tokens.withLock { $0.append(token) }

        guard let token, state.validTokens.withLock({ $0.contains(token) }) else {
            throw RPCError(code: .unauthenticated, message: "invalid token")
        }

        return try await next(request, context)
    }
}

private final class TestConnection: ClusterConnection {
    private let conn: GRPCClusterConnection<InProcessTransport.Client>
    private let server: GRPCServer<InProcessTransport.Server>

    init(_ state: ServerState) {
        let transport = InProcessTransport()
        let server = GRPCServer(
            transport: transport.server,
            services: [TestService(state: state)],
            interceptors: [AuthInterceptor(state: state)]
        )

        Task {
            try? await server.serve()
        }

        self.server = server
        self.conn = GRPCClusterConnection(transport: transport.client)

        state.connections.add(1, ordering: .sequentiallyConsistent)
    }

    func getStatus(
        _ req: Userv1.GetStatusRequest,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Userv1.GetStatusResponse {
        try await conn.getStatus(req, metadata: metadata, options: options)
    }

    func listService(
        _ req: Userv1.ListServiceOptions,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Userv1.ServiceList {
        try await conn.listService(req, metadata: metadata, options: options)
    }

    func listNamespace(
        _ req: Userv1.ListNamespaceOptions,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Userv1.NamespaceList {
        try await conn.listNamespace(req, metadata: metadata, options: options)
    }

    func close() {
        conn.close()
        server.beginGracefulShutdown()
    }
}

private func getCredential(_ accessToken: String, expiresAt: Date? = nil) -> Daemonv1.GetAPICredentialResponse {
    var ret = Daemonv1.GetAPICredentialResponse()
    ret.accessToken = accessToken
    if let expiresAt {
        ret.expiresAt = Google_Protobuf_Timestamp(date: expiresAt)
    }
    return ret
}

final class ClusterClientTests: XCTestCase {

    private func getClient(
        _ state: ServerState,
        now: @escaping @Sendable () -> Date = { Date() },
        source: @escaping CredentialSource
    ) -> ClusterClient {
        ClusterClient(
            credentials: source,
            connections: { _ in TestConnection(state) },
            callTimeout: .seconds(10),
            now: now
        )
    }

    private func assertStatusError(
        _ code: StatusCode,
        _ message: String? = nil,
        _ fn: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await fn()
            XCTFail(file: file, line: line)
        } catch let err as StatusError {
            XCTAssertEqual(code, err.code, file: file, line: line)
            if let message {
                XCTAssertEqual(message, err.message, file: file, line: line)
            }
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testCall() async throws {
        let state = ServerState()
        let count = Atomic<Int>(0)
        _ = state.validTokens.withLock { $0.insert("token-1") }

        let c = getClient(state) { _ in
            let n = count.add(1, ordering: .sequentiallyConsistent).newValue
            return getCredential("token-\(n)")
        }

        do {
            let ret = try await c.getStatus("example.com")
            XCTAssertEqual("example.com", ret.domain)
            XCTAssertEqual(["token-1"], state.tokens.withLock { $0 })
            XCTAssertEqual(1, count.load(ordering: .sequentiallyConsistent))
        }

        do {
            _ = try await c.getStatus("example.com")
            XCTAssertEqual(1, count.load(ordering: .sequentiallyConsistent))
            XCTAssertEqual("token-1", state.tokens.withLock { $0.last! })
        }

        do {
            state.validTokens.withLock { $0 = ["token-2"] }

            _ = try await c.getStatus("example.com")
            XCTAssertEqual(2, count.load(ordering: .sequentiallyConsistent))
            XCTAssertEqual(["token-1", "token-1", "token-1", "token-2"], state.tokens.withLock { $0 })
            XCTAssertEqual(1, state.connections.load(ordering: .sequentiallyConsistent))
        }

        do {
            c.invalidate("example.com")
            _ = state.validTokens.withLock { $0.insert("token-3") }

            _ = try await c.getStatus("example.com")
            XCTAssertEqual(3, count.load(ordering: .sequentiallyConsistent))
            XCTAssertEqual("token-3", state.tokens.withLock { $0.last! })
            XCTAssertEqual(2, state.connections.load(ordering: .sequentiallyConsistent))
        }

        c.close()
    }

    func testConcurrentCredentials() async throws {
        let state = ServerState()
        let count = Atomic<Int>(0)
        _ = state.validTokens.withLock { $0.insert("token") }

        let c = getClient(state) { _ in
            count.add(1, ordering: .sequentiallyConsistent)
            try await Task.sleep(for: .milliseconds(100))
            return getCredential("token")
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try await c.getStatus("example.com")
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(1, count.load(ordering: .sequentiallyConsistent))
        XCTAssertEqual(8, state.tokens.withLock { $0.count })

        c.close()
    }

    func testUnauthenticated() async {
        do {
            let state = ServerState()
            let count = Atomic<Int>(0)
            let c = getClient(state) { _ in
                count.add(1, ordering: .sequentiallyConsistent)
                return getCredential("invalid")
            }

            await assertStatusError(.unauthenticated, "invalid token") {
                _ = try await c.getStatus("example.com")
            }
            XCTAssertEqual(2, count.load(ordering: .sequentiallyConsistent))
            c.close()
        }

        do {
            let c = getClient(ServerState()) { _ in Daemonv1.GetAPICredentialResponse() }

            await assertStatusError(.unauthenticated, "You are not authenticated to the domain example.com") {
                _ = try await c.getStatus("example.com")
            }
            c.close()
        }

        do {
            let c = getClient(ServerState()) { _ in throw StatusError(.unauthenticated, "logged out") }

            await assertStatusError(.unauthenticated, "logged out") {
                _ = try await c.getStatus("example.com")
            }
            c.close()
        }
    }

    func testListAll() async throws {
        let state = ServerState()
        _ = state.validTokens.withLock { $0.insert("token") }
        let c = getClient(state) { _ in getCredential("token") }

        do {
            let ret = try await c.listAllServices("example.com", namespace: "default")
            XCTAssertEqual(250, ret.count)
            XCTAssertEqual("svc-0.default", ret.first?.metadata.name)
            XCTAssertEqual("svc-249.default", ret.last?.metadata.name)
        }

        do {
            state.totalServices.withLock { $0 = 0 }
            let ret = try await c.listAllServices("example.com")
            XCTAssertTrue(ret.isEmpty)
        }

        do {
            let ret = try await c.listAllNamespaces("example.com")
            XCTAssertEqual(["default"], ret.map(\.metadata.name))
        }

        do {
            var options = Userv1.ListServiceOptions()
            options.common = getCommonListOptions(0, 10)
            let ret = try await c.listService("example.com", options)
            XCTAssertTrue(ret.items.isEmpty)
        }

        c.close()
    }

    func testCredentialCache() {
        let now = Mutex(getDate("2026-09-23T10:00:00Z"))
        let c = CredentialCache { now.withLock { $0 } }

        do {
            XCTAssertNil(c.get("example.com"))
        }

        do {
            c.set("example.com", getCredential("token"))
            XCTAssertEqual("token", c.get("example.com"))
        }

        do {
            c.set("example.com", getCredential("token", expiresAt: now.withLock { $0 }.addingTimeInterval(60)))
            XCTAssertEqual("token", c.get("example.com"))

            now.withLock { $0 = $0.addingTimeInterval(29) }
            XCTAssertEqual("token", c.get("example.com"))

            now.withLock { $0 = $0.addingTimeInterval(2) }
            XCTAssertNil(c.get("example.com"))
            XCTAssertNil(c.get("example.com"))
        }

        do {
            c.set("a.example.com", getCredential("a"))
            c.set("b.example.com", getCredential("b"))
            c.remove("a.example.com")
            XCTAssertNil(c.get("a.example.com"))
            XCTAssertEqual("b", c.get("b.example.com"))

            c.clear()
            XCTAssertNil(c.get("b.example.com"))
        }

        do {
            c.set("example.com", getCredential("token"))
            XCTAssertEqual("token", c.get("example.com"))

            now.withLock { $0 = $0.addingTimeInterval(credentialMaxAge - credentialExpiryMargin - 1) }
            XCTAssertEqual("token", c.get("example.com"))

            now.withLock { $0 = $0.addingTimeInterval(2) }
            XCTAssertNil(c.get("example.com"))
        }

        do {
            let generation = c.generation
            XCTAssertTrue(c.set("example.com", getCredential("token"), generation: generation))
            XCTAssertEqual("token", c.get("example.com"))

            c.remove("other.example.com")
            XCTAssertNotEqual(generation, c.generation)
            XCTAssertFalse(c.set("example.com", getCredential("stale"), generation: generation))
            XCTAssertEqual("token", c.get("example.com"))

            let next = c.generation
            c.clear()
            XCTAssertFalse(c.set("example.com", getCredential("stale"), generation: next))
            XCTAssertNil(c.get("example.com"))

            XCTAssertTrue(c.set("example.com", getCredential("token-2"), generation: c.generation))
            XCTAssertEqual("token-2", c.get("example.com"))
        }
    }

    func testInvalidateDuringFetch() async throws {
        let state = ServerState()
        let count = Atomic<Int>(0)
        let isReleased = Atomic<Bool>(false)
        state.validTokens.withLock { $0.formUnion(["token-1", "token-2"]) }

        let c = getClient(state) { _ in
            let n = count.add(1, ordering: .sequentiallyConsistent).newValue
            if n == 1 {
                while !isReleased.load(ordering: .sequentiallyConsistent) {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            return getCredential("token-\(n)")
        }

        let task = Task {
            try await c.getStatus("example.com")
        }

        while count.load(ordering: .sequentiallyConsistent) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        c.invalidate("example.com")

        do {
            _ = try await c.getStatus("example.com")
            XCTAssertEqual(2, count.load(ordering: .sequentiallyConsistent))
            XCTAssertEqual("token-2", state.tokens.withLock { $0.last! })
        }

        isReleased.store(true, ordering: .sequentiallyConsistent)
        _ = try? await task.value

        do {
            _ = try await c.getStatus("example.com")
            XCTAssertEqual(2, count.load(ordering: .sequentiallyConsistent))
            XCTAssertEqual("token-2", state.tokens.withLock { $0.last! })
        }

        c.close()
    }

    func testGetClusterAPIHost() {
        XCTAssertEqual("octelium-api.example.com", getClusterAPIHost("example.com"))
        XCTAssertEqual("x-octelium-auth", authMetadataKey)
    }

    func testGetStatusError() {
        XCTAssertEqual(StatusError(.unauthenticated, "x"), getStatusError(RPCError(code: .unauthenticated, message: "x")))
        XCTAssertEqual(StatusError(.unavailable, "down"), getStatusError(RPCError(code: .unavailable, message: "down")))
        XCTAssertEqual(StatusError(.notFound, ""), getStatusError(RPCError(code: .notFound, message: "")))
    }

    func testNewClusterConnection() throws {
        let conn = try newClusterConnection("example.com")
        conn.close()
    }
}

private func getDate(_ arg: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: arg)!
}
