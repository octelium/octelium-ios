import Foundation
import OcteliumProto

public struct ClientError: Error, LocalizedError {
    public let message: String
    public let cause: (any Error)?

    public init(_ message: String, cause: (any Error)? = nil) {
        self.message = message
        self.cause = cause
    }

    public var errorDescription: String? {
        message
    }
}

public func getError(_ err: any Error, _ code: Daemonv1.Error.Code) -> Daemonv1.Error {
    var retCode = code
    var isRetryable = false

    let chain = getErrorChain(err)
    let statusCode = chain.lazy.compactMap { getStatusCode($0) }.first
    let tunnelErr = chain.lazy.compactMap { $0 as? TunnelError }.first

    if chain.contains(where: { $0 is AuthenticationTimedOutError }) {
        retCode = .authenticationTimedOut
    } else if chain.contains(where: { $0 is AuthenticationRequiredError }) {
        retCode = .authenticationRequired
    } else if chain.contains(where: { $0 is CancellationError }) || statusCode == .canceled {
        retCode = .operationCanceled
    } else if statusCode == .unauthenticated {
        retCode = .authenticationRequired
    } else if statusCode == .permissionDenied {
        retCode = .permissionDenied
    } else if statusCode == .deadlineExceeded {
        isRetryable = true
    } else if statusCode == .unavailable {
        retCode = .clusterUnreachable
    } else if tunnelErr?.code == .unauthenticated {
        retCode = .authenticationRequired
    } else if tunnelErr?.code == .platform {
        retCode = .networkConfigurationFailed
    }

    switch retCode {
    case .clusterUnreachable, .connectionFailed, .networkConfigurationFailed, .dnsConfigurationFailed:
        isRetryable = true
    default:
        break
    }

    var ret = Daemonv1.Error()
    ret.code = retCode
    ret.message = getErrorMessage(err)
    ret.retryable = isRetryable

    return ret
}

private func getErrorChain(_ err: any Error) -> [any Error] {
    var ret: [any Error] = [err]

    while ret.count < 8, let next = getCause(ret[ret.count - 1]) {
        ret.append(next)
    }

    return ret
}

private func getCause(_ err: any Error) -> (any Error)? {
    switch err {
    case let err as ClientError:
        err.cause
    case let err as ConnectionClosedError:
        err.cause
    default:
        nil
    }
}
