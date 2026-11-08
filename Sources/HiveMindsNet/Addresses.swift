import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Which addresses count as the local network (docs/LINUX-HOST-SPEC.md §6): the host listens only on these, and
/// refuses any connection from elsewhere.
package enum PrivateAddress {
    /// Private (RFC 1918), link-local, IPv6 unique local and link-local, and loopback. An IPv4-mapped IPv6
    /// address counts as its IPv4 address. Anything that doesn't parse is not private.
    package static func isPrivate(_ text: String) -> Bool {
        var host = text
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }  // fe80::1%en0
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return isPrivate(v4: UInt32(bigEndian: v4.s_addr)) }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        // ::ffff:a.b.c.d
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isPrivate(v4: UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
        }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }  // ::1
        if b[0] & 0xfe == 0xfc { return true }  // fc00::/7, unique local
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }  // fe80::/10, link-local
        return false
    }

    private static func isPrivate(v4 a: UInt32) -> Bool {
        let o1 = a >> 24, o2 = (a >> 16) & 0xff
        return o1 == 10                                  // 10.0.0.0/8
            || (o1 == 172 && (16...31).contains(o2))     // 172.16.0.0/12
            || (o1 == 192 && o2 == 168)                  // 192.168.0.0/16
            || (o1 == 169 && o2 == 254)                  // 169.254.0.0/16, link-local
            || o1 == 127                                 // loopback
    }

    /// One address of this machine to listen on.
    package struct Local: Hashable, Sendable {
        /// The address as text; link-local IPv6 includes its interface ("fe80::1%en0").
        package var address: String
        package var interface: String
        package var isIPv6: Bool
    }

    /// This machine's addresses to listen on: private ones on interfaces that are up, leaving out the ones that
    /// reach past the local network. That is: point-to-point links (VPN tunnels), Apple's peer-to-peer Wi-Fi
    /// (`awdl`, `llw`, used by AirDrop), and IPv6 link-local addresses on interfaces with no other private address
    /// (loopback always stays).
    package static func local() -> [Local] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [Local] = []
        var loopbackInterfaces = Set<String>()
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_POINTOPOINT) == 0, let sa = ifa.pointee.ifa_addr else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("awdl") || name.hasPrefix("llw") { continue }
            if flags & Int32(IFF_LOOPBACK) != 0 { loopbackInterfaces.insert(name) }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: buf)
            guard isPrivate(text) else { continue }
            let local = Local(address: text, interface: name, isIPv6: family == AF_INET6)
            if !found.contains(local) { found.append(local) }
        }
        // Interfaces on a real local network: they have a private address that isn't link-local.
        let onLAN = Set(found.filter { !isLinkLocal($0.address) }.map(\.interface)).union(loopbackInterfaces)
        return found.filter { !isLinkLocal($0.address) || onLAN.contains($0.interface) }
    }

    /// 169.254.0.0/16 or fe80::/10.
    package static func isLinkLocal(_ text: String) -> Bool {
        let host = text.split(separator: "%").first.map(String.init) ?? text
        if host.hasPrefix("169.254.") { return true }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        return b[0] == 0xfe && b[1] & 0xc0 == 0x80
    }
}
