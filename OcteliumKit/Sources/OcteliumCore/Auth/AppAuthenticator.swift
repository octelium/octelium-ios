#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import OcteliumProto
import Synchronization

public let codeVerifierLen = 32
public let webAuthenticationTimeout: TimeInterval = 300

public func generateCodeVerifier() -> Data {
    var rng = SystemRandomNumberGenerator()
    return Data((0..<codeVerifierLen).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &rng) })
}

public final class AppAuthenticator: Sendable {
    private struct State {
        var response: Authv1.ClientLoginResponse?
        var err: (any Error)?
        var waiter: CheckedContinuation<Authv1.ClientLoginResponse, any Error>?
    }

    public let domain: String
    public let scopes: [String]
    public let codeVerifier: Data

    private let codeChallenge: Data
    private let state = Mutex(State())

    public init(domain: String, scopes: [String] = [], codeVerifier: Data = generateCodeVerifier()) {
        self.domain = domain
        self.scopes = scopes
        self.codeVerifier = codeVerifier
        self.codeChallenge = Data(SHA256.hash(data: codeVerifier))
    }

    public func getLoginURL() -> String {
        var req = Authv1.ClientLoginRequest()
        req.apiVersion = .v1
        req.codeChallenge = codeChallenge
        req.callbackType = .app

        let data: Data = (try? req.serializedBytes()) ?? Data()

        return "https://\(domain)/login?octelium_req=\(encodeBase64URL(data))"
    }

    public func getLoginResponse(_ callbackURL: String) throws -> Authv1.ClientLoginResponse {
        guard let u = parseURI(callbackURL), u.scheme.lowercased() == authCallbackScheme,
              u.authority == nil, u.path == authCallbackPath else {
            throw StatusError(.invalidArgument, "Invalid callback URL")
        }

        guard let encoded = getQueryParam(u.query, "octelium_response") else {
            throw StatusError(.invalidArgument, "No login response is set")
        }

        guard let data = decodeBase64URL(encoded) else {
            throw StatusError(.invalidArgument, "Invalid login response encoding")
        }

        let ret: Authv1.ClientLoginResponse
        do {
            ret = try Authv1.ClientLoginResponse(serializedBytes: data)
        } catch {
            throw StatusError(.invalidArgument, "Could not unmarshal the login response")
        }

        if ret.authenticationToken.isEmpty {
            throw StatusError(.invalidArgument, "No authentication token is set")
        }

        if !isEqual(ret.codeChallenge, codeChallenge) {
            throw StatusError(.invalidArgument, "The callback does not belong to this authentication")
        }

        return ret
    }

    public func complete(_ arg: Authv1.ClientLoginResponse) throws {
        let waiter = try state.withLock { st in
            if st.response != nil {
                throw StatusError(.failedPrecondition, "The authentication is already completed")
            }

            st.response = arg

            let ret = st.waiter
            st.waiter = nil
            return ret
        }

        waiter?.resume(returning: arg)
    }

    public func wait(timeout: TimeInterval = webAuthenticationTimeout) async throws -> Authv1.ClientLoginResponse {
        let timer = Task {
            try await Task.sleep(for: .seconds(timeout))
            self.fail(AuthenticationTimedOutError())
        }

        defer {
            timer.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let ret: Result<Authv1.ClientLoginResponse, any Error>? = state.withLock { st in
                    if let response = st.response {
                        return .success(response)
                    }

                    if let err = st.err {
                        st.err = nil
                        return .failure(err)
                    }

                    st.waiter = cont
                    return nil
                }

                if let ret {
                    cont.resume(with: ret)
                }
            }
        } onCancel: {
            fail(CancellationError())
        }
    }

    private func fail(_ err: any Error) {
        let waiter: CheckedContinuation<Authv1.ClientLoginResponse, any Error>? = state.withLock { st in
            guard let ret = st.waiter else {
                st.err = err
                return nil
            }

            st.waiter = nil
            return ret
        }

        waiter?.resume(throwing: err)
    }
}

public func encodeBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private let base64URLChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

public func decodeBase64URL(_ arg: String) -> Data? {
    var ret = arg
    while ret.hasSuffix("=") {
        ret.removeLast()
    }

    if !ret.allSatisfy({ base64URLChars.contains($0) }) {
        return nil
    }

    ret = ret.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    ret += String(repeating: "=", count: (4 - ret.count % 4) % 4)

    return Data(base64Encoded: ret)
}

private func getQueryParam(_ query: String?, _ name: String) -> String? {
    for itm in (query ?? "").split(separator: "&", omittingEmptySubsequences: false) {
        let parts = itm.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if decodeQueryComponent(parts[0]) == name {
            return decodeQueryComponent(parts.count > 1 ? parts[1] : "")
        }
    }

    return nil
}

private func decodeQueryComponent(_ arg: Substring) -> String? {
    String(arg).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
}

private func isEqual(_ a: Data, _ b: Data) -> Bool {
    if a.count != b.count {
        return false
    }

    var ret: UInt8 = 0
    for (x, y) in zip(a, b) {
        ret |= x ^ y
    }

    return ret == 0
}
