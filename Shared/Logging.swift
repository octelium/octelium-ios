import Foundation
import OcteliumCore
import os

enum Log {
    static let subsystem = "com.octelium.client"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
    static let client = Logger(subsystem: subsystem, category: "client")
}

func writeClientLog(_ log: LogEntry) {
    switch log.level {
    case .debug:
        Log.client.debug("\(log.message, privacy: .private)")
    case .info:
        Log.client.info("\(log.message, privacy: .private)")
    case .warn:
        Log.client.warning("\(log.message, privacy: .private)")
    case .error:
        Log.client.error("\(log.message, privacy: .private)")
    }
}
