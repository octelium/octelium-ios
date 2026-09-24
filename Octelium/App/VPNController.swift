import Foundation
import NetworkExtension
import OcteliumCore

let vpnMessageTimeout: TimeInterval = 5

func getVPNState(_ arg: NEVPNStatus?) -> VPNState {
    switch arg {
    case .invalid:
        return .invalid
    case .connecting:
        return .connecting
    case .connected:
        return .connected
    case .reasserting:
        return .reasserting
    case .disconnecting:
        return .disconnecting
    default:
        return .disconnected
    }
}

private final class ResponseOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Data?, Never>?

    init(_ cont: CheckedContinuation<Data?, Never>) {
        self.cont = cont
    }

    func resume(_ arg: Data?) {
        lock.lock()
        let ret = cont
        cont = nil
        lock.unlock()

        ret?.resume(returning: arg)
    }
}

@MainActor
final class VPNController {
    private(set) var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    var onChange: (() -> Void)?

    let providerBundleIdentifier: String = getInfoString("OcteliumTunnelBundleID")
        ?? "\(Bundle.main.bundleIdentifier ?? "com.octelium.client").tunnel"

    var state: VPNState {
        getVPNState(manager?.connection.status)
    }

    var domain: String? {
        let cfg = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        return cfg?[tunnelDomainKey] as? String
    }

    var isOnDemandEnabled: Bool {
        manager?.isOnDemandEnabled ?? false
    }

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let ret = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
            }
            setManager(ret)
        } catch {
            Log.app.error("Could not load the VPN configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    func connect(_ domain: String, onDemand: Bool) async throws {
        let ret = try await configure(domain, onDemand: onDemand)

        guard let session = ret.connection as? NETunnelProviderSession else {
            throw StatusError(.internal, "The VPN session is not available")
        }

        do {
            try session.startTunnel(options: [tunnelDomainKey: domain as NSString])
        } catch {
            throw StatusError(.unavailable, "Could not start the VPN: \(error.localizedDescription)")
        }
    }

    func disconnect() async throws {
        guard let manager else {
            return
        }

        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try await save(manager)
        }

        manager.connection.stopVPNTunnel()
    }

    func setOnDemand(_ domain: String?) async throws {
        guard let domain else {
            guard let manager, manager.isOnDemandEnabled else {
                return
            }

            manager.isOnDemandEnabled = false
            try await save(manager)
            onChange?()
            return
        }

        _ = try await configure(domain, onDemand: true)
    }

    func sendMessage(_ msg: TunnelMessage) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession, isVPNActive(state) else {
            return nil
        }

        return await withCheckedContinuation { cont in
            let once = ResponseOnce(cont)

            do {
                try session.sendProviderMessage(encodeTunnelMessage(msg)) { data in
                    once.resume(data)
                }
            } catch {
                once.resume(nil)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + vpnMessageTimeout) {
                once.resume(nil)
            }
        }
    }

    func fetchLastDisconnectError() async -> Error? {
        guard let connection = manager?.connection else {
            return nil
        }

        return await withCheckedContinuation { cont in
            connection.fetchLastDisconnectError { err in
                cont.resume(returning: err)
            }
        }
    }

    private func configure(_ domain: String, onDemand: Bool) async throws -> NETunnelProviderManager {
        let ret = manager ?? NETunnelProviderManager()

        let proto = (ret.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = domain
        proto.providerConfiguration = [tunnelDomainKey: domain]
        proto.includeAllNetworks = false
        proto.enforceRoutes = true
        proto.disconnectOnSleep = false

        ret.protocolConfiguration = proto
        ret.localizedDescription = "Octelium"
        ret.isEnabled = true
        ret.onDemandRules = [NEOnDemandRuleConnect()]
        ret.isOnDemandEnabled = onDemand

        try await save(ret)
        try await ret.loadFromPreferences()

        if manager !== ret {
            setManager(ret)
        } else {
            onChange?()
        }

        return ret
    }

    private func save(_ arg: NETunnelProviderManager) async throws {
        do {
            try await arg.saveToPreferences()
        } catch {
            let err = error as NSError
            if err.domain == NEVPNErrorDomain && err.code == NEVPNError.configurationReadWriteFailed.rawValue {
                throw StatusError(
                    .permissionDenied,
                    "Octelium needs your permission to add a VPN configuration in order to route the Cluster traffic of this device."
                )
            }

            throw StatusError(.internal, "Could not save the VPN configuration: \(err.localizedDescription)")
        }
    }

    private func setManager(_ arg: NETunnelProviderManager?) {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }

        observer = nil
        manager = arg

        if let arg {
            observer = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: arg.connection,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onChange?()
                }
            }
        }

        onChange?()
    }
}
