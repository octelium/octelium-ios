import Foundation

public protocol LocalTransport: Sendable {
    func call(_ method: String, _ request: Data) async throws -> Data
}

public enum StatusCode: Int32, Sendable, CaseIterable {
    case ok = 0
    case canceled = 1
    case unknown = 2
    case invalidArgument = 3
    case deadlineExceeded = 4
    case notFound = 5
    case alreadyExists = 6
    case permissionDenied = 7
    case resourceExhausted = 8
    case failedPrecondition = 9
    case aborted = 10
    case outOfRange = 11
    case unimplemented = 12
    case `internal` = 13
    case unavailable = 14
    case dataLoss = 15
    case unauthenticated = 16

    public var name: String {
        switch self {
        case .ok: "OK"
        case .canceled: "CANCELLED"
        case .unknown: "UNKNOWN"
        case .invalidArgument: "INVALID_ARGUMENT"
        case .deadlineExceeded: "DEADLINE_EXCEEDED"
        case .notFound: "NOT_FOUND"
        case .alreadyExists: "ALREADY_EXISTS"
        case .permissionDenied: "PERMISSION_DENIED"
        case .resourceExhausted: "RESOURCE_EXHAUSTED"
        case .failedPrecondition: "FAILED_PRECONDITION"
        case .aborted: "ABORTED"
        case .outOfRange: "OUT_OF_RANGE"
        case .unimplemented: "UNIMPLEMENTED"
        case .internal: "INTERNAL"
        case .unavailable: "UNAVAILABLE"
        case .dataLoss: "DATA_LOSS"
        case .unauthenticated: "UNAUTHENTICATED"
        }
    }
}

public struct StatusError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let code: StatusCode
    public let message: String

    public init(_ code: StatusCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String {
        "\(code.name): \(message)"
    }

    public var errorDescription: String? {
        message.isEmpty ? code.name : message
    }
}

public func getStatusError(code: Int32, message: String) -> StatusError {
    guard (1...16).contains(code), let ret = StatusCode(rawValue: code) else {
        return StatusError(.unknown, message)
    }

    return StatusError(ret, message)
}

public func getStatusCode(_ err: Error) -> StatusCode? {
    (err as? StatusError)?.code
}

public func getErrorMessage(_ err: Error) -> String {
    let ret: String

    switch err {
    case let err as StatusError:
        ret = err.message.isEmpty ? err.code.name : err.message
    case let err as LocalizedError where err.errorDescription != nil:
        ret = err.errorDescription ?? ""
    default:
        ret = (err as NSError).localizedDescription
    }

    let trimmed = ret.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Unknown error" : trimmed
}
