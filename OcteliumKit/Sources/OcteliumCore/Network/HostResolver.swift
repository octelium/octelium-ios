import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public let hostResolveTimeout: Duration = .seconds(10)

private final class ResolveOnce: Sendable {
    private let cont: Mutex<CheckedContinuation<HostCheck, Never>?>

    init(_ cont: CheckedContinuation<HostCheck, Never>) {
        self.cont = Mutex(cont)
    }

    func resume(_ arg: HostCheck) {
        let ret = cont.withLock { cont in
            let ret = cont
            cont = nil
            return ret
        }

        ret?.resume(returning: arg)
    }
}

public func resolveHost(_ host: String, timeout: Duration = hostResolveTimeout) async -> HostCheck {
    await resolveHost(host, timeout: timeout, doResolveHost)
}

func resolveHost(
    _ host: String,
    timeout: Duration,
    _ fn: @escaping @Sendable (String) -> HostCheck
) async -> HostCheck {
    await withCheckedContinuation { cont in
        let once = ResolveOnce(cont)

        let timer = Task {
            try await Task.sleep(for: timeout)
            once.resume(HostCheck(host: host, resolution: .failed, message: "Timed out"))
        }

        DispatchQueue.global(qos: .userInitiated).async {
            once.resume(fn(host))
            timer.cancel()
        }
    }
}

private func doResolveHost(_ host: String) -> HostCheck {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    #if canImport(Darwin)
    hints.ai_socktype = SOCK_STREAM
    #else
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #endif

    var res: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, "443", &hints, &res)
    if rc != 0 {
        return getHostCheck(host, [], isNotFound: rc == EAI_NONAME, message: String(cString: gai_strerror(rc)))
    }

    defer {
        freeaddrinfo(res)
    }

    var addresses: [String] = []
    var cur = res

    while let itm = cur {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(itm.pointee.ai_addr, itm.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
            addresses.append(String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }

        cur = itm.pointee.ai_next
    }

    return getHostCheck(host, addresses, isNotFound: addresses.isEmpty)
}
