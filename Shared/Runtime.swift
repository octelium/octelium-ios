import Foundation
import OcteliumAPI
import OcteliumCore
import OcteliumProto

func getDefaultLogLevel() -> LogLevel {
    #if DEBUG
    return .debug
    #else
    return .info
    #endif
}

func newClient(
    stateDir: URL,
    stateKey: Data,
    installationID: String,
    deviceName: String,
    tunnels: TunnelFactory? = nil,
    host: (any TunnelHost)? = nil,
    onStatus: @escaping @Sendable (Daemonv1.GetStatusResponse) -> Void,
    onLog: @escaping @Sendable (LogEntry) -> Void
) throws -> OcteliumClient {
    try OcteliumClient(
        db: DB(dir: stateDir, key: stateKey),
        device: DeviceInfo(installationID: installationID, name: deviceName),
        tunnels: tunnels,
        host: host,
        onStatus: onStatus,
        logger: LogWriter(level: getDefaultLogLevel(), sink: onLog)
    )
}
