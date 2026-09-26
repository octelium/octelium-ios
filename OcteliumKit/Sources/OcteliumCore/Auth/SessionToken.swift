#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import OcteliumProto

public let maxDeviceHostnameLen = 32

public struct AuthenticationRequiredError: Error, Equatable, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "Interactive authentication is not available in this mode. Please authenticate yourself first"
    }
}

public struct AuthenticationTimedOutError: Error, Equatable, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "You have not authenticated yourself after 5 minutes. Please authenticate yourself again."
    }
}

public struct DeviceInfo: Equatable, Sendable {
    public let installationID: String
    public let name: String

    public init(installationID: String, name: String) {
        self.installationID = installationID
        self.name = name
    }
}

public func getDeviceID(_ installationID: String) -> String {
    SHA256.hash(data: Data(installationID.utf8)).map { String(format: "%02x", $0) }.joined()
}

public func getDeviceHostname(_ arg: String) -> String {
    let ret = arg.trimmingCharacters(in: .whitespacesAndNewlines)
    if ret.utf8.count <= maxDeviceHostnameLen {
        return ret
    }

    var size = 0
    var scalars = String.UnicodeScalarView()

    for c in ret.unicodeScalars {
        let n = UTF8.width(c)
        if size + n > maxDeviceHostnameLen {
            break
        }

        size += n
        scalars.append(c)
    }

    return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
}

public func getAccessTokenRenewAt(_ arg: Configv1.State.Domain?) -> Date? {
    guard let arg, let expiresAt = getAccessTokenExpiresAt(arg) else {
        return nil
    }

    return expiresAt.addingTimeInterval(getExpirationGap(arg.sessionToken.expiresIn))
}

public func getAccessTokenExpiresAt(_ arg: Configv1.State.Domain?) -> Date? {
    guard let arg, arg.hasSessionToken, arg.hasSessionTokenSetAt, arg.sessionToken.expiresIn != 0 else {
        return nil
    }

    return arg.sessionTokenSetAt.date.addingTimeInterval(TimeInterval(arg.sessionToken.expiresIn))
}

public func getRefreshTokenExpiresAt(_ arg: Configv1.State.Domain?) -> Date? {
    guard let arg, arg.hasSessionToken, arg.hasSessionTokenSetAt, arg.sessionToken.refreshTokenExpiresIn != 0 else {
        return nil
    }

    return arg.sessionTokenSetAt.date.addingTimeInterval(TimeInterval(arg.sessionToken.refreshTokenExpiresIn))
}

public func hasValidRefreshToken(_ arg: Configv1.State.Domain?, now: Date = Date()) -> Bool {
    guard let expiresAt = getRefreshTokenExpiresAt(arg) else {
        return false
    }

    return now < expiresAt
}

public func needsNewAccessToken(_ arg: Configv1.State.Domain?, now: Date = Date()) -> Bool {
    guard let arg, arg.hasSessionToken, arg.hasSessionTokenSetAt else {
        return true
    }

    guard let renewAt = getAccessTokenRenewAt(arg) else {
        return false
    }

    return now > renewAt
}

private func getExpirationGap(_ expiresIn: Int64) -> TimeInterval {
    if expiresIn < 3600 {
        return -600
    }

    return -TimeInterval(expiresIn / 2)
}
