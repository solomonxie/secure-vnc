import Foundation

/// One sample of a machine's state. Rates (`cpuUsage` on Linux and this device, network speeds)
/// need two samples: see `updatingRates(from:)`.
public struct SystemStats: Sendable {
    public struct Disk: Sendable, Hashable {
        public var mount: String
        public var total: UInt64
        public var available: UInt64
        public var used: UInt64 { total > available ? total - available : 0 }
    }

    public struct Interface: Sendable, Hashable {
        public var name: String
        public var addresses: [String] = []
        public var mac: String?
        public var up = false
        public var rxBytes: UInt64 = 0
        public var txBytes: UInt64 = 0
        public var rxRate: Double?
        public var txRate: Double?
        /// Counters that wrap at 2³² (iOS `if_data`).
        var counterWidth: UInt64 = 0
    }

    public struct Battery: Sendable, Hashable {
        public var percent: Int
        public var state: String

        public init(percent: Int, state: String) {
            self.percent = percent
            self.state = state
        }
    }

    public var hostname = ""
    public var os = ""
    public var model = ""
    public var cpuName = ""
    public var kernel = ""
    public var cpuCount = 0
    public var bootTime: Date?
    public var load: [Double] = []
    /// 0…1.
    public var cpuUsage: Double?
    public var memoryUsed: UInt64 = 0
    public var memoryTotal: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var disks: [Disk] = []
    public var interfaces: [Interface] = []
    public var gateway: String?
    public var battery: Battery?
    public var sampledAt = Date()
    var cpuTicks: (busy: UInt64, total: UInt64)?

    public init() {}

    /// Interfaces worth showing: with an address, not loopback.
    public var activeInterfaces: [Interface] {
        interfaces.filter { !$0.addresses.isEmpty && !$0.name.hasPrefix("lo") }
    }

    public var ipv4Addresses: [String] {
        activeInterfaces.flatMap(\.addresses).filter { !$0.contains(":") }
    }

    public func updatingRates(from previous: SystemStats?) -> SystemStats {
        guard let previous else { return self }
        var next = self
        let dt = sampledAt.timeIntervalSince(previous.sampledAt)
        if let now = cpuTicks, let before = previous.cpuTicks, now.total > before.total {
            next.cpuUsage = Double(now.busy &- before.busy) / Double(now.total - before.total)
        }
        guard dt > 0 else { return next }
        let old = Dictionary(previous.interfaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for i in next.interfaces.indices {
            guard let o = old[next.interfaces[i].name] else { continue }
            let w = next.interfaces[i].counterWidth
            next.interfaces[i].rxRate = Self.delta(next.interfaces[i].rxBytes, o.rxBytes, width: w).map { Double($0) / dt }
            next.interfaces[i].txRate = Self.delta(next.interfaces[i].txBytes, o.txBytes, width: w).map { Double($0) / dt }
        }
        return next
    }

    private static func delta(_ now: UInt64, _ before: UInt64, width: UInt64) -> UInt64? {
        if now >= before { return now - before }
        return width > 0 ? width - before + now : nil
    }
}

// MARK: Parsing the remote script's output

extension SystemStats {
    /// Output of `RemoteSystem.statsScript`: `@@section` lines, each followed by its command's output.
    static func parse(_ text: String, now: Date = Date()) -> SystemStats {
        var sections: [String: [Substring]] = [:]
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") { current = String(line.dropFirst(2)); continue }
            sections[current, default: []].append(line)
        }
        var s = SystemStats()
        s.sampledAt = now
        var info: [String: String] = [:]
        for line in sections["info"] ?? [] {
            let kv = line.split(separator: "\t", maxSplits: 1)
            if kv.count == 2 { info[String(kv[0])] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        s.hostname = info["host"] ?? ""
        s.os = info["os"] ?? ""
        s.model = info["model"] ?? ""
        s.cpuName = info["cpuname"] ?? ""
        s.kernel = info["kernel"] ?? ""
        s.cpuCount = Int(info["cpus"] ?? "") ?? 0
        s.load = (info["load"] ?? "").split(separator: " ").compactMap { Double($0) }
        s.gateway = info["gateway"].flatMap { $0.isEmpty ? nil : $0 }
        let remoteNow = TimeInterval(info["now"] ?? "").map(Date.init(timeIntervalSince1970:)) ?? now
        if let boot = TimeInterval(info["boot"] ?? "") {
            s.bootTime = Date(timeIntervalSince1970: boot)
        } else if let up = TimeInterval(info["uptime"] ?? "") {
            s.bootTime = remoteNow.addingTimeInterval(-up)
        }
        if let cpu = info["cpu"] { s.cpuUsage = parseTopCPU(cpu) }
        if let ticks = info["cputicks"] { s.cpuTicks = parseProcStat(ticks) }
        if let total = UInt64(info["memtotal"] ?? "") { s.memoryTotal = total }
        if let vm = sections["vm"] { s.memoryUsed = parseVMStat(vm) }
        if let swap = sections["swap"]?.first { (s.swapUsed, s.swapTotal) = parseSwapUsage(String(swap)) }
        if let mem = sections["meminfo"] { parseMeminfo(mem, into: &s) }
        s.battery = parseBattery(sections["battery"] ?? [])
        s.disks = parseDF(sections["df"] ?? [])
        var ifaces = parseAddresses(sections["addr"] ?? [])
        let counters = sections["net"].map(parseNetstat) ?? sections["netdev"].map(parseProcNetDev) ?? [:]
        for (name, c) in counters {
            if let i = ifaces.firstIndex(where: { $0.name == name }) {
                ifaces[i].rxBytes = c.rx
                ifaces[i].txBytes = c.tx
            } else {
                ifaces.append(Interface(name: name, rxBytes: c.rx, txBytes: c.tx))
            }
        }
        s.interfaces = ifaces.sorted { $0.name < $1.name }
        return s
    }

    /// `CPU usage: 5.12% user, 3.45% sys, 91.42% idle`
    static func parseTopCPU(_ line: String) -> Double? {
        guard let r = line.range(of: #"([\d.]+)% idle"#, options: .regularExpression) else { return nil }
        let idle = Double(line[r].dropLast(6)) ?? 100
        return max(0, min(1, (100 - idle) / 100))
    }

    /// `cpu  user nice system idle iowait irq softirq steal …`
    static func parseProcStat(_ line: String) -> (busy: UInt64, total: UInt64)? {
        let n = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard n.count >= 4 else { return nil }
        let total = n.prefix(8).reduce(0, +)
        let idle = n[3] + (n.count > 4 ? n[4] : 0)
        return (total - idle, total)
    }

    /// Like Activity Monitor's "Memory Used": app memory + wired + compressed.
    static func parseVMStat(_ lines: [Substring]) -> UInt64 {
        var page: UInt64 = 4096
        var v: [String: UInt64] = [:]
        for line in lines {
            if let r = line.range(of: #"page size of (\d+)"#, options: .regularExpression) {
                page = UInt64(line[r].split(separator: " ").last ?? "") ?? page
                continue
            }
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            v[String(kv[0])] = UInt64(kv[1].trimmingCharacters(in: CharacterSet(charactersIn: " .")))
        }
        let wired = v["Pages wired down"] ?? 0
        let compressed = v["Pages occupied by compressor"] ?? 0
        let app = v["Anonymous pages"].map { $0 - min($0, v["Pages purgeable"] ?? 0) } ?? v["Pages active"] ?? 0
        return (app + wired + compressed) * page
    }

    /// `total = 2048.00M  used = 1030.50M  free = 1017.50M  (encrypted)`
    static func parseSwapUsage(_ line: String) -> (used: UInt64, total: UInt64) {
        func value(_ key: String) -> UInt64 {
            guard let r = line.range(of: key + #" = ([\d.]+)([KMGT])"#, options: .regularExpression) else { return 0 }
            let token = line[r].split(separator: " ").last ?? ""
            let unit: Double = switch token.last {
            case "K": 0x1p10
            case "M": 0x1p20
            case "G": 0x1p30
            default: 0x1p40
            }
            return UInt64((Double(token.dropLast()) ?? 0) * unit)
        }
        return (value("used"), value("total"))
    }

    static func parseMeminfo(_ lines: [Substring], into s: inout SystemStats) {
        var kb: [String: UInt64] = [:]
        for line in lines {
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0].hasSuffix(":"), let n = UInt64(parts[1]) else { continue }
            kb[String(parts[0].dropLast())] = n * 1024
        }
        s.memoryTotal = kb["MemTotal"] ?? 0
        let available = kb["MemAvailable"] ?? (kb["MemFree"] ?? 0) + (kb["Cached"] ?? 0) + (kb["Buffers"] ?? 0)
        s.memoryUsed = s.memoryTotal - min(s.memoryTotal, available)
        s.swapTotal = kb["SwapTotal"] ?? 0
        s.swapUsed = s.swapTotal - min(s.swapTotal, kb["SwapFree"] ?? 0)
    }

    /// `pmset -g batt` (`… 87%; charging; 1:23 remaining …`) or `87%; Charging`.
    static func parseBattery(_ lines: [Substring]) -> Battery? {
        for line in lines {
            guard let r = line.range(of: #"(\d+)%;\s*[^;]+"#, options: .regularExpression) else { continue }
            let parts = line[r].split(separator: ";", maxSplits: 1)
            guard let pct = Int(parts[0].dropLast()) else { continue }
            return Battery(percent: pct, state: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces).lowercased() : "")
        }
        return nil
    }

    /// Real block devices from `df -kP`; macOS's hidden system volumes share the root container.
    static func parseDF(_ lines: [Substring]) -> [Disk] {
        var seen = Set<String>()
        var disks: [Disk] = []
        for line in lines.dropFirst() {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 6, f[0].hasPrefix("/dev/"), !f[0].hasPrefix("/dev/loop"),
                  let total = UInt64(f[1]), let avail = UInt64(f[3]), total > 0 else { continue }
            let mount = f[5...].joined(separator: " ")
            guard !mount.hasPrefix("/System/Volumes/"), !mount.hasPrefix("/private/var/vm"),
                  !mount.hasPrefix("/Library/Developer/CoreSimulator"), seen.insert(String(f[0])).inserted else { continue }
            disks.append(Disk(mount: mount, total: total * 1024, available: avail * 1024))
        }
        return disks
    }

    /// `name<TAB>inet|inet6|ether|up<TAB>value`
    static func parseAddresses(_ lines: [Substring]) -> [Interface] {
        var order: [String] = []
        var map: [String: Interface] = [:]
        for line in lines {
            let f = line.split(separator: "\t")
            guard f.count == 3 else { continue }
            let name = String(f[0]).replacingOccurrences(of: "@.*", with: "", options: .regularExpression)
            if map[name] == nil { order.append(name); map[name] = Interface(name: name) }
            let value = String(f[2])
            switch f[1] {
            case "inet": map[name]?.addresses.append(value)
            case "inet6" where !value.lowercased().hasPrefix("fe80") && value != "::1": map[name]?.addresses.append(value)
            case "ether" where value != "00:00:00:00:00:00": map[name]?.mac = value
            case "up": map[name]?.up = true
            default: break
            }
        }
        return order.compactMap { map[$0] }
    }

    /// macOS `netstat -ibn`: the `<Link#N>` row of each interface has its byte counters.
    static func parseNetstat(_ lines: [Substring]) -> [String: (rx: UInt64, tx: UInt64)] {
        var out: [String: (rx: UInt64, tx: UInt64)] = [:]
        for line in lines {
            let f = line.split(separator: " ")
            guard f.count >= 8, let link = f.firstIndex(where: { $0.hasPrefix("<Link#") }) else { continue }
            var rest = Array(f[(link + 1)...])
            if rest.first?.contains(":") == true { rest.removeFirst() }
            guard rest.count >= 6, let rx = UInt64(rest[2]), let tx = UInt64(rest[5]) else { continue }
            let name = String(f[0]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if out[name] == nil { out[name] = (rx, tx) }
        }
        return out
    }

    /// Linux `/proc/net/dev`.
    static func parseProcNetDev(_ lines: [Substring]) -> [String: (rx: UInt64, tx: UInt64)] {
        var out: [String: (rx: UInt64, tx: UInt64)] = [:]
        for line in lines {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let n = kv[1].split(separator: " ").compactMap { UInt64($0) }
            guard n.count >= 9 else { continue }
            out[kv[0].trimmingCharacters(in: .whitespaces)] = (n[0], n[8])
        }
        return out
    }
}

public struct RemoteProcess: Sendable, Hashable, Identifiable {
    public var pid: Int
    public var cpu: Double
    public var memory: Double
    public var rssKB: UInt64
    public var user: String
    public var name: String
    public var id: Int { pid }

    /// `ps -o pid=,pcpu=,pmem=,rss=,user=,comm=`
    static func parse(_ text: String) -> [RemoteProcess] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count == 6, let pid = Int(f[0]) else { return nil }
            let name = (f[5].trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            return RemoteProcess(pid: pid, cpu: Double(f[1].replacingOccurrences(of: ",", with: ".")) ?? 0,
                                 memory: Double(f[2].replacingOccurrences(of: ",", with: ".")) ?? 0,
                                 rssKB: UInt64(f[3]) ?? 0, user: String(f[4]), name: name)
        }
    }
}

/// Public IP and its rough location, from ipinfo.io.
public struct PublicIP: Sendable, Decodable {
    public var ip: String
    public var hostname: String?
    public var city: String?
    public var region: String?
    public var country: String?
    public var org: String?
    public var timezone: String?

    public static let url = URL(string: "https://ipinfo.io/json")!

    public var place: String {
        [city, region, country].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }

    public static func decode(_ bytes: [UInt8]) throws -> PublicIP {
        try JSONDecoder().decode(PublicIP.self, from: Data(bytes))
    }
}
