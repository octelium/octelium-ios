import Foundation
import OcteliumProto
import os

enum Log {
    static let subsystem = "com.octelium.client"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
    static let lib = Logger(subsystem: subsystem, category: "liboctelium")
}

func writeLibLog(_ log: Mobilev1.Log) {
    switch log.level {
    case .debug:
        Log.lib.debug("\(log.message, privacy: .private)")
    case .warn:
        Log.lib.warning("\(log.message, privacy: .private)")
    case .error:
        Log.lib.error("\(log.message, privacy: .private)")
    default:
        Log.lib.info("\(log.message, privacy: .private)")
    }
}
