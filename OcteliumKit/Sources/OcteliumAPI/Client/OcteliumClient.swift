import Foundation
import OcteliumCore
import OcteliumProto
import SwiftProtobuf
import Synchronization

public let operationRetention: TimeInterval = 600

public final class OcteliumClient: LocalClient, @unchecked Sendable {
    public let instanceID = UUID().uuidString.lowercased()

    let lock = NSLock()
    let db: DB
    let channels: ClusterChannels
    let tunnels: TunnelFactory?
    let host: (any TunnelHost)?
    let logger: LogWriter
    let network: NetworkWatcher
    let authenticator: Authenticator

    private let onStatus: @Sendable (Daemonv1.GetStatusResponse) -> Void

    private var revision: UInt64 = 0
    private var domains: [String: DomainController] = [:]
    var ops: [String: Operation] = [:]
    private var jobs: [ObjectIdentifier: Job] = [:]
    private var tunnelDomain: String?
    private var isClosed = false

    public init(
        db: DB,
        device: DeviceInfo,
        channels: @escaping ChannelFactory = newClusterChannel,
        tunnels: TunnelFactory? = nil,
        host: (any TunnelHost)? = nil,
        onStatus: @escaping @Sendable (Daemonv1.GetStatusResponse) -> Void = { _ in },
        logger: LogWriter = LogWriter(),
        network: NetworkWatcher = NetworkWatcher()
    ) throws {
        let clusterChannels = ClusterChannels(channels)

        self.db = db
        self.channels = clusterChannels
        self.tunnels = tunnels
        self.host = host
        self.onStatus = onStatus
        self.logger = logger
        self.network = network
        self.authenticator = Authenticator(
            db: db,
            channels: { try clusterChannels.get($0) },
            device: device,
            logger: logger
        )

        try db.migrate()
        try loadDomains()
    }

    public func getStatus() async throws -> Daemonv1.GetStatusResponse {
        try await call {
            reconcile()

            return lock.withLock { getStatusLocked() }
        }
    }

    public func authenticateBrowser(_ domain: String) async throws -> Daemonv1.Operation {
        try await call {
            try getDomain(canonicalizeDomain(domain)).startAuthenticateBrowser([])
        }
    }

    public func authenticateToken(_ domain: String, _ authenticationToken: String) async throws -> Daemonv1.Operation {
        try await call {
            let canonical = try canonicalizeDomain(domain)

            if authenticationToken.isEmpty {
                throw invalidArgument("The authentication Token is not set")
            }

            return try getDomain(canonical).startAuthenticateToken(authenticationToken, [])
        }
    }

    public func completeAuthentication(_ operationID: String, _ callbackURL: String) async throws -> Daemonv1.Operation {
        try await call {
            if operationID.isEmpty {
                throw invalidArgument("The Operation ID is not set")
            }

            if callbackURL.isEmpty {
                throw invalidArgument("The callback URL is not set")
            }

            let (op, d) = try lock.withLock { () throws -> (Operation, DomainController?) in
                guard let op = ops[operationID] else {
                    throw StatusError(.notFound, "Unknown Operation: \(operationID)")
                }

                return (op, domains[op.domain])
            }

            guard let d else {
                throw StatusError(.notFound, "Unknown Cluster domain: \(op.domain)")
            }

            return try d.completeAuthentication(op, callbackURL)
        }
    }

    public func connect(_ domain: String) async throws -> Daemonv1.Operation {
        try await call {
            try findDomain(domain).startConnect(nil)
        }
    }

    public func disconnect(_ domain: String) async throws -> Daemonv1.Operation {
        try await call {
            try findDomain(domain).startDisconnect()
        }
    }

    public func logout(_ domain: String) async throws -> Daemonv1.Operation {
        try await call {
            try findDomain(domain).startLogout()
        }
    }

    public func deleteDomain(_ domain: String) async throws -> Daemonv1.Operation {
        try await call {
            try findDomain(domain).startDelete()
        }
    }

    public func getOperation(_ id: String) async throws -> Daemonv1.Operation {
        try await call {
            if id.isEmpty {
                throw invalidArgument("The Operation ID is not set")
            }

            return try lock.withLock {
                pruneOperations()

                guard let op = ops[id] else {
                    throw StatusError(.notFound, "Unknown Operation: \(id)")
                }

                return op.toPB()
            }
        }
    }

    public func cancelOperation(_ id: String) async throws -> Daemonv1.Operation {
        try await call {
            if id.isEmpty {
                throw invalidArgument("The Operation ID is not set")
            }

            let (ret, cancelFn) = try lock.withLock { () throws -> (Daemonv1.Operation, (@Sendable () -> Void)?) in
                guard let op = ops[id] else {
                    throw StatusError(.notFound, "Unknown Operation: \(id)")
                }

                if op.isDone {
                    return (op.toPB(), nil)
                }

                if !op.isCancellable {
                    throw StatusError(
                        .failedPrecondition,
                        "The \(String(describing: op.type).uppercased()) Operation cannot be canceled"
                    )
                }

                let cancelFn = op.cancelFn
                op.setCanceled("The Operation was canceled")
                notifyLocked()

                return (op.toPB(), cancelFn)
            }

            cancelFn?()

            return ret
        }
    }

    public func getAPICredential(_ domain: String) async throws -> Daemonv1.GetAPICredentialResponse {
        try await call {
            try await findDomain(domain).getAPICredential()
        }
    }

    public func updateDomainSettings(
        _ domain: String,
        _ settings: Daemonv1.DomainSettings
    ) async throws -> Daemonv1.DomainSettings {
        try await call {
            let canonical = try canonicalizeDomain(domain)
            _ = try getConnectOptions(settings.connectionOptions)

            return try getDomain(canonical).updateSettings(settings)
        }
    }

    public func setNetworkState(_ state: NetworkState) async {
        network.set(state)
    }

    public func close() async {
        let domains = lock.withLock {
            isClosed = true
            return Array(self.domains.values)
        }

        for itm in domains {
            await itm.close()
        }

        let jobs = lock.withLock { Array(self.jobs.values) }
        for itm in jobs {
            itm.cancel()
        }

        let deadline = ContinuousClock.now + disconnectTimeout
        for itm in jobs {
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                break
            }

            if !(await itm.join(timeout: remaining)) {
                break
            }
        }

        channels.close()

        lock.withLock {
            self.domains.removeAll()
        }
    }

    private func call<T>(_ fn: () async throws -> T) async throws -> T {
        if lock.withLock({ isClosed }) {
            throw StatusError(.unavailable, "The client is closed")
        }

        return try await fn()
    }

    func start(_ job: Job, _ fn: @escaping @Sendable () async -> Void) {
        let id = ObjectIdentifier(job)

        let isClosed = lock.withLock {
            jobs[id] = job
            return self.isClosed
        }

        job.start {
            await fn()
            self.lock.withLock {
                _ = self.jobs.removeValue(forKey: id)
            }
        }

        if isClosed {
            job.cancel()
        }
    }

    func launch(_ fn: @escaping @Sendable () async -> Void) {
        start(Job(), fn)
    }

    func update(_ fn: () -> Void) {
        lock.withLock {
            fn()
            notifyLocked()
        }
    }

    func updateIf(_ fn: () -> Bool) {
        lock.withLock {
            if fn() {
                notifyLocked()
            }
        }
    }

    func notifyLocked() {
        revision += 1
        onStatus(getStatusLocked())
    }

    private func getStatusLocked() -> Daemonv1.GetStatusResponse {
        pruneOperations()

        var ret = Daemonv1.GetStatusResponse()
        ret.instanceID = instanceID
        ret.revision = revision
        ret.updatedAt = Google_Protobuf_Timestamp(date: Date())
        ret.domains = domains.values.map { $0.toPB() }.sorted { $0.domain < $1.domain }

        return ret
    }

    private func loadDomains() throws {
        for (domain, itm) in try db.list() {
            guard let canonical = try? canonicalizeDomain(domain) else {
                logger.warn("Skipping an invalid stored domain: \(domain)")
                continue
            }

            if domains[canonical] != nil {
                logger.warn("Skipping a duplicate stored domain: \(domain)")
                continue
            }

            let d = DomainController(c: self, domain: canonical)
            d.settings = itm.hasSettings ? itm.settings : nil
            d.setAuthenticationFromState(itm)

            domains[canonical] = d
        }
    }

    private func reconcile() {
        let domainMap: [String: Configv1.State.Domain]
        do {
            domainMap = try db.list()
        } catch {
            logger.debug("Could not read the state to reconcile it: \(getErrorMessage(error))")
            return
        }

        var canonicalMap: [String: Configv1.State.Domain] = [:]
        for (domain, itm) in domainMap {
            if let canonical = try? canonicalizeDomain(domain) {
                canonicalMap[canonical] = itm
            }
        }

        updateIf {
            var isChanged = false

            for (domain, itm) in canonicalMap {
                guard let d = domains[domain] else {
                    let d = DomainController(c: self, domain: domain)
                    d.settings = itm.hasSettings ? itm.settings : nil
                    d.setAuthenticationFromState(itm)

                    domains[domain] = d
                    isChanged = true
                    continue
                }

                if !d.canReconcile() {
                    continue
                }

                if itm.hasSettings && d.settings != itm.settings {
                    d.settings = itm.settings
                    isChanged = true
                }

                if d.setAuthenticationFromState(itm) {
                    isChanged = true
                }
            }

            for (domain, d) in domains where canonicalMap[domain] == nil {
                if d.canReconcile() && d.setAuthenticationFromState(nil) {
                    isChanged = true
                }
            }

            return isChanged
        }
    }

    private func getDomain(_ domain: String) throws -> DomainController {
        try lock.withLock {
            if let ret = domains[domain] {
                if ret.isDeleting {
                    throw StatusError(.failedPrecondition, "The domain \(domain) is being deleted")
                }
                return ret
            }

            let itm: Configv1.State.Domain?
            do {
                itm = try db.get(domain)
            } catch {
                throw StatusError(.internal, "Could not read the local state: \(getErrorMessage(error))")
            }

            let ret = DomainController(c: self, domain: domain)

            if let itm {
                ret.settings = itm.hasSettings ? itm.settings : nil
                ret.setAuthenticationFromState(itm)
            }

            domains[domain] = ret

            return ret
        }
    }

    private func findDomain(_ arg: String) throws -> DomainController {
        let domain = try canonicalizeDomain(arg)

        return try lock.withLock {
            guard let ret = domains[domain] else {
                throw StatusError(.notFound, "Unknown Cluster domain: \(domain)")
            }

            if ret.isDeleting {
                throw StatusError(.failedPrecondition, "The domain \(domain) is being deleted")
            }

            return ret
        }
    }

    func removeDomainLocked(_ domain: String) {
        domains.removeValue(forKey: domain)
    }

    func pruneOperations() {
        let now = Date()

        ops = ops.filter { _, op in
            guard op.isDone, let completedAt = op.completedAt else {
                return true
            }

            return now.timeIntervalSince(completedAt) <= operationRetention
        }
    }

    func acquireTunnel(_ domain: String) throws {
        try lock.withLock {
            if isClosed {
                throw StatusError(.unavailable, "The client is closed")
            }

            if let tunnelDomain {
                throw StatusError(
                    .failedPrecondition,
                    "The domain \(tunnelDomain) is already connected. Only a single domain can be connected at a time"
                )
            }

            tunnelDomain = domain
        }
    }

    func releaseTunnelLocked(_ domain: String) {
        if tunnelDomain == domain {
            tunnelDomain = nil
        }
    }
}

final class ClusterChannels: Sendable {
    private let factory: ChannelFactory
    private let channels = Mutex<[String: any ClusterChannel]>([:])

    init(_ factory: @escaping ChannelFactory) {
        self.factory = factory
    }

    func get(_ domain: String) throws -> any ClusterChannel {
        try channels.withLock { itms in
            if let ret = itms[domain] {
                return ret
            }

            let ret = try factory(domain)
            itms[domain] = ret
            return ret
        }
    }

    func close() {
        let channels = self.channels.withLock { itms in
            let ret = Array(itms.values)
            itms.removeAll()
            return ret
        }

        for itm in channels {
            itm.close()
        }
    }
}
