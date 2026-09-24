import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public func resolveHost(_ host: String) async -> HostCheck {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            cont.resume(returning: doResolveHost(host))
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
