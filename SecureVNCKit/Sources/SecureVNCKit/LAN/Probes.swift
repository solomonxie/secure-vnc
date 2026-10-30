import Darwin
import Foundation

/// Blocking BSD-socket probes; run them off the main thread. All unprivileged, so they work on iOS:
/// ICMP through a datagram socket, TCP connects, unicast UDP.
public enum Probes {
    // MARK: ICMP echo

    /// One echo to each address; round-trip seconds of those that answered within `timeout`.
    public static func ping(_ targets: [UInt32], sequence: UInt16 = 0, timeout: TimeInterval) -> [UInt32: Double] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let ident = UInt16.random(in: 1...UInt16.max)
        var sent: [UInt32: Date] = [:]
        for (i, target) in targets.enumerated() {
            var packet: [UInt8] = [8, 0, 0, 0, UInt8(ident >> 8), UInt8(ident & 0xFF), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
            packet += [UInt8](repeating: 0x5A, count: 24)
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8)
            packet[3] = UInt8(sum & 0xFF)
            var addr = sockaddrIn(target, port: 0)
            for _ in 0..<3 {
                let n = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if n >= 0 { sent[target] = Date(); break }
                guard errno == ENOBUFS || errno == EAGAIN else { break }
                usleep(2000)
            }
            if i % 32 == 31 { usleep(1000) }
        }
        var replies: [UInt32: Double] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 1500)
        while replies.count < sent.count, wait(fd, POLLIN, until: deadline) {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            // Darwin hands datagram ICMP sockets the IP header too.
            let off = buf[0] >> 4 == 4 ? Int(buf[0] & 0x0F) * 4 : 0
            guard n >= off + 8, buf[off] == 0 else { continue }
            let source = UInt32(bigEndian: from.sin_addr.s_addr)
            if let at = sent[source], replies[source] == nil { replies[source] = Date().timeIntervalSince(at) }
        }
        return replies
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    // MARK: TCP connect

    public enum PortState: Sendable { case open, closed, silent }

    /// Connects to each target, `concurrency` at a time. A refusal (`closed`) still proves the host is up.
    public static func connect(_ targets: [(ip: UInt32, port: UInt16)], timeout: TimeInterval, concurrency: Int = 96,
                               cancelled: () -> Bool = { false }) -> [PortState] {
        var results = [PortState](repeating: .silent, count: targets.count)
        var inFlight: [(fd: Int32, index: Int, deadline: Date)] = []
        var next = 0
        while (next < targets.count || !inFlight.isEmpty) && !cancelled() {
            while next < targets.count, inFlight.count < concurrency {
                let i = next
                next += 1
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { continue }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddrIn(targets[i].ip, port: targets[i].port)
                let r = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if r == 0 {
                    results[i] = .open
                    close(fd)
                } else if errno == EINPROGRESS {
                    inFlight.append((fd, i, Date().addingTimeInterval(timeout)))
                } else {
                    results[i] = errno == ECONNREFUSED ? .closed : .silent
                    close(fd)
                }
            }
            var fds = inFlight.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            _ = poll(&fds, nfds_t(fds.count), 50)
            let now = Date()
            var keep: [(fd: Int32, index: Int, deadline: Date)] = []
            for (k, item) in inFlight.enumerated() {
                if fds[k].revents != 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(item.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    results[item.index] = err == 0 ? .open : err == ECONNREFUSED ? .closed : .silent
                    close(item.fd)
                } else if now > item.deadline {
                    close(item.fd)
                } else {
                    keep.append(item)
                }
            }
            inFlight = keep
        }
        inFlight.forEach { close($0.fd) }
        return results
    }

    /// Connects, optionally sends `request`, and returns what comes back within `timeout`.
    public static func exchange(_ ip: UInt32, port: UInt16, request: [UInt8] = [], timeout: TimeInterval, maxBytes: Int = 2048) -> [UInt8] {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddrIn(ip, port: port)
        let deadline = Date().addingTimeInterval(timeout)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 || errno == EINPROGRESS, wait(fd, POLLOUT, until: deadline) else { return [] }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        guard err == 0 else { return [] }
        if !request.isEmpty { _ = send(fd, request, request.count, 0) }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 1024)
        while out.count < maxBytes, wait(fd, POLLIN, until: deadline) {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { break }
            out += buf[0..<n]
            if request.isEmpty, out.contains(0x0A) { break }
        }
        return out
    }

    /// `SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13`
    public static func sshBanner(_ ip: UInt32, timeout: TimeInterval = 1.5) -> String? {
        let text = String(decoding: exchange(ip, port: 22, timeout: timeout, maxBytes: 256), as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.hasPrefix("SSH-") == true ? line : nil
    }

    /// The `Server:` header of `HEAD /`.
    public static func httpServer(_ ip: UInt32, port: UInt16, timeout: TimeInterval = 1.5) -> String? {
        let request = Array("HEAD / HTTP/1.0\r\nHost: \(IPv4.format(ip))\r\nUser-Agent: SecureVNC\r\n\r\n".utf8)
        let text = String(decoding: exchange(ip, port: port, request: request, timeout: timeout), as: UTF8.self)
        for line in text.split(separator: "\r\n") where line.lowercased().hasPrefix("server:") {
            let value = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: NetBIOS

    /// NetBIOS node status (UDP 137, unicast): the name Windows and Samba machines answer to, and
    /// often their MAC address.
    public static func netbios(_ targets: [UInt32], timeout: TimeInterval) -> [UInt32: (name: String, mac: String?)] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let query = netbiosQuery()
        let wanted = Set(targets)
        for target in targets {
            var addr = sockaddrIn(target, port: 137)
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, query, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        var out: [UInt32: (name: String, mac: String?)] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 1500)
        while out.count < wanted.count, wait(fd, POLLIN, until: deadline) {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            let source = UInt32(bigEndian: from.sin_addr.s_addr)
            guard n > 0, wanted.contains(source), let parsed = parseNetbios(Array(buf[0..<n])) else { continue }
            out[source] = parsed
        }
        return out
    }

    static func netbiosQuery() -> [UInt8] {
        var name = [UInt8(ascii: "*")] + [UInt8](repeating: 0, count: 15)
        name = name.flatMap { [0x41 + ($0 >> 4), 0x41 + ($0 & 0x0F)] }
        return [0x13, 0x37, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x20] + name + [0, 0, 0x21, 0, 1]
    }

    static func parseNetbios(_ b: [UInt8]) -> (name: String, mac: String?)? {
        var off = 12
        if off < b.count, b[off] & 0xC0 == 0xC0 {
            off += 2
        } else {
            while off < b.count, b[off] != 0 { off += Int(b[off]) + 1 }
            off += 1
        }
        off += 10
        guard off < b.count else { return nil }
        let count = Int(b[off])
        off += 1
        var name: String?
        for i in 0..<count {
            let e = off + i * 18
            guard e + 18 <= b.count else { return nil }
            let isGroup = b[e + 16] & 0x80 != 0
            if name == nil, b[e + 15] == 0, !isGroup {
                name = String(decoding: b[e..<e + 15], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let name, !name.isEmpty else { return nil }
        let m = off + count * 18
        let mac = m + 6 <= b.count ? MACAddress.normalize(b[m..<m + 6].map { String(format: "%02x", $0) }.joined(separator: ":")) : nil
        return (name, mac)
    }

    // MARK: Names

    /// Reverse DNS (unicast or multicast), e.g. `Solo-M1.local`.
    public static func reverseName(_ ip: UInt32) -> String? {
        var addr = sockaddrIn(ip, port: 0)
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &name, socklen_t(name.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard r == 0 else { return nil }
        let s = String(cString: name)
        return s.hasSuffix(".") ? String(s.dropLast()) : s
    }

    /// Every address a name resolves to, or the name of an address.
    public static func lookup(_ host: String) -> [String] {
        if let ip = IPv4.parse(host) { return reverseName(ip).map { [$0] } ?? [] }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        for ai in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let a = ai.pointee.ai_addr, let s = DeviceStats.numericHost(a), !out.contains(s) else { continue }
            out.append(s)
        }
        return out
    }

    public static func resolveIPv4(_ host: String) -> UInt32? {
        if let ip = IPv4.parse(host) { return ip }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res, let a = first.pointee.ai_addr else { return nil }
        defer { freeaddrinfo(res) }
        return a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
    }

    // MARK: Helpers

    static func sockaddrIn(_ ip: UInt32, port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = ip.bigEndian
        return a
    }

    /// Polls one descriptor until it's ready or `deadline` passes.
    private static func wait(_ fd: Int32, _ event: Int32, until deadline: Date) -> Bool {
        while true {
            let ms = Int32(deadline.timeIntervalSinceNow * 1000)
            guard ms > 0 else { return false }
            var p = pollfd(fd: fd, events: Int16(event), revents: 0)
            let r = poll(&p, 1, ms)
            if r > 0 { return true }
            if r < 0, errno == EINTR { continue }
            return false
        }
    }
}
