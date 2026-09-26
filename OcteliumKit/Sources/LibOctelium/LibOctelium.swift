import COctelium
import Foundation
import OcteliumCore
import OcteliumProto
import Synchronization

public let abiVersionMajor: UInt32 = 1

public struct LibraryUnavailableError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public func formatABIVersion(_ arg: UInt32) -> String {
    "\(arg >> 16).\(arg & 0xffff)"
}

private final class CallbackContext: Sendable {
    let handler: any TunnelHandler
    let handle = Atomic<UInt64>(0)

    init(_ handler: any TunnelHandler) {
        self.handler = handler
    }
}

private func getContext(_ ctx: UnsafeMutableRawPointer?) -> CallbackContext? {
    guard let ctx else {
        return nil
    }

    return Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
}

private func getString(_ arg: UnsafePointer<CChar>?) -> String {
    guard let arg else {
        return ""
    }

    return String(cString: arg)
}

private func getStrings(_ arg: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int) -> [String] {
    guard let arg else {
        return []
    }

    return (0..<count).map { getString(arg[$0]) }
}

private func getPrefixes(_ arg: UnsafePointer<octelium_prefix_t>?, _ count: Int) -> [String] {
    guard let arg else {
        return []
    }

    return (0..<count).map { "\(getString(arg[$0].address))/\(arg[$0].prefix_len)" }
}

func getNetworkConfig(_ arg: octelium_network_config_t) -> NetworkConfig {
    let dns: DNSConfig? = arg.dns.map { ptr in
        let itm = ptr.pointee
        return DNSConfig(
            servers: getStrings(itm.servers, itm.servers_len),
            searchDomains: getStrings(itm.search_domains, itm.search_domains_len),
            matchDomains: getStrings(itm.match_domains, itm.match_domains_len),
            matchAllDomains: itm.match_all_domains != 0
        )
    }

    return NetworkConfig(
        generation: arg.generation,
        addresses: getPrefixes(arg.addresses, arg.addresses_len),
        routes: getPrefixes(arg.routes, arg.routes_len),
        dns: dns,
        mtu: Int(arg.mtu)
    )
}

private func handleEvent(_ ctx: UnsafeMutableRawPointer?, _ event: UnsafePointer<octelium_event_t>?) {
    guard let context = getContext(ctx), let event else {
        return
    }

    let ev = event.pointee

    switch Int(ev.type) {
    case Int(OCTELIUM_EVENT_STATE):
        context.handler.onStatus(
            TunnelStatus(
                state: TunnelState(rawValue: Int(ev.state)) ?? .failed,
                error: ev.error == 0 ? nil : TunnelError.Code(ev.error),
                message: getString(ev.message)
            )
        )
    case Int(OCTELIUM_EVENT_LOG):
        context.handler.onLog(
            LogEntry(
                level: LogLevel(rawValue: Int(ev.log_level)) ?? .info,
                createdAt: Date(timeIntervalSince1970: TimeInterval(ev.created_at) / 1000),
                message: getString(ev.message)
            )
        )
    default:
        break
    }
}

private func handleRequest(
    _ ctx: UnsafeMutableRawPointer?,
    _ requestID: UInt64,
    _ request: UnsafePointer<octelium_request_t>?
) {
    guard let context = getContext(ctx), let request else {
        return
    }

    let req = request.pointee

    let ret: TunnelRequest? = switch Int(req.type) {
    case Int(OCTELIUM_REQUEST_APPLY_NETWORK_CONFIG):
        req.network_config.map { TunnelRequest.applyNetworkConfig(getNetworkConfig($0.pointee)) }
    case Int(OCTELIUM_REQUEST_GET_ACCESS_TOKEN):
        .getAccessToken
    default:
        nil
    }

    guard let ret else {
        _ = completeRequest(
            context.handle.load(ordering: .acquiring),
            requestID,
            .error(.unsupported, "Unsupported request: \(req.type)")
        )
        return
    }

    context.handler.onRequest(requestID, ret)
}

public final class LibOctelium: Tunnel, Sendable {
    private let handle: UInt64
    private let context: Mutex<Unmanaged<CallbackContext>?>
    private let isClosed = Atomic<Bool>(false)

    private init(handle: UInt64, context: Unmanaged<CallbackContext>) {
        self.handle = handle
        self.context = Mutex(context)
    }

    public static var hostABIVersion: UInt32 {
        UInt32(OCTELIUM_ABI_VERSION_MAJOR << 16 | OCTELIUM_ABI_VERSION_MINOR)
    }

    public static func getABIVersion() -> UInt32 {
        octelium_abi_version()
    }

    public static func getVersion() -> String {
        getString(octelium_version())
    }

    public static func checkABI() throws {
        let ret = getABIVersion()
        if ret >> 16 != abiVersionMajor || hostABIVersion >> 16 != abiVersionMajor {
            throw LibraryUnavailableError(
                "liboctelium implements the C ABI version \(formatABIVersion(ret)) while this application requires the version \(abiVersionMajor)"
            )
        }
    }

    public static func create(_ handler: any TunnelHandler, logLevel: LogLevel = .info) throws -> LibOctelium {
        try checkABI()

        let context = Unmanaged.passRetained(CallbackContext(handler))

        var opts = octelium_tunnel_opts_t(
            ctx: context.toOpaque(),
            on_event: handleEvent,
            on_request: handleRequest,
            protect_socket: nil,
            platform: UInt32(OCTELIUM_PLATFORM_HOST),
            log_level: UInt32(logLevel.rawValue),
            device_name: nil
        )

        var handle: UInt64 = 0
        let code = octelium_tunnel_new(hostABIVersion, &opts, &handle)

        if code != 0 || handle == 0 {
            let message = getString(octelium_last_error())
            context.release()
            throw TunnelError(code == 0 ? .internal : TunnelError.Code(code), message)
        }

        context.takeUnretainedValue().handle.store(handle, ordering: .releasing)

        return LibOctelium(handle: handle, context: context)
    }

    public func setConfig(_ config: TunnelConfig) throws {
        if isClosed.load(ordering: .acquiring) {
            throw TunnelError(.invalidState, "The tunnel is closed")
        }

        let (code, message) = withArena { a in
            var cfg = getNativeConfig(config, a)
            let ret = octelium_tunnel_set_config(handle, &cfg)
            return (ret, ret == 0 ? "" : getString(octelium_last_error()))
        }

        if code != 0 {
            throw TunnelError(TunnelError.Code(code), message)
        }
    }

    public func setNetworkState(_ state: NetworkState) {
        if isClosed.load(ordering: .acquiring) {
            return
        }

        state.id.withCString { id in
            var arg = octelium_network_state_t(is_available: state.isAvailable ? 1 : 0, id: id)
            _ = octelium_tunnel_set_network_state(handle, &arg)
        }
    }

    public func complete(_ requestID: UInt64, _ response: TunnelResponse) -> Int32 {
        if isClosed.load(ordering: .acquiring) {
            return TunnelError.Code.notFound.rawValue
        }

        return completeRequest(handle, requestID, response)
    }

    public func close() {
        guard isClosed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
            return
        }

        octelium_tunnel_free(handle)

        context.withLock { ctx in
            ctx?.release()
            ctx = nil
        }
    }
}

private func completeRequest(_ handle: UInt64, _ requestID: UInt64, _ response: TunnelResponse) -> Int32 {
    withArena { a in
        var resp = octelium_response_t(result: 0, message: nil, tun_fd: -1, access_token: nil)

        switch response {
        case .applyNetworkConfig(let tunFD):
            resp.tun_fd = tunFD ?? -1
        case .getAccessToken(let accessToken):
            resp.access_token = a.string(accessToken)
        case .error(let code, let message):
            resp.result = code.rawValue
            resp.message = a.string(message)
        }

        return octelium_tunnel_complete_request(handle, requestID, &resp)
    }
}

private func getNativeConfig(_ arg: TunnelConfig, _ a: Arena) -> octelium_config_t {
    let state = arg.state

    let addresses = state.addresses.map { getDualStackNetwork($0, a) }
    let gateways = state.gateways.map { getGateway($0, a) }
    let dnsServers = state.dns.servers.map { a.string($0) }

    var cs = octelium_connection_state_t()
    cs.mtu = state.mtu
    cs.l3_mode = UInt32(state.l3Mode.rawValue)
    if !state.x25519Key.isEmpty {
        cs.x25519_key = a.bytes(state.x25519Key)
        cs.x25519_key_len = state.x25519Key.count
    }
    cs.addresses = a.array(addresses)
    cs.addresses_len = addresses.count
    cs.gateways = a.array(gateways)
    cs.gateways_len = gateways.count
    cs.dns_servers = a.array(dnsServers)
    cs.dns_servers_len = dnsServers.count
    cs.cidr = getDualStackNetwork(state.cidr, a)

    let dnsMode = switch arg.preferences.dnsMode {
    case .default: OCTELIUM_DNS_MODE_DEFAULT
    case .disabled: OCTELIUM_DNS_MODE_DISABLED
    case .full: OCTELIUM_DNS_MODE_FULL
    }

    var prefs = octelium_preferences_t()
    prefs.tunnel_mode = UInt32(arg.preferences.tunnelMode == .quicv0 ? OCTELIUM_TUNNEL_MODE_QUICV0 : OCTELIUM_TUNNEL_MODE_WIREGUARD)
    prefs.dns_mode = UInt32(dnsMode)
    prefs.mtu = arg.preferences.mtu
    prefs.keepalive_seconds = arg.preferences.keepAliveSeconds

    return octelium_config_t(domain: a.string(arg.domain), state: a.value(cs), preferences: a.value(prefs))
}

private func getDualStackNetwork(_ arg: Metav1.DualStackNetwork, _ a: Arena) -> octelium_dual_stack_network_t {
    octelium_dual_stack_network_t(
        v4: arg.v4.isEmpty ? nil : a.string(arg.v4),
        v6: arg.v6.isEmpty ? nil : a.string(arg.v6)
    )
}

private func getGateway(_ arg: Userv1.Gateway, _ a: Arena) -> octelium_gateway_t {
    let addresses = arg.addresses.map { a.string($0) }
    let cidrs = arg.cidrs.map { a.string($0) }

    var ret = octelium_gateway_t()
    ret.id = a.string(arg.id)
    ret.hostname = a.string(arg.hostname)
    ret.addresses = a.array(addresses)
    ret.addresses_len = addresses.count
    ret.cidrs = a.array(cidrs)
    ret.cidrs_len = cidrs.count

    if arg.hasWireguard {
        ret.wireguard = a.value(
            octelium_gateway_wireguard_t(
                public_key: a.string(arg.wireguard.publicKey),
                port: arg.wireguard.port,
                keepalive_seconds: arg.wireguard.keepAliveSeconds
            )
        )
    }

    if arg.hasQuicv0 {
        ret.quicv0 = a.value(
            octelium_gateway_quicv0_t(port: arg.quicv0.port, keepalive_seconds: arg.quicv0.keepAliveSeconds)
        )
    }

    return ret
}

private final class Arena {
    private var allocations: [(UnsafeMutableRawPointer, Int)] = []

    func string(_ arg: String) -> UnsafePointer<CChar>? {
        array(Array(arg.utf8CString))
    }

    func bytes(_ arg: Data) -> UnsafePointer<UInt8>? {
        array(Array(arg))
    }

    func value<T>(_ arg: T) -> UnsafePointer<T>? {
        array([arg])
    }

    func array<T>(_ arg: [T]) -> UnsafePointer<T>? {
        if arg.isEmpty {
            return nil
        }

        let ret = UnsafeMutablePointer<T>.allocate(capacity: arg.count)
        ret.initialize(from: arg, count: arg.count)
        allocations.append((UnsafeMutableRawPointer(ret), MemoryLayout<T>.stride * arg.count))

        return UnsafePointer(ret)
    }

    func free() {
        for (ptr, size) in allocations {
            memset(ptr, 0, size)
            ptr.deallocate()
        }

        allocations.removeAll()
    }
}

private func withArena<T>(_ fn: (Arena) throws -> T) rethrows -> T {
    let a = Arena()
    defer {
        a.free()
    }

    return try fn(a)
}
