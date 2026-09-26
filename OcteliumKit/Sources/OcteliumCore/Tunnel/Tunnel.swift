import Foundation
import OcteliumProto

public enum TunnelState: Int, Sendable, CaseIterable {
    case idle = 0
    case connecting = 1
    case connected = 2
    case reconnecting = 3
    case failed = 4
}

public struct TunnelError: Error, Equatable, LocalizedError {
    public enum Code: Int32, Sendable, CaseIterable {
        case invalidArgument = 1
        case invalidState = 2
        case notFound = 3
        case unsupported = 4
        case unauthenticated = 5
        case unavailable = 6
        case platform = 7
        case transport = 8
        case timeout = 9
        case `internal` = 10

        public init(_ code: Int32) {
            self = Code(rawValue: code) ?? .internal
        }
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        message.isEmpty ? "\(code)" : message
    }
}

public enum TunnelMode: Sendable {
    case wireguard
    case quicv0
}

public enum DNSMode: Sendable {
    case `default`
    case disabled
    case full
}

public struct TunnelPreferences: Equatable, Sendable {
    public var tunnelMode: TunnelMode
    public var dnsMode: DNSMode
    public var mtu: Int32
    public var keepAliveSeconds: Int32

    public init(
        tunnelMode: TunnelMode = .wireguard,
        dnsMode: DNSMode = .default,
        mtu: Int32 = 0,
        keepAliveSeconds: Int32 = 0
    ) {
        self.tunnelMode = tunnelMode
        self.dnsMode = dnsMode
        self.mtu = mtu
        self.keepAliveSeconds = keepAliveSeconds
    }
}

public struct TunnelConfig: Equatable, Sendable {
    public let domain: String
    public let state: Userv1.ConnectionState
    public let preferences: TunnelPreferences

    public init(domain: String, state: Userv1.ConnectionState, preferences: TunnelPreferences) {
        self.domain = domain
        self.state = state
        self.preferences = preferences
    }
}

public struct TunnelStatus: Equatable, Sendable {
    public let state: TunnelState
    public let error: TunnelError.Code?
    public let message: String

    public init(state: TunnelState, error: TunnelError.Code? = nil, message: String = "") {
        self.state = state
        self.error = error
        self.message = message
    }
}

public struct DNSConfig: Equatable, Sendable {
    public let servers: [String]
    public let searchDomains: [String]
    public let matchDomains: [String]
    public let matchAllDomains: Bool

    public init(
        servers: [String],
        searchDomains: [String] = [],
        matchDomains: [String] = [],
        matchAllDomains: Bool = false
    ) {
        self.servers = servers
        self.searchDomains = searchDomains
        self.matchDomains = matchDomains
        self.matchAllDomains = matchAllDomains
    }
}

public struct NetworkConfig: Equatable, Sendable {
    public let generation: UInt64
    public let addresses: [String]
    public let routes: [String]
    public let dns: DNSConfig?
    public let mtu: Int

    public init(generation: UInt64, addresses: [String], routes: [String], dns: DNSConfig?, mtu: Int) {
        self.generation = generation
        self.addresses = addresses
        self.routes = routes
        self.dns = dns
        self.mtu = mtu
    }
}

public enum TunnelRequest: Equatable, Sendable {
    case applyNetworkConfig(NetworkConfig)
    case getAccessToken
}

public enum TunnelResponse: Equatable, Sendable {
    case applyNetworkConfig(tunFD: Int32?)
    case getAccessToken(String)
    case error(TunnelError.Code, String)
}

public protocol TunnelHandler: AnyObject, Sendable {
    func onStatus(_ status: TunnelStatus)

    func onLog(_ log: LogEntry)

    func onRequest(_ requestID: UInt64, _ request: TunnelRequest)
}

public protocol Tunnel: Sendable {
    func setConfig(_ config: TunnelConfig) throws

    func setNetworkState(_ state: NetworkState)

    func complete(_ requestID: UInt64, _ response: TunnelResponse) -> Int32

    func close()
}

public typealias TunnelFactory = @Sendable (any TunnelHandler) throws -> any Tunnel
