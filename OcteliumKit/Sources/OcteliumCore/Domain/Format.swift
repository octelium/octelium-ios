import Foundation
import SwiftProtobuf

public func toDate(_ arg: Google_Protobuf_Timestamp?) -> Date? {
    guard let arg, arg.seconds != 0 || arg.nanos != 0 else {
        return nil
    }

    return arg.date
}

public func toRFC3339(_ arg: Google_Protobuf_Timestamp?) -> String? {
    guard let at = toDate(arg) else {
        return nil
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")

    return formatter.string(from: at)
}

public func printDuration(_ from: Google_Protobuf_Timestamp?, now: Date = Date()) -> String {
    guard let start = toDate(from) else {
        return ""
    }

    let seconds = max(Int64(now.timeIntervalSince(start).rounded(.down)), 0)

    let days = seconds / 86400
    let hours = (seconds % 86400) / 3600
    let minutes = (seconds % 3600) / 60

    if days > 0 {
        return "\(days)d \(hours)h"
    }

    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }

    if minutes > 0 {
        return "\(minutes)m \(seconds % 60)s"
    }

    return "\(seconds)s"
}

public func printTimeAgo(_ arg: Google_Protobuf_Timestamp?, now: Date = Date()) -> String {
    guard let at = toDate(arg) else {
        return "—"
    }

    let seconds = Int64(now.timeIntervalSince(at).rounded(.down))

    if seconds < 0 {
        return "in the future"
    }

    switch seconds {
    case ..<45:
        return "a few seconds ago"
    case ..<90:
        return "a minute ago"
    case ..<(45 * 60):
        return "\((seconds + 30) / 60) minutes ago"
    case ..<(90 * 60):
        return "an hour ago"
    case ..<(22 * 3600):
        return "\((seconds + 1800) / 3600) hours ago"
    case ..<(36 * 3600):
        return "a day ago"
    case ..<(26 * 86400):
        return "\((seconds + 43200) / 86400) days ago"
    case ..<(46 * 86400):
        return "a month ago"
    case ..<(320 * 86400):
        return "\((seconds + 15 * 86400) / (30 * 86400)) months ago"
    case ..<(548 * 86400):
        return "a year ago"
    default:
        return "\((seconds + 182 * 86400) / (365 * 86400)) years ago"
    }
}
