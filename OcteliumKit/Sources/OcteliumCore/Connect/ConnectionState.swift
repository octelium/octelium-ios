import Foundation
import OcteliumProto

public struct ConnectOptions: Equatable, Sendable {
    public var l3Mode: Userv1.ConnectRequest.Initialize.L3Mode
    public var tunnelMode: TunnelMode
    public var dnsMode: DNSMode
    public var mtu: Int32

    public init(
        l3Mode: Userv1.ConnectRequest.Initialize.L3Mode = .v6,
        tunnelMode: TunnelMode = .wireguard,
        dnsMode: DNSMode = .default,
        mtu: Int32 = 0
    ) {
        self.l3Mode = l3Mode
        self.tunnelMode = tunnelMode
        self.dnsMode = dnsMode
        self.mtu = mtu
    }
}

public struct Connection: Equatable, Sendable {
    public let state: Userv1.ConnectionState
    public let tunnelMode: TunnelMode
    public let dnsMode: DNSMode
    public let mtu: Int32

    public init(state: Userv1.ConnectionState, tunnelMode: TunnelMode, dnsMode: DNSMode, mtu: Int32) {
        self.state = state
        self.tunnelMode = tunnelMode
        self.dnsMode = dnsMode
        self.mtu = mtu
    }
}

public struct ConnectionClosedError: Error, LocalizedError {
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

public func getInitializeRequest(_ opts: ConnectOptions) -> Userv1.ConnectRequest {
    var initialize = Userv1.ConnectRequest.Initialize()
    initialize.l3Mode = opts.l3Mode
    initialize.connectionType = opts.tunnelMode == .quicv0 ? .quicv0 : .unset
    initialize.ignoreDns = opts.dnsMode == .disabled

    var ret = Userv1.ConnectRequest()
    ret.initialize = initialize
    return ret
}

public func reduceConnectionState(
    _ state: Userv1.ConnectionState,
    _ resp: Userv1.ConnectResponse
) -> Userv1.ConnectionState? {
    switch resp.event {
    case .state(let arg):
        return arg
    case .addGateway(let arg):
        var ret = state
        if let idx = ret.gateways.firstIndex(where: { $0.id == arg.gateway.id }) {
            ret.gateways[idx] = arg.gateway
        } else {
            ret.gateways.append(arg.gateway)
        }
        return ret
    case .updateGateway(let arg):
        guard let idx = state.gateways.firstIndex(where: { $0.id == arg.gateway.id }) else {
            return nil
        }

        var ret = state
        ret.gateways[idx] = arg.gateway
        return ret
    case .deleteGateway(let arg):
        guard let idx = state.gateways.firstIndex(where: { $0.id == arg.id }) else {
            return nil
        }

        var ret = state
        ret.gateways.remove(at: idx)
        return ret
    case .updateDns(let arg):
        if arg.dns.servers.isEmpty {
            return nil
        }

        var ret = state
        ret.dns = arg.dns
        return ret
    default:
        return nil
    }
}
