import Foundation
import OcteliumCore
import OcteliumProto

public final class Authenticator: Sendable {
    private let db: DB
    private let channels: ChannelFactory
    private let device: DeviceInfo
    private let logger: LogWriter
    private let callTimeout: Duration
    private let now: @Sendable () -> Date

    public init(
        db: DB,
        channels: @escaping ChannelFactory,
        device: DeviceInfo,
        logger: LogWriter = LogWriter(),
        callTimeout: Duration = .seconds(20),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.db = db
        self.channels = channels
        self.device = device
        self.logger = logger
        self.callTimeout = callTimeout
        self.now = now
    }

    public func getAccessToken(_ domain: String) async throws -> String {
        guard let itm = try db.get(domain), hasValidRefreshToken(itm, now: now()) else {
            throw AuthenticationRequiredError()
        }

        if !needsNewAccessToken(itm, now: now()) {
            return itm.sessionToken.accessToken
        }

        let refreshToken = itm.sessionToken.refreshToken

        let ret: Authv1.SessionToken
        do {
            ret = try await channels(domain).authenticateWithRefreshToken(refreshToken: refreshToken, timeout: callTimeout)
        } catch let err as StatusError where err.code == .alreadyExists || err.code == .unauthenticated {
            if let renewed = getRenewedSessionToken(domain, refreshToken) {
                logger.debug("The session token of the domain \(domain) has already been renewed by another client")
                return renewed.accessToken
            }

            if err.code == .alreadyExists {
                return itm.sessionToken.accessToken
            }

            try db.deleteStaleSessionToken(domain, refreshToken: refreshToken)
            throw AuthenticationRequiredError()
        }

        try db.setSessionToken(domain, ret)

        return ret.accessToken
    }

    public func authenticate(
        _ domain: String,
        _ authenticationToken: String,
        scopes: [String],
        codeVerifier: Data? = nil
    ) async throws {
        let refreshToken = try db.getSessionToken(domain)?.refreshToken

        var req = Authv1.AuthenticateWithAuthenticationTokenRequest()
        req.authenticationToken = authenticationToken
        req.scopes = scopes

        if let codeVerifier {
            req.codeVerifier = codeVerifier
        }

        let ret = try await channels(domain).authenticateWithAuthenticationToken(
            req,
            refreshToken: refreshToken,
            timeout: callTimeout
        )

        try db.setSessionToken(domain, ret)

        do {
            try await doPostAuth(domain, ret)
        } catch {
            logger.debug("Could not doPostAuth for the domain \(domain): \(getErrorMessage(error))")
        }
    }

    public func logout(_ domain: String) async throws {
        guard let token = try db.getSessionToken(domain) else {
            return
        }

        do {
            try await channels(domain).logout(refreshToken: token.refreshToken, timeout: callTimeout)
        } catch let err as StatusError {
            if err.code != .unauthenticated {
                logger.debug("Could not log out at the Cluster of the domain \(domain): \(getErrorMessage(err))")
            }
        }

        try db.deleteSessionToken(domain)
    }

    private func getRenewedSessionToken(_ domain: String, _ refreshToken: String) -> Authv1.SessionToken? {
        guard let itm = try? db.get(domain), itm.sessionToken.refreshToken != refreshToken,
              hasValidRefreshToken(itm, now: now()), !needsNewAccessToken(itm, now: now()) else {
            return nil
        }

        return itm.sessionToken
    }

    private func doPostAuth(_ domain: String, _ token: Authv1.SessionToken) async throws {
        let st = try await channels(domain).getStatus(accessToken: token.accessToken, timeout: callTimeout)

        logger.info("You are now authenticated to \(domain) as \(printResourceNameWithDisplay(st.user.metadata))")

        if st.user.spec.type != .human {
            return
        }

        do {
            try await registerDevice(domain, token.refreshToken)
        } catch {
            logger.debug("Could not register the Device to the domain \(domain): \(getErrorMessage(error))")
        }
    }

    private func registerDevice(_ domain: String, _ refreshToken: String) async throws {
        let channel = try channels(domain)

        var req = Authv1.RegisterDeviceBeginRequest()
        req.info.osType = .ios
        req.info.hostname = getDeviceHostname(device.name)
        req.info.id = getDeviceID(device.installationID)

        let resp: Authv1.RegisterDeviceBeginResponse
        do {
            resp = try await channel.registerDeviceBegin(req, refreshToken: refreshToken, timeout: callTimeout)
        } catch let err as StatusError where err.code == .alreadyExists {
            logger.debug("The Device is already registered to the domain \(domain)")
            return
        }

        if !resp.requests.isEmpty {
            throw ClientError("The Device registration requests are not supported on this platform")
        }

        var finish = Authv1.RegisterDeviceFinishRequest()
        finish.uid = resp.uid

        try await channel.registerDeviceFinish(finish, refreshToken: refreshToken, timeout: callTimeout)

        logger.info("The Device is successfully registered to the domain \(domain)")
    }
}
