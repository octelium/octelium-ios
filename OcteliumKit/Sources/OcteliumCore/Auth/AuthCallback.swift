import Foundation
import OcteliumProto

public let maxCallbackURLLength = 16 * 1024

public let authCallbackScheme = "com.octelium.client"
public let authCallbackPath = "/callback/success"
public let authCallbackURL = "\(authCallbackScheme):\(authCallbackPath)"

public struct ParsedURI: Equatable, Sendable {
    public let scheme: String
    public let authority: String?
    public let userInfo: String?
    public let host: String?
    public let path: String
    public let query: String?
    public let fragment: String?
}

private let unreservedChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
private let subDelimChars = Set("!$&'()*+,;=")
private let hexChars = Set("0123456789abcdefABCDEF")

private func isValidURIComponent(_ arg: Substring, extra: Set<Character>) -> Bool {
    var idx = arg.startIndex

    while idx < arg.endIndex {
        let c = arg[idx]

        if c == "%" {
            let first = arg.index(after: idx)
            guard first < arg.endIndex, hexChars.contains(arg[first]) else {
                return false
            }

            let second = arg.index(after: first)
            guard second < arg.endIndex, hexChars.contains(arg[second]) else {
                return false
            }

            idx = arg.index(after: second)
            continue
        }

        if !unreservedChars.contains(c) && !subDelimChars.contains(c) && !extra.contains(c) {
            return false
        }

        idx = arg.index(after: idx)
    }

    return true
}

public func parseURI(_ arg: String) -> ParsedURI? {
    guard let colon = arg.firstIndex(of: ":") else {
        return nil
    }

    let scheme = arg[..<colon]
    guard let first = scheme.first, first.isASCII, first.isLetter,
          scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else {
        return nil
    }

    var rest = arg[arg.index(after: colon)...]

    var fragment: Substring?
    if let idx = rest.firstIndex(of: "#") {
        fragment = rest[rest.index(after: idx)...]
        rest = rest[..<idx]
    }

    var query: Substring?
    if let idx = rest.firstIndex(of: "?") {
        query = rest[rest.index(after: idx)...]
        rest = rest[..<idx]
    }

    var authority: Substring?
    if rest.hasPrefix("//") {
        let afterSlashes = rest.index(rest.startIndex, offsetBy: 2)
        let end = rest[afterSlashes...].firstIndex(of: "/") ?? rest.endIndex
        authority = rest[afterSlashes..<end]
        rest = rest[end...]
    }

    let pathChars: Set<Character> = [":", "@", "/"]
    let queryChars: Set<Character> = [":", "@", "/", "?"]

    guard isValidURIComponent(rest, extra: pathChars) else {
        return nil
    }

    if let query, !isValidURIComponent(query, extra: queryChars) {
        return nil
    }

    if let fragment, !isValidURIComponent(fragment, extra: queryChars) {
        return nil
    }

    var userInfo: Substring?
    var host: Substring?
    if let authority {
        var hostPort = authority
        if let at = authority.lastIndex(of: "@") {
            userInfo = authority[..<at]
            hostPort = authority[authority.index(after: at)...]
        }

        if hostPort.hasPrefix("[") {
            guard let end = hostPort.firstIndex(of: "]") else {
                return nil
            }
            host = hostPort[hostPort.startIndex...end]
        } else if let idx = hostPort.lastIndex(of: ":") {
            host = hostPort[..<idx]
            guard hostPort[hostPort.index(after: idx)...].allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
        } else {
            host = hostPort
        }

        if let userInfo, !isValidURIComponent(userInfo, extra: [":"]) {
            return nil
        }

        if let host, !host.hasPrefix("["), !isValidURIComponent(host, extra: []) {
            return nil
        }
    }

    return ParsedURI(
        scheme: String(scheme),
        authority: authority.map(String.init),
        userInfo: userInfo.map(String.init),
        host: host.map(String.init),
        path: String(rest),
        query: query.map(String.init),
        fragment: fragment.map(String.init)
    )
}

public func isAuthCallbackURL(_ url: String, _ expected: String) -> Bool {
    if url.isEmpty || url.count > maxCallbackURLLength {
        return false
    }

    guard let u = parseURI(url), let e = parseURI(expected) else {
        return false
    }

    return u.scheme.lowercased() == e.scheme.lowercased() &&
        u.authority == nil &&
        u.path.hasPrefix("/") &&
        u.path == e.path &&
        u.fragment == nil
}

public func getWaitingAuthentications(_ status: Daemonv1.GetStatusResponse?) -> [Daemonv1.Operation] {
    (status?.domains ?? [])
        .filter(\.hasLastOperation)
        .map(\.lastOperation)
        .filter { $0.type == .authenticate && $0.state == .waitingForUser }
}

public func getAuthCallbackCandidates(_ status: Daemonv1.GetStatusResponse?, _ preferredOperationID: String?) -> [String] {
    var ret: [String] = []

    if let preferredOperationID, !preferredOperationID.isEmpty {
        ret.append(preferredOperationID)
    }

    for itm in getWaitingAuthentications(status) where !ret.contains(itm.id) {
        ret.append(itm.id)
    }

    return ret
}

public func isLoginURLAllowed(_ url: String) -> Bool {
    guard let u = parseURI(url) else {
        return false
    }

    return u.scheme.lowercased() == "https" && !(u.host ?? "").isEmpty && u.userInfo == nil
}
