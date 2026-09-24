import Foundation
import Network
import OcteliumCore

func getNetworkTransport(_ arg: NWInterface.InterfaceType) -> NetworkTransport {
    switch arg {
    case .wifi:
        return .wifi
    case .cellular:
        return .cellular
    case .wiredEthernet:
        return .ethernet
    default:
        return .other
    }
}

func getNetworkInfo(_ path: NWPath) -> NetworkInfo {
    let physical: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
    let iface = path.availableInterfaces.first { physical.contains($0.type) } ?? path.availableInterfaces.first

    let gateways: [String] = path.gateways.compactMap {
        guard case .hostPort(let host, _) = $0 else {
            return nil
        }
        return "\(host)"
    }

    return NetworkInfo(
        isSatisfied: path.status == .satisfied,
        transport: iface.map { getNetworkTransport($0.type) } ?? .other,
        interfaceName: iface?.name ?? "",
        gateways: gateways,
        supportsIPv4: path.supportsIPv4,
        supportsIPv6: path.supportsIPv6,
        isExpensive: path.isExpensive,
        isConstrained: path.isConstrained
    )
}

final class PathMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.octelium.client.path", qos: .utility)

    func start(_ handler: @escaping (NetworkInfo) -> Void) {
        monitor.pathUpdateHandler = { path in
            handler(getNetworkInfo(path))
        }
        monitor.start(queue: queue)
    }

    var current: NetworkInfo {
        getNetworkInfo(monitor.currentPath)
    }

    func cancel() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}
