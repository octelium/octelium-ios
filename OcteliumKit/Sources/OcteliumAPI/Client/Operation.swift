import Foundation
import OcteliumProto
import SwiftProtobuf

final class Operation: @unchecked Sendable {
    let id = UUID().uuidString.lowercased()
    let domain: String
    let type: Daemonv1.Operation.TypeEnum
    var cancelFn: (@Sendable () -> Void)?

    private(set) var state: Daemonv1.Operation.State = .pending

    let createdAt: Date
    private(set) var updatedAt: Date
    private(set) var completedAt: Date?

    var action: Daemonv1.Action?

    private(set) var err: Daemonv1.Error?

    init(domain: String, type: Daemonv1.Operation.TypeEnum, cancelFn: (@Sendable () -> Void)?) {
        self.domain = domain
        self.type = type
        self.cancelFn = cancelFn

        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }

    var isDone: Bool {
        switch state {
        case .succeeded, .failed, .canceled:
            true
        default:
            false
        }
    }

    var isCancellable: Bool {
        cancelFn != nil && !isDone
    }

    func setState(_ arg: Daemonv1.Operation.State) {
        if isDone {
            return
        }

        state = arg
        updatedAt = Date()

        if isDone {
            completedAt = updatedAt
            action = nil
            cancelFn = nil
        }
    }

    func setFailed(_ arg: Daemonv1.Error) {
        if isDone {
            return
        }

        err = arg
        if arg.code == .operationCanceled {
            setState(.canceled)
            return
        }

        setState(.failed)
    }

    func setCanceled(_ message: String) {
        var ret = Daemonv1.Error()
        ret.code = .operationCanceled
        ret.message = message

        setFailed(ret)
    }

    func toPB() -> Daemonv1.Operation {
        var ret = Daemonv1.Operation()
        ret.id = id
        ret.domain = domain
        ret.type = type
        ret.state = state
        ret.createdAt = Google_Protobuf_Timestamp(date: createdAt)
        ret.updatedAt = Google_Protobuf_Timestamp(date: updatedAt)
        ret.cancellable = isCancellable

        if let completedAt {
            ret.completedAt = Google_Protobuf_Timestamp(date: completedAt)
        }

        if let action {
            ret.action = action
        }

        if let err {
            ret.error = err
        }

        return ret
    }
}
