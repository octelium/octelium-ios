import Foundation
import GRPCCore
import GRPCInProcessTransport
import OcteliumCore
import OcteliumProto
import Synchronization
import XCTest

@testable import OcteliumAPI

private final class ServicesState: Sendable {
    let isFailing = Atomic<Bool>(false)
    let listCalls = Atomic<Int>(0)

    let services: [Userv1.Service] = (0..<120).map { idx in
        var ret = Userv1.Service()
        ret.metadata.uid = "uid-\(idx)"
        ret.metadata.name = idx % 2 == 0 ? "api-\(idx).production" : "db-\(idx).staging"
        ret.spec.type = idx % 2 == 0 ? .http : .postgres
        ret.status.namespace = idx % 2 == 0 ? "production" : "staging"
        return ret
    }
}

private struct ServicesService: Octelium_Api_Main_User_V1_MainService.SimpleServiceProtocol {
    let state: ServicesState

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
        state.listCalls.add(1, ordering: .sequentiallyConsistent)

        if state.isFailing.load(ordering: .sequentiallyConsistent) {
            throw RPCError(code: .unavailable, message: "unreachable")
        }

        let items = state.services.filter {
            (request.namespace.isEmpty || $0.status.namespace == request.namespace) &&
                (request.type == .unset || $0.spec.type == request.type)
        }

        let start = Int(request.common.page * request.common.itemsPerPage)
        let end = min(start + Int(request.common.itemsPerPage), items.count)

        var ret = Userv1.ServiceList()
        ret.items = start < end ? Array(items[start..<end]) : []
        ret.listResponseMeta.hasMore_p = end < items.count
        return ret
    }

    func listNamespace(
        request: Userv1.ListNamespaceOptions,
        context: ServerContext
    ) async throws -> Userv1.NamespaceList {
        var ret = Userv1.NamespaceList()
        ret.items = ["production", "staging"].map {
            var ns = Userv1.Namespace()
            ns.metadata.name = $0
            return ns
        }
        return ret
    }

    func getStatus(
        request: Userv1.GetStatusRequest,
        context: ServerContext
    ) async throws -> Userv1.GetStatusResponse {
        Userv1.GetStatusResponse()
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

private final class ServicesConnection: ClusterConnection {
    private let conn: GRPCClusterConnection<InProcessTransport.Client>
    private let server: GRPCServer<InProcessTransport.Server>

    init(_ state: ServicesState) {
        let transport = InProcessTransport()
        let server = GRPCServer(transport: transport.server, services: [ServicesService(state: state)])

        Task {
            try? await server.serve()
        }

        self.server = server
        self.conn = GRPCClusterConnection(transport: transport.client)
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

@MainActor
final class ServicesModelTests: XCTestCase {

    private var state: ServicesState!
    private var cluster: ClusterClient!

    override func setUp() async throws {
        let state = ServicesState()
        self.state = state
        self.cluster = ClusterClient(
            credentials: { _ in
                var ret = Daemonv1.GetAPICredentialResponse()
                ret.accessToken = "token"
                return ret
            },
            connections: { _ in ServicesConnection(state) }
        )
    }

    override func tearDown() async throws {
        cluster.close()
    }

    private func waitFor(
        _ fn: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(10)

        while !fn() {
            if Date() > deadline {
                XCTFail("Timed out", file: file, line: line)
                return
            }

            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private var listCalls: Int {
        state.listCalls.load(ordering: .sequentiallyConsistent)
    }

    func testPaging() async throws {
        let m = ServicesModel(cluster: cluster, domain: "example.com")
        XCTAssertTrue(m.isLoading)

        m.start()
        try await waitFor { !m.isLoading && m.namespaces.count == 2 }

        do {
            XCTAssertEqual(servicesPerPage, m.items.count)
            XCTAssertTrue(m.hasMore)
            XCTAssertNil(m.error)
            XCTAssertEqual(["production", "staging"], m.namespaces.map(\.metadata.name))
        }

        do {
            m.loadMore()
            XCTAssertTrue(m.isLoadingMore)
            try await waitFor { !m.isLoadingMore }
            XCTAssertEqual(100, m.items.count)
            XCTAssertTrue(m.hasMore)

            m.loadMore()
            try await waitFor { !m.isLoadingMore }
            XCTAssertEqual(120, m.items.count)
            XCTAssertFalse(m.hasMore)

            m.loadMore()
            XCTAssertFalse(m.isLoadingMore)
            XCTAssertEqual(120, m.items.count)
            XCTAssertEqual(120, Set(m.items.map(\.metadata.uid)).count)
        }
    }

    func testFilters() async throws {
        let m = ServicesModel(cluster: cluster, domain: "example.com")
        m.start()
        try await waitFor { !m.isLoading }

        do {
            m.setNamespace("staging")
            XCTAssertTrue(m.isLoading)
            try await waitFor { !m.isLoading }
            XCTAssertEqual("staging", m.filter.namespace)
            XCTAssertEqual(servicesPerPage, m.items.count)
            XCTAssertTrue(m.items.allSatisfy { $0.status.namespace == "staging" })
        }

        do {
            m.setNamespace(nil)
            m.setType("HTTP")
            try await waitFor { !m.isLoading }
            XCTAssertFalse(m.items.isEmpty)
            XCTAssertTrue(m.items.allSatisfy { $0.spec.type == .http })
        }

        do {
            m.setType(nil)
            m.setSearch("api-1")
            try await waitFor { !m.isLoading }

            let names = m.items.map(\.metadata.name)
            XCTAssertEqual(["api-10.production", "api-12.production", "api-14.production"], Array(names.prefix(3)))
            XCTAssertTrue(names.allSatisfy { $0.contains("api-1") })
            XCTAssertFalse(m.hasMore)
        }

        do {
            m.setSearch("nothing matches")
            try await waitFor { !m.isLoading }
            XCTAssertTrue(m.items.isEmpty)
            XCTAssertNil(m.error)
        }
    }

    func testSearchCache() async throws {
        let now = Mutex(Date(timeIntervalSince1970: 1_767_225_600))
        let m = ServicesModel(cluster: cluster, domain: "example.com") { now.withLock { $0 } }
        m.start()
        try await waitFor { !m.isLoading }
        XCTAssertEqual(1, listCalls)

        do {
            m.setSearch("api-1")
            try await waitFor { !m.isLoading }
            XCTAssertEqual(3, listCalls)
            XCTAssertTrue(m.items.allSatisfy { $0.metadata.name.contains("api-1") })
        }

        do {
            m.setSearch("db-3")
            XCTAssertFalse(m.isLoading)
            XCTAssertTrue(m.items.allSatisfy { $0.metadata.name.contains("db-3") })
            XCTAssertEqual(["db-3.staging", "db-31.staging"], Array(m.items.map(\.metadata.name).prefix(2)))
            XCTAssertEqual(3, listCalls)
        }

        do {
            m.setNamespace("staging")
            try await waitFor { !m.isLoading }
            XCTAssertEqual(4, listCalls)
            XCTAssertTrue(m.items.allSatisfy { $0.status.namespace == "staging" })

            m.setSearch("db-5")
            XCTAssertFalse(m.isLoading)
            XCTAssertFalse(m.items.isEmpty)
            XCTAssertEqual(4, listCalls)
        }

        do {
            now.withLock { $0 = $0.addingTimeInterval(31) }
            m.setSearch("db-7")
            try await waitFor { !m.isLoading }
            XCTAssertEqual(5, listCalls)
        }

        do {
            await m.refresh()
            XCTAssertEqual(6, listCalls)
        }

        do {
            m.setSearch("")
            try await waitFor { !m.isLoading }
            XCTAssertEqual(7, listCalls)
            XCTAssertEqual(servicesPerPage, m.items.count)
        }
    }

    func testSearchDebounce() async throws {
        let m = ServicesModel(cluster: cluster, domain: "example.com")
        m.start()
        try await waitFor { !m.isLoading }
        XCTAssertEqual(1, listCalls)

        m.setSearch("a")
        m.setSearch("ap")
        m.setSearch("api")
        m.setSearch("api")
        try await waitFor { !m.isLoading }

        XCTAssertEqual(3, listCalls)
        XCTAssertEqual("api", m.filter.search)
        XCTAssertEqual(60, m.items.count)
    }

    func testErrors() async throws {
        state.isFailing.store(true, ordering: .sequentiallyConsistent)

        let m = ServicesModel(cluster: cluster, domain: "example.com")
        m.start()
        try await waitFor { !m.isLoading }

        XCTAssertEqual("unreachable", m.error)
        XCTAssertTrue(m.items.isEmpty)

        state.isFailing.store(false, ordering: .sequentiallyConsistent)
        await m.refresh()

        XCTAssertNil(m.error)
        XCTAssertEqual(servicesPerPage, m.items.count)
    }
}
