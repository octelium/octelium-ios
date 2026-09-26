import Foundation
import OcteliumCore
import OcteliumProto
import SwiftProtobuf

let clusterCallTimeout: Duration = .seconds(10)
let disconnectTimeout: Duration = .seconds(30)
let apiCredentialTimeout: Duration = .seconds(30)

let refreshMinInterval: TimeInterval = 60
let refreshMaxInterval: TimeInterval = 3600

final class DomainController: @unchecked Sendable {
    private let c: OcteliumClient
    let domain: String

    private var authState: Daemonv1.AuthenticationStatus.State = .loggedOut
    private var authenticatedAt: Google_Protobuf_Timestamp?
    private var authExpiresAt: Google_Protobuf_Timestamp?
    private var appAuth: AppAuthenticator?

    private var connState: Daemonv1.ConnectionStatus.State = .disconnected
    private var connectedAt: Google_Protobuf_Timestamp?
    private var connection: Connection?
    private var connOpts: Daemonv1.ConnectionOptions?

    var settings: Daemonv1.DomainSettings?
    private var op: Operation?
    private var lastErr: Daemonv1.Error?

    private(set) var isDeleting = false

    private var connGen: UInt64 = 0
    private var connJob: Job?
    private var refreshJob: Job?

    private let credLock = AsyncMutex()

    init(c: OcteliumClient, domain: String) {
        self.c = c
        self.domain = domain
    }

    @discardableResult
    func setAuthenticationFromState(_ itm: Configv1.State.Domain?) -> Bool {
        let isValid = hasValidRefreshToken(itm)

        let state: Daemonv1.AuthenticationStatus.State = isValid ? .authenticated : .loggedOut
        let at = isValid ? itm?.sessionTokenSetAt : nil
        let expiresAt = isValid ? getRefreshTokenExpiresAt(itm).map { Google_Protobuf_Timestamp(date: $0) } : nil

        if authState == state && authenticatedAt == at && authExpiresAt == expiresAt {
            return false
        }

        authState = state
        authenticatedAt = at
        authExpiresAt = expiresAt

        return true
    }

    func canReconcile() -> Bool {
        if isDeleting {
            return false
        }

        switch authState {
        case .authenticating, .loggingOut:
            return false
        default:
            return true
        }
    }

    @discardableResult
    private func reloadAuthentication() -> Bool {
        let itm: Configv1.State.Domain?
        do {
            itm = try c.db.get(domain)
        } catch {
            c.logger.debug("Could not read the stored credentials of the domain \(domain): \(getErrorMessage(error))")
            itm = nil
        }

        return setAuthenticationFromState(itm)
    }

    func toPB() -> Daemonv1.DomainState {
        var ret = Daemonv1.DomainState()
        ret.domain = domain

        ret.authentication.state = authState
        if let authenticatedAt {
            ret.authentication.authenticatedAt = authenticatedAt
        }
        if let authExpiresAt {
            ret.authentication.expiresAt = authExpiresAt
        }

        ret.connection.state = connState
        if let connectedAt {
            ret.connection.connectedAt = connectedAt
        }
        if let connOpts {
            ret.connection.options = connOpts
        }
        setConnectionStatusFromConnection(&ret.connection, connection)

        ret.settings = getDomainSettings()

        if let lastErr {
            ret.lastError = lastErr
        }

        if let op {
            ret.lastOperation = op.toPB()
        }

        return ret
    }

    private func getDomainSettings() -> Daemonv1.DomainSettings {
        if let settings {
            return settings
        }

        var ret = Daemonv1.DomainSettings()
        ret.domain = domain
        return ret
    }

    private func beginOperation(
        _ type: Daemonv1.Operation.TypeEnum,
        cancelFn: (@Sendable () -> Void)?,
        canSupersede: Bool = false,
        onBegin: (Operation) -> Void = { _ in }
    ) throws -> Operation {
        let (ret, cancelActiveFn) = try c.lock.withLock { () throws -> (Operation, (@Sendable () -> Void)?) in
            if isDeleting && type != .delete {
                throw StatusError(.failedPrecondition, "The domain \(domain) is being deleted")
            }

            var cancelActiveFn: (@Sendable () -> Void)?

            if let cur = op, !cur.isDone {
                if !canSupersede || !cur.isCancellable {
                    throw StatusError(.failedPrecondition, "There is already an active Operation for the domain \(domain)")
                }

                cancelActiveFn = cur.cancelFn
                cur.setCanceled("The Operation was superseded")
            }

            c.pruneOperations()

            let ret = Operation(domain: domain, type: type, cancelFn: cancelFn)
            ret.setState(.running)

            op = ret
            c.ops[ret.id] = ret

            onBegin(ret)

            c.notifyLocked()

            return (ret, cancelActiveFn)
        }

        cancelActiveFn?()

        return ret
    }

    private func getOperationPB(_ op: Operation) -> Daemonv1.Operation {
        c.lock.withLock { op.toPB() }
    }

    func startAuthenticateBrowser(_ scopes: [String]) throws -> Daemonv1.Operation {
        let appAuth = AppAuthenticator(domain: domain, scopes: scopes)
        let job = Job()

        let op = try beginOperation(.authenticate, cancelFn: { job.cancel() }) { op in
            var action = Daemonv1.Action()
            action.openURL.url = appAuth.getLoginURL()
            action.expiresAt = Google_Protobuf_Timestamp(date: Date().addingTimeInterval(webAuthenticationTimeout))

            op.action = action
            op.setState(.waitingForUser)
            self.appAuth = appAuth
            authState = .authenticating
            lastErr = nil
        }

        c.start(job) { [self] in
            let err = await catchError {
                let resp = try await appAuth.wait()
                try await c.authenticator.authenticate(
                    domain,
                    resp.authenticationToken,
                    scopes: scopes,
                    codeVerifier: appAuth.codeVerifier
                )
            }

            finishAuthenticate(op, err)
        }

        return getOperationPB(op)
    }

    func completeAuthentication(_ op: Operation, _ callbackURL: String) throws -> Daemonv1.Operation {
        let appAuth = try c.lock.withLock { try getWaitingAppAuth(op) }

        let resp: Authv1.ClientLoginResponse
        do {
            resp = try appAuth.getLoginResponse(callbackURL)
        } catch {
            throw invalidArgument("Invalid authentication callback URL: \(getErrorMessage(error))")
        }

        return try c.lock.withLock {
            if try getWaitingAppAuth(op) !== appAuth {
                throw getNotWaitingError(op)
            }

            try appAuth.complete(resp)

            self.appAuth = nil
            op.action = nil
            op.setState(.running)
            c.notifyLocked()

            return op.toPB()
        }
    }

    private func getWaitingAppAuth(_ op: Operation) throws -> AppAuthenticator {
        guard self.op === op, op.state == .waitingForUser, let ret = appAuth else {
            throw getNotWaitingError(op)
        }

        return ret
    }

    private func getNotWaitingError(_ op: Operation) -> StatusError {
        StatusError(.failedPrecondition, "The Operation \(op.id) is not waiting for an authentication callback")
    }

    func startAuthenticateToken(_ authenticationToken: String, _ scopes: [String]) throws -> Daemonv1.Operation {
        let job = Job()

        let op = try beginOperation(.authenticate, cancelFn: { job.cancel() }) { _ in
            authState = .authenticating
            lastErr = nil
        }

        c.start(job) { [self] in
            let err = await catchError {
                try await c.authenticator.authenticate(domain, authenticationToken, scopes: scopes)
            }

            finishAuthenticate(op, err)
        }

        return getOperationPB(op)
    }

    private func finishAuthenticate(_ op: Operation, _ arg: (any Error)?) {
        var err = arg

        c.update {
            let isCurrent = self.op === op
            if isCurrent {
                appAuth = nil
            }

            if isCurrent || isAuthenticationReleased() {
                reloadAuthentication()
            }

            if err == nil && authState != .authenticated {
                err = ClientError("The Cluster did not provide usable credentials")
            }

            if let err {
                let authErr = getError(err, .authenticationFailed)
                if isCurrent && authErr.code != .operationCanceled {
                    lastErr = authErr
                }
                op.setFailed(authErr)
                return
            }

            if isCurrent {
                lastErr = nil
            }
            op.setState(.succeeded)
        }

        if let err {
            c.logger.debug("Could not authenticate to the domain \(domain): \(getErrorMessage(err))")
            return
        }

        c.logger.debug("Successfully authenticated to the domain \(domain)")
    }

    private func isAuthenticationReleased() -> Bool {
        if authState != .authenticating {
            return false
        }

        guard let op else {
            return true
        }

        return op.isDone || op.type != .authenticate
    }

    func startConnect(_ arg: Daemonv1.ConnectionOptions?) throws -> Daemonv1.Operation {
        let (curAuthState, curConnState, opts) = c.lock.withLock {
            if canReconcile() && reloadAuthentication() {
                c.notifyLocked()
            }

            return (authState, connState, arg ?? getDomainSettings().connectionOptions)
        }

        if curAuthState != .authenticated {
            throw getUnauthenticatedError()
        }

        switch curConnState {
        case .disconnected:
            break
        case .disconnecting:
            throw StatusError(.failedPrecondition, "The domain \(domain) is still disconnecting")
        default:
            throw StatusError(.failedPrecondition, "The domain \(domain) is already connected")
        }

        let connectOpts = try getConnectOptions(opts)

        guard let tunnels = c.tunnels, let host = c.host else {
            throw StatusError(.failedPrecondition, "Only the packet tunnel provider can establish Connections")
        }

        try c.acquireTunnel(domain)

        let job = Job()
        var gen: UInt64 = 0

        let op: Operation
        do {
            op = try beginOperation(.connect, cancelFn: { job.cancel() }) { _ in
                connGen += 1
                gen = connGen
                connState = .connecting
                connOpts = normalizeConnectionOptions(opts)
                connJob = job
                lastErr = nil
            }
        } catch {
            c.lock.withLock { c.releaseTunnelLocked(domain) }
            throw error
        }

        let curGen = gen

        let connector = Connector(
            domain: domain,
            opts: connectOpts,
            channel: { [self] in try c.channels.get(domain) },
            credentials: { [self] in try await getConnectAccessToken() },
            tunnels: tunnels,
            host: host,
            network: c.network,
            logger: c.logger,
            onEvent: { [self] ev in onConnectEvent(op, curGen, ev, job) }
        )

        c.start(job) { [self] in
            var runErr: (any Error)?
            do {
                try await connector.run()
            } catch {
                if !Task.isCancelled {
                    runErr = error
                }
            }

            finishConnect(op, curGen, runErr ?? job.cause)
        }

        return getOperationPB(op)
    }

    private func finishConnect(_ op: Operation, _ gen: UInt64, _ err: (any Error)?) {
        stopRefreshLoop()

        c.update {
            c.releaseTunnelLocked(domain)

            if connGen == gen {
                connState = .disconnected
                connectedAt = nil
                connection = nil
                connOpts = nil
                connJob = nil

                if let err {
                    lastErr = getError(err, .connectionFailed)
                }
            }

            if !op.isDone {
                if let err {
                    op.setFailed(getError(err, .connectionFailed))
                } else {
                    op.setCanceled("The Connection was closed")
                }
            }
        }

        if let err {
            c.logger.warn("The Connection of the domain \(domain) failed: \(getErrorMessage(err))")
        }
    }

    private func onConnectEvent(_ op: Operation, _ gen: UInt64, _ ev: ConnectEvent, _ job: Job) {
        var startRefresh = false
        var stopErr: (any Error)?

        c.update {
            if connGen != gen {
                return
            }

            switch ev {
            case .connecting:
                connState = .connecting
            case .connected(let arg):
                connState = .connected
                connection = arg
                if connectedAt == nil {
                    connectedAt = Google_Protobuf_Timestamp(date: Date())
                }
                lastErr = nil
                op.setState(.succeeded)
                startRefresh = true
            case .reconnecting(_, let arg):
                connState = .reconnecting
                connection = arg
            }

            let err: (any Error)? = switch ev {
            case .connecting(let arg): arg
            case .reconnecting(let arg, _): arg
            case .connected: nil
            }

            guard let err else {
                return
            }

            let connErr = getError(err, .connectionFailed)
            lastErr = connErr

            if connErr.code == .authenticationRequired {
                stopErr = err
                if canReconcile() {
                    reloadAuthentication()
                }
            }
        }

        if let stopErr {
            c.logger.debug("Stopping the Connection of the domain \(domain) since authentication is required")
            job.cancel(stopErr)
            return
        }

        if startRefresh {
            startRefreshLoop()
        }
    }

    func startDisconnect() throws -> Daemonv1.Operation {
        let op = try beginOperation(.disconnect, cancelFn: nil, canSupersede: true)

        let job = c.lock.withLock {
            let job = connJob
            if job != nil {
                connState = .disconnecting
            }
            c.notifyLocked()
            return job
        }

        guard let job else {
            c.update {
                lastErr = nil
                op.setState(.succeeded)
            }
            return getOperationPB(op)
        }

        c.launch { [self] in
            let err = await catchError {
                try await doDisconnect(job)
            }

            c.update {
                if let err {
                    let e = getError(err, .internal)
                    lastErr = e
                    op.setFailed(e)
                    return
                }

                lastErr = nil
                op.setState(.succeeded)
            }
        }

        return getOperationPB(op)
    }

    private func doDisconnect(_ job: Job) async throws {
        job.cancel()

        var ret: (any Error)?
        if !(await job.join(timeout: disconnectTimeout)) {
            c.logger.warn("Timed out waiting for the Connection of the domain \(domain) to be closed")
            ret = ClientError("Timed out waiting for the Connection of the domain \(domain) to be closed")
        }

        if hasCredentials() {
            do {
                let isDone = try await withTimeout(clusterCallTimeout) { [self] in
                    let token = try await getAccessToken()
                    try await c.channels.get(domain).disconnect(accessToken: token, timeout: clusterCallTimeout)
                    return true
                }

                if isDone == nil {
                    c.logger.debug("Timed out disconnecting at the Cluster of the domain \(domain)")
                }
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                c.logger.debug("Could not disconnect at the Cluster of the domain \(domain): \(getErrorMessage(error))")
            }
        }

        if let ret {
            throw ret
        }
    }

    func startLogout() throws -> Daemonv1.Operation {
        let op = try beginOperation(.logout, cancelFn: nil, canSupersede: true)

        let job = c.lock.withLock {
            let job = connJob
            if job != nil {
                connState = .disconnecting
            }
            authState = .loggingOut
            c.notifyLocked()
            return job
        }

        c.launch { [self] in
            let err = await catchError {
                try await doDisconnectAndLogout(job)
            }

            c.update {
                reloadAuthentication()

                if let err {
                    let e = getError(err, .internal)
                    lastErr = e
                    op.setFailed(e)
                    return
                }

                lastErr = nil
                op.setState(.succeeded)
            }
        }

        return getOperationPB(op)
    }

    private func doDisconnectAndLogout(_ job: Job?) async throws {
        var ret: (any Error)?
        if let job {
            ret = await catchError {
                try await doDisconnect(job)
            }
        }

        try await doLogout()

        if let ret {
            throw ret
        }
    }

    private func doLogout() async throws {
        stopRefreshLoop()

        try await credLock.withLock {
            if !hasCredentials() {
                return
            }

            try await c.authenticator.logout(domain)
        }
    }

    private func hasCredentials() -> Bool {
        (try? c.db.getSessionToken(domain)) != nil
    }

    func startDelete() throws -> Daemonv1.Operation {
        let op = try beginOperation(.delete, cancelFn: nil, canSupersede: true)

        let job = c.lock.withLock {
            isDeleting = true
            let job = connJob
            if job != nil {
                connState = .disconnecting
            }
            c.notifyLocked()
            return job
        }

        c.launch { [self] in
            let err = await catchError {
                try await doDelete(job)
            }

            c.update {
                if let err {
                    isDeleting = false
                    reloadAuthentication()
                    let e = getError(err, .internal)
                    lastErr = e
                    op.setFailed(e)
                    return
                }

                c.removeDomainLocked(domain)
                op.setState(.succeeded)
            }
        }

        return getOperationPB(op)
    }

    private func doDelete(_ job: Job?) async throws {
        try await doDisconnectAndLogout(job)

        do {
            try c.db.delete(domain)
        } catch {
            throw ClientError("Could not delete the local state: \(getErrorMessage(error))", cause: error)
        }
    }

    func updateSettings(_ arg: Daemonv1.DomainSettings) throws -> Daemonv1.DomainSettings {
        var ret = Daemonv1.DomainSettings()
        ret.domain = domain
        ret.autoConnect = arg.autoConnect

        if arg.hasConnectionOptions {
            ret.connectionOptions = arg.connectionOptions
        }

        do {
            try c.db.setDomainSettings(domain, ret)
        } catch {
            throw StatusError(.internal, "Could not store the settings: \(getErrorMessage(error))")
        }

        c.update {
            settings = ret
        }

        return ret
    }

    func getAPICredential() async throws -> Daemonv1.GetAPICredentialResponse {
        let curAuthState = c.lock.withLock { authState }

        switch curAuthState {
        case .authenticated, .authenticating:
            break
        default:
            throw getUnauthenticatedError()
        }

        try checkNetwork()

        let accessToken: String
        do {
            accessToken = try await getAccessTokenWithTimeout()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }

            c.update {
                reloadAuthentication()
                lastErr = getError(error, .authenticationFailed)
            }

            let code = getStatusCode(error)

            if error is AuthenticationRequiredError || code == .unauthenticated {
                throw getUnauthenticatedError()
            }

            if code == .unavailable || code == .deadlineExceeded {
                throw error
            }

            throw StatusError(.internal, "Could not get an access token: \(getErrorMessage(error))")
        }

        if accessToken.isEmpty {
            throw getUnauthenticatedError()
        }

        var ret = Daemonv1.GetAPICredentialResponse()
        ret.accessToken = accessToken

        if let itm = try? c.db.get(domain) {
            if let expiresAt = getAccessTokenExpiresAt(itm) {
                ret.expiresAt = Google_Protobuf_Timestamp(date: expiresAt)
            }

            c.updateIf {
                var isChanged = setAuthenticationFromState(itm)
                if lastErr != nil {
                    lastErr = nil
                    isChanged = true
                }

                return isChanged
            }
        }

        return ret
    }

    private func getConnectAccessToken() async throws -> String {
        try checkNetwork()
        return try await getAccessTokenWithTimeout()
    }

    private func checkNetwork() throws {
        if !c.network.isAvailable && isRefreshRequired() {
            throw StatusError(.unavailable, "The network is not available to renew the access token of the domain \(domain)")
        }
    }

    private func getAccessTokenWithTimeout() async throws -> String {
        let ret = try await withTimeout(apiCredentialTimeout) { [self] in
            try await getAccessToken()
        }

        guard let ret else {
            throw StatusError(.deadlineExceeded, "Timed out getting an access token for the domain \(domain)")
        }

        return ret
    }

    private func getAccessToken() async throws -> String {
        try await credLock.withLock {
            try await c.authenticator.getAccessToken(domain)
        }
    }

    private func getUnauthenticatedError() -> StatusError {
        StatusError(.unauthenticated, "You are not authenticated to the domain \(domain)")
    }

    private func isRefreshRequired() -> Bool {
        let itm: Configv1.State.Domain?
        do {
            itm = try c.db.get(domain)
        } catch {
            return false
        }

        return hasValidRefreshToken(itm) && needsNewAccessToken(itm)
    }

    private func startRefreshLoop() {
        let job = Job()

        let isStarted = c.lock.withLock {
            if refreshJob != nil {
                return false
            }

            refreshJob = job
            return true
        }

        if !isStarted {
            return
        }

        c.start(job) { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(getRefreshWait()))
                if Task.isCancelled {
                    return
                }

                if !c.network.isAvailable {
                    continue
                }

                do {
                    _ = try await getAPICredential()
                } catch {
                    if Task.isCancelled {
                        return
                    }
                    c.logger.debug("Could not renew the access token of the domain \(domain): \(getErrorMessage(error))")
                }
            }
        }
    }

    private func getRefreshWait() -> TimeInterval {
        let itm: Configv1.State.Domain?
        do {
            itm = try c.db.get(domain)
        } catch {
            return refreshMinInterval
        }

        guard let renewAt = getAccessTokenRenewAt(itm) else {
            return refreshMaxInterval
        }

        return min(max(renewAt.timeIntervalSinceNow, refreshMinInterval), refreshMaxInterval)
    }

    private func stopRefreshLoop() {
        let job = c.lock.withLock {
            let ret = refreshJob
            refreshJob = nil
            return ret
        }

        job?.cancel()
    }

    func close() async {
        stopRefreshLoop()

        guard let job = c.lock.withLock({ connJob }) else {
            return
        }

        job.cancel()

        if !(await job.join(timeout: disconnectTimeout)) {
            c.logger.warn("Timed out waiting for the Connection of the domain \(domain) to be closed")
        }
    }
}
