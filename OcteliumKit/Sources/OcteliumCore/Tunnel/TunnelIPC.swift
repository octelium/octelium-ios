import Foundation
import OcteliumProto

public let tunnelDomainKey = "domain"
public let tunnelErrorDomain = "com.octelium.client.tunnel"
public let maxTunnelLogs = 200

public func getTunnelStatusNotification(_ appGroup: String) -> String {
    "\(appGroup).tunnel.status"
}

public enum TunnelMessage: UInt8, Sendable {
    case getStatus = 1
    case getLogs = 2
}

public func encodeTunnelMessage(_ arg: TunnelMessage) -> Data {
    Data([arg.rawValue])
}

public func decodeTunnelMessage(_ data: Data) -> TunnelMessage? {
    guard data.count == 1, let ret = data.first else {
        return nil
    }

    return TunnelMessage(rawValue: ret)
}

private func appendVarint(_ data: inout Data, _ arg: Int) {
    var value = UInt64(arg)
    while value >= 0x80 {
        data.append(UInt8(value & 0x7f) | 0x80)
        value >>= 7
    }
    data.append(UInt8(value))
}

private func readVarint(_ data: Data, _ idx: inout Int) -> Int? {
    var ret: UInt64 = 0
    var shift: UInt64 = 0

    while idx < data.endIndex && shift < 64 {
        let b = data[idx]
        idx += 1

        ret |= UInt64(b & 0x7f) << shift
        if b & 0x80 == 0 {
            return ret <= UInt64(Int.max) ? Int(ret) : nil
        }

        shift += 7
    }

    return nil
}

public func encodeLogs(_ logs: [Mobilev1.Log]) throws -> Data {
    var ret = Data()

    for itm in logs.suffix(maxTunnelLogs) {
        let data: Data = try itm.serializedBytes()
        appendVarint(&ret, data.count)
        ret.append(data)
    }

    return ret
}

public func decodeLogs(_ data: Data) throws -> [Mobilev1.Log] {
    var ret: [Mobilev1.Log] = []
    var idx = data.startIndex

    while idx < data.endIndex {
        guard let size = readVarint(data, &idx), size <= data.endIndex - idx else {
            throw StatusError(.dataLoss, "Invalid log encoding")
        }

        ret.append(try Mobilev1.Log(serializedBytes: data[idx..<(idx + size)]))
        idx += size
    }

    return ret
}

public enum TunnelErrorCode: Int, Sendable, CaseIterable {
    case missingDomain = 1
    case stateUnavailable = 2
    case authenticationRequired = 3
    case invalidConfiguration = 4
    case libraryUnavailable = 5
    case startTimeout = 6
    case connectionFailed = 7
    case clusterUnreachable = 8
    case permissionDenied = 9
    case internalError = 10
}

public func getTunnelErrorCode(_ arg: Daemonv1.Error?) -> TunnelErrorCode {
    switch arg?.code {
    case .authenticationRequired, .authenticationFailed, .authenticationTimedOut:
        .authenticationRequired
    case .clusterUnreachable:
        .clusterUnreachable
    case .connectionFailed:
        .connectionFailed
    case .networkConfigurationFailed, .dnsConfigurationFailed:
        .invalidConfiguration
    case .permissionDenied:
        .permissionDenied
    default:
        .internalError
    }
}

public func getTunnelError(_ code: TunnelErrorCode, _ message: String) -> NSError {
    NSError(domain: tunnelErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
}

public func getDaemonError(_ code: TunnelErrorCode, _ message: String) -> Daemonv1.Error {
    var ret = Daemonv1.Error()
    ret.message = message

    switch code {
    case .authenticationRequired:
        ret.code = .authenticationRequired
    case .invalidConfiguration:
        ret.code = .networkConfigurationFailed
    case .startTimeout, .connectionFailed:
        ret.code = .connectionFailed
        ret.retryable = true
    case .clusterUnreachable:
        ret.code = .clusterUnreachable
        ret.retryable = true
    case .permissionDenied:
        ret.code = .permissionDenied
    case .stateUnavailable:
        ret.code = .internal
        ret.retryable = true
    case .missingDomain, .libraryUnavailable, .internalError:
        ret.code = .internal
    }

    return ret
}

public func getDaemonError(_ err: Error) -> Daemonv1.Error {
    let ns = err as NSError
    if ns.domain == tunnelErrorDomain, let code = TunnelErrorCode(rawValue: ns.code) {
        return getDaemonError(code, ns.localizedDescription)
    }

    var ret = Daemonv1.Error()
    ret.code = .connectionFailed
    ret.message = getErrorMessage(err)
    ret.retryable = true

    return ret
}
