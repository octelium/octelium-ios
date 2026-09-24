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

public let defaultLogCapacity = 500

public final class LogStore: Sendable {
    private let buffer = Mutex<[Mobilev1.Log]>([])
    private let capacity: Int
    private let onChange: @Sendable () -> Void

    public init(capacity: Int = defaultLogCapacity, onChange: @escaping @Sendable () -> Void = {}) {
        self.capacity = capacity
        self.onChange = onChange
    }

    public var logs: [Mobilev1.Log] {
        buffer.withLock { $0 }
    }

    public func add(_ log: Mobilev1.Log) {
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

public struct EventHandler: Sendable {
    private let statusStore: StatusStore
    private let logStore: LogStore
    private let onLog: @Sendable (Mobilev1.Log) -> Void

    public init(
        statusStore: StatusStore,
        logStore: LogStore,
        onLog: @escaping @Sendable (Mobilev1.Log) -> Void = { _ in }
    ) {
        self.statusStore = statusStore
        self.logStore = logStore
        self.onLog = onLog
    }

    public func handle(_ data: Data) {
        guard let ev = try? Mobilev1.Event(serializedBytes: data) else {
            return
        }

        switch ev.type {
        case .status(let arg):
            statusStore.update(arg)
        case .log(let arg):
            logStore.add(arg)
            onLog(arg)
        case nil:
            break
        }
    }
}

public func getLogLevelName(_ arg: Mobilev1.Log.Level) -> String {
    switch arg {
    case .debug: "DEBUG"
    case .info: "INFO"
    case .warn: "WARN"
    case .error: "ERROR"
    default: "LEVEL_UNSPECIFIED"
    }
}

public func formatLog(_ arg: Mobilev1.Log, timeZone: TimeZone = .current) -> String {
    let at: String
    if arg.hasCreatedAt {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: arg.createdAt.date)
        at = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    } else {
        at = "--:--:--"
    }

    let level = getLogLevelName(arg.level)
    let padded = level.count >= 5 ? level : level + String(repeating: " ", count: 5 - level.count)

    return "\(at) \(padded) \(arg.message)"
}
