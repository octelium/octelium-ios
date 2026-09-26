import Foundation
import OcteliumProto
import Synchronization

public final class StatusStore: Sendable {
    private let state = Mutex<Daemonv1.GetStatusResponse?>(nil)
    private let onChange: @Sendable () -> Void

    public init(onChange: @escaping @Sendable () -> Void = {}) {
        self.onChange = onChange
    }

    public var status: Daemonv1.GetStatusResponse? {
        state.withLock { $0 }
    }

    public func update(_ arg: Daemonv1.GetStatusResponse) {
        let isChanged = state.withLock { cur in
            guard shouldReplaceStatus(cur, arg) else {
                return false
            }

            cur = arg
            return true
        }

        if isChanged {
            onChange()
        }
    }

    public func reset() {
        state.withLock { $0 = nil }
        onChange()
    }
}

public func shouldReplaceStatus(_ cur: Daemonv1.GetStatusResponse?, _ next: Daemonv1.GetStatusResponse) -> Bool {
    guard let cur, cur.instanceID == next.instanceID else {
        return true
    }

    return next.revision >= cur.revision
}

public enum LogLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    case debug = 1
    case info = 2
    case warn = 3
    case error = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct LogEntry: Codable, Equatable, Sendable {
    public let level: LogLevel
    public let createdAt: Date
    public let message: String

    public init(level: LogLevel, createdAt: Date = Date(), message: String) {
        self.level = level
        self.createdAt = createdAt
        self.message = message
    }
}

public struct LogWriter: Sendable {
    private let level: LogLevel
    private let sink: @Sendable (LogEntry) -> Void

    public init(level: LogLevel = .info, sink: @escaping @Sendable (LogEntry) -> Void = { _ in }) {
        self.level = level
        self.sink = sink
    }

    public func debug(_ message: String) {
        log(.debug, message)
    }

    public func info(_ message: String) {
        log(.info, message)
    }

    public func warn(_ message: String) {
        log(.warn, message)
    }

    public func error(_ message: String) {
        log(.error, message)
    }

    public func log(_ level: LogLevel, _ message: String) {
        log(LogEntry(level: level, message: message))
    }

    public func log(_ entry: LogEntry) {
        if entry.level >= level {
            sink(entry)
        }
    }
}

public let defaultLogCapacity = 500

public final class LogStore: Sendable {
    private let buffer = Mutex<[LogEntry]>([])
    private let capacity: Int
    private let onChange: @Sendable () -> Void

    public init(capacity: Int = defaultLogCapacity, onChange: @escaping @Sendable () -> Void = {}) {
        self.capacity = capacity
        self.onChange = onChange
    }

    public var logs: [LogEntry] {
        buffer.withLock { $0 }
    }

    public func add(_ log: LogEntry) {
        buffer.withLock { itms in
            itms.append(log)
            if itms.count > capacity {
                itms.removeFirst(itms.count - capacity)
            }
        }

        onChange()
    }

    public func clear() {
        buffer.withLock { $0.removeAll() }
        onChange()
    }
}

public func getLogLevelName(_ arg: LogLevel) -> String {
    switch arg {
    case .debug: "DEBUG"
    case .info: "INFO"
    case .warn: "WARN"
    case .error: "ERROR"
    }
}

public func formatLog(_ arg: LogEntry, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.hour, .minute, .second], from: arg.createdAt)
    let at = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)

    let level = getLogLevelName(arg.level)
    let padded = level.count >= 5 ? level : level + String(repeating: " ", count: 5 - level.count)

    return "\(at) \(padded) \(arg.message)"
}
