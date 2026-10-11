import Darwin
import Foundation

/// Minimal SSDP (UPnP discovery) client using a plain UDP socket.
enum SSDP {
    static let searchTargets = [
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:schemas-upnp-org:service:AVTransport:1",
    ]

    /// Sends M-SEARCH and returns the unique `LOCATION` URLs of devices that answered.
    static func search(timeout: TimeInterval = 3) async -> [URL] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: searchBlocking(timeout: timeout))
            }
        }
    }

    private static func searchBlocking(timeout: TimeInterval) -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")

        func send(_ message: String) {
            let bytes = Array(message.utf8)
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        // Send on every LAN interface explicitly: with a VPN up, the default multicast
        // route usually points into the tunnel and the TV never sees the query.
        var interfaces = lanInterfaceAddresses()
        if interfaces.isEmpty { interfaces = [in_addr(s_addr: INADDR_ANY)] }
        for _ in 0..<2 {
            for var ifaddr in interfaces {
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifaddr, socklen_t(MemoryLayout<in_addr>.size))
                for st in searchTargets {
                    send("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(st)\r\nUSER-AGENT: macOS UPnP/1.1 SamsungTV4Mac/1.0\r\n\r\n")
                }
            }
        }

        var locations: [URL] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { continue }
            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            if let location = header("location", in: text), let url = URL(string: location),
               !locations.contains(url) {
                locations.append(url)
            }
        }
        return locations
    }

    /// IPv4 addresses of active, multicast-capable, non-loopback, non-tunnel interfaces.
    private static func lanInterfaceAddresses() -> [in_addr] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [in_addr] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_MULTICAST != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if !result.contains(where: { $0.s_addr == addr.s_addr }) { result.append(addr) }
        }
        return result
    }

    private static func header(_ name: String, in response: String) -> String? {
        for line in response.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
