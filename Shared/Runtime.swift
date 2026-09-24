import Foundation
import LibOctelium
import OcteliumCore
import OcteliumProto
import Synchronization

func getLibConfig(
    stateDir: URL,
    stateKey: Data,
    deviceID: String,
    deviceName: String,
    logLevel: Mobilev1.Log.Level
) -> Mobilev1.Config {
    var ret = Mobilev1.Config()
    ret.platform = .ios
    ret.stateDir = stateDir.path
    ret.stateKey = stateKey
    ret.device.id = deviceID
    ret.device.name = deviceName
    ret.logLevel = logLevel
    return ret
}

func getDefaultLogLevel() -> Mobilev1.Log.Level {
    #if DEBUG
    return .debug
    #else
    return .info
    #endif
}

final class RuntimeCallbacks: NativeCallbacks {
    private let onEventFn: @Sendable (Data) -> Void
    private let requestHandler = Mutex<PlatformRequestHandler?>(nil)

    init(onEvent: @escaping @Sendable (Data) -> Void) {
        self.onEventFn = onEvent
    }

    func setRequestHandler(_ arg: PlatformRequestHandler?) {
        requestHandler.withLock { $0 = arg }
    }

    func onEvent(_ data: Data) {
        onEventFn(data)
    }

    func onRequest(_ requestID: UInt64, _ data: Data) {
        guard let handler = requestHandler.withLock({ $0 }) else {
            return
        }

        Task.detached(priority: .userInitiated) {
            await handler.handle(requestID, data)
        }
    }
}

func closeLib(_ lib: LibOctelium) async {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .utility).async {
            lib.close()
            cont.resume()
        }
    }
}
