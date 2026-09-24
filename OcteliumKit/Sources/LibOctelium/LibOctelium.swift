import COctelium
import Foundation
import OcteliumCore
import OcteliumProto
import Synchronization

public let abiVersion: UInt32 = 1

public struct LibraryUnavailableError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public protocol NativeCallbacks: AnyObject, Sendable {
    func onEvent(_ data: Data)

    func onRequest(_ requestID: UInt64, _ data: Data)
}

private final class CallbackContext: Sendable {
    let callbacks: any NativeCallbacks

    init(_ callbacks: any NativeCallbacks) {
        self.callbacks = callbacks
    }
}

private func getBytes(_ data: UnsafePointer<UInt8>?, _ dataLen: Int) -> Data {
    guard let data, dataLen > 0 else {
        return Data()
    }

    return Data(bytes: data, count: dataLen)
}

private func takeBytes(_ data: UnsafeMutablePointer<UInt8>?, _ dataLen: Int) -> Data {
    guard let data else {
        return Data()
    }

    let ret = getBytes(data, dataLen)
    octelium_free(data)

    return ret
}

private func getContext(_ ctx: UnsafeMutableRawPointer?) -> CallbackContext? {
    guard let ctx else {
        return nil
    }

    return Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
}

private func handleEvent(_ ctx: UnsafeMutableRawPointer?, _ data: UnsafePointer<UInt8>?, _ dataLen: Int) {
    getContext(ctx)?.callbacks.onEvent(getBytes(data, dataLen))
}

private func handleRequest(
    _ ctx: UnsafeMutableRawPointer?,
    _ requestID: UInt64,
    _ data: UnsafePointer<UInt8>?,
    _ dataLen: Int
) {
    getContext(ctx)?.callbacks.onRequest(requestID, getBytes(data, dataLen))
}

private func withBytes<T>(_ data: Data, _ fn: (UnsafePointer<UInt8>?, Int) -> T) -> T {
    data.withUnsafeBytes { buf in
        fn(buf.bindMemory(to: UInt8.self).baseAddress, buf.count)
    }
}

public final class LibOctelium: LocalTransport, RequestCompleter, Sendable {
    private let handle: UInt64
    private let context: Mutex<Unmanaged<CallbackContext>?>
    private let isClosed = Atomic<Bool>(false)

    private static let queue = DispatchQueue(
        label: "com.octelium.liboctelium",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init(handle: UInt64, context: Unmanaged<CallbackContext>) {
        self.handle = handle
        self.context = Mutex(context)
    }

    public static func checkABI() throws {
        let ret = octelium_abi_version()
        if ret != abiVersion {
            throw LibraryUnavailableError(
                "liboctelium implements the C ABI version \(ret) while this application requires the version \(abiVersion)"
            )
        }
    }

    public static func create(_ config: Mobilev1.Config, _ callbacks: any NativeCallbacks) throws -> LibOctelium {
        try checkABI()

        let configBytes: Data = try config.serializedBytes()
        let context = Unmanaged.passRetained(CallbackContext(callbacks))

        var cb = octelium_callbacks_t(ctx: context.toOpaque(), on_event: handleEvent, on_request: handleRequest)
        var handle: UInt64 = 0
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0

        let code = withBytes(configBytes) { data, dataLen in
            octelium_client_new(data, dataLen, &cb, &handle, &out, &outLen)
        }

        let msg = String(decoding: takeBytes(out, outLen), as: UTF8.self)

        if code != 0 || handle == 0 {
            context.release()
            throw getStatusError(code: code == 0 ? StatusCode.unknown.rawValue : code, message: msg)
        }

        return LibOctelium(handle: handle, context: context)
    }

    public func call(_ method: String, _ request: Data) async throws -> Data {
        if isClosed.load(ordering: .acquiring) {
            throw StatusError(.unavailable, "liboctelium is closed")
        }

        let handle = self.handle

        return try await withCheckedThrowingContinuation { cont in
            LibOctelium.queue.async {
                cont.resume(with: Result { try LibOctelium.callSync(handle, method, request) })
            }
        }
    }

    public func complete(_ requestID: UInt64, _ response: Data) -> Int32 {
        if isClosed.load(ordering: .acquiring) {
            return StatusCode.unavailable.rawValue
        }

        return withBytes(response) { data, dataLen in
            octelium_client_complete_request(handle, requestID, data, dataLen)
        }
    }

    public func close() {
        guard isClosed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
            return
        }

        octelium_client_free(handle)

        context.withLock { ctx in
            ctx?.release()
            ctx = nil
        }
    }

    static func callSync(_ handle: UInt64, _ method: String, _ request: Data) throws -> Data {
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0

        let code = withBytes(request) { data, dataLen in
            method.withCString { m in
                octelium_client_call(handle, m, data, dataLen, &out, &outLen)
            }
        }

        let ret = takeBytes(out, outLen)

        if code != 0 {
            throw getStatusError(code: code, message: String(decoding: ret, as: UTF8.self))
        }

        return ret
    }
}
