import Foundation
import NetworkExtension
import OcteliumCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var runtime: TunnelRuntime?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let domain = getDomain(options) else {
            completionHandler(getTunnelError(.missingDomain, "No Cluster domain is configured for this VPN"))
            return
        }

        Log.tunnel.info("Starting the tunnel of \(domain, privacy: .public)")

        let runtime = TunnelRuntime(provider: self, domain: domain)
        self.runtime = runtime

        Task {
            await runtime.start(completionHandler)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Log.tunnel.info("Stopping the tunnel: \(reason.rawValue, privacy: .public)")

        guard let runtime else {
            completionHandler()
            return
        }

        self.runtime = nil

        Task {
            await runtime.stop()
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let msg = decodeTunnelMessage(messageData), let runtime else {
            completionHandler?(nil)
            return
        }

        Task {
            completionHandler?(await runtime.handleMessage(msg))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
        guard let runtime else {
            return
        }

        Task {
            await runtime.wake()
        }
    }

    private func getDomain(_ options: [String: NSObject]?) -> String? {
        if let ret = options?[tunnelDomainKey] as? String, !ret.isEmpty {
            return ret
        }

        let cfg = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        if let ret = cfg?[tunnelDomainKey] as? String, !ret.isEmpty {
            return ret
        }

        return nil
    }
}
