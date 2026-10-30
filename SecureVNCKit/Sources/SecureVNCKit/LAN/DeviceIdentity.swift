import Foundation

public enum MACAddress {
    /// `a0:b1:2:…` → `A0:B1:02:…`; nil for anything else, incomplete or broadcast.
    public static func normalize(_ raw: String) -> String? {
        let parts = raw.split(separator: raw.contains("-") ? "-" : ":")
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for p in parts {
            guard p.count <= 2, let b = UInt8(p, radix: 16) else { return nil }
            bytes.append(b)
        }
        guard bytes != [0, 0, 0, 0, 0, 0], bytes != [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] else { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Phones and newer laptops use a random, locally administered address per network.
    public static func isPrivate(_ mac: String) -> Bool {
        guard let first = UInt8(mac.prefix(2), radix: 16) else { return false }
        return first & 0x02 != 0
    }

    /// Manufacturer from the IEEE registry (bundled), for a globally assigned address.
    public static func vendor(_ mac: String) -> String? {
        guard !isPrivate(mac) else { return nil }
        let key = mac.replacingOccurrences(of: ":", with: "").prefix(6).uppercased()
        return vendors[key]
    }

    private static let vendors: [String: String] = {
        guard let url = Bundle.module.url(forResource: "mac-vendors", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        map.reserveCapacity(41_000)
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            map[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return map
    }()
}

public enum DeviceKind: String, Sendable, CaseIterable {
    case router, mac, iPhone, iPad, appleTV, homePod, appleWatch, windows, linux, nas, printer,
         tv, speaker, camera, smartHome, gameConsole, phone, computer, unknown

    public var label: String {
        switch self {
        case .router: "Router"
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .appleTV: "Apple TV"
        case .homePod: "HomePod"
        case .appleWatch: "Apple Watch"
        case .windows: "Windows PC"
        case .linux: "Linux / server"
        case .nas: "NAS"
        case .printer: "Printer"
        case .tv: "TV / streamer"
        case .speaker: "Speaker"
        case .camera: "Camera"
        case .smartHome: "Smart home"
        case .gameConsole: "Game console"
        case .phone: "Phone"
        case .computer: "Computer"
        case .unknown: "Device"
        }
    }

    public var symbol: String {
        switch self {
        case .router: "wifi.router"
        case .mac: "laptopcomputer"
        case .iPhone, .phone: "iphone"
        case .iPad: "ipad"
        case .appleTV, .tv: "tv"
        case .homePod: "homepod"
        case .appleWatch: "applewatch"
        case .windows, .computer: "desktopcomputer"
        case .linux: "server.rack"
        case .nas: "externaldrive.connected.to.line.below"
        case .printer: "printer"
        case .speaker: "hifispeaker"
        case .camera: "video"
        case .smartHome: "lightbulb"
        case .gameConsole: "gamecontroller"
        case .unknown: "questionmark.square.dashed"
        }
    }
}

/// Everything learned about one address on the network.
public struct LANDevice: Sendable, Identifiable, Hashable {
    public var ip: String
    public var mac: String?
    public var names: [String] = []
    /// Bonjour service types, e.g. `_ssh._tcp`.
    public var services: Set<String> = []
    public var openPorts: Set<Int> = []
    /// Model strings from Bonjour TXT records (`model=Mac14,2`, `md=Chromecast`…).
    public var models: [String] = []
    public var banners: [Int: String] = [:]
    public var latency: Double?
    public var isGateway = false
    public var isSelf = false
    public var id: String { ip }

    public init(ip: String) { self.ip = ip }

    public var vendor: String? { mac.flatMap(MACAddress.vendor) }
    public var name: String? { names.first }

    public var guess: (kind: DeviceKind, reason: String) { DeviceIdentity.guess(self) }

    /// Sorts 192.168.1.9 before 192.168.1.10.
    public var sortKey: UInt32 { IPv4.parse(ip) ?? .max }
}

public enum DeviceIdentity {
    /// Apple model identifiers (`Mac14,2`, `AppleTV11,1`, `AudioAccessory5,1`…) by prefix.
    static let appleModels: [(String, DeviceKind)] = [
        ("iPhone", .iPhone), ("iPad", .iPad), ("AppleTV", .appleTV), ("AudioAccessory", .homePod),
        ("Watch", .appleWatch), ("Mac", .mac), ("iMac", .mac), ("MacBook", .mac), ("Macmini", .mac),
        ("MacPro", .mac), ("Xserve", .mac),
    ]

    public static func guess(_ d: LANDevice) -> (kind: DeviceKind, reason: String) {
        if d.isSelf { return (.iPhone, "this iPhone") }
        let s = d.services
        let p = d.openPorts
        let vendor = d.vendor?.lowercased() ?? ""
        let models = d.models.joined(separator: " ")
        let names = d.names.joined(separator: " ").lowercased()

        for model in d.models {
            for (prefix, kind) in appleModels where model.hasPrefix(prefix) {
                return (kind, "model \(model)")
            }
        }
        if d.isGateway { return (.router, "default gateway") }
        if s.contains("_apple-mobdev2._tcp") || p.contains(62078) {
            return (names.contains("ipad") ? .iPad : .iPhone, "Apple device sync port")
        }
        if s.contains("_googlecast._tcp") || p.contains(8009) || s.contains("_androidtvremote2._tcp") || s.contains("_amzn-wplay._tcp") {
            return (.tv, s.contains("_googlecast._tcp") ? "Google Cast" : "TV remote service")
        }
        if s.contains("_sonos._tcp") || p.contains(1400) || s.contains("_spotify-connect._tcp") || (s.contains("_raop._tcp") && !s.contains("_ssh._tcp")) {
            return (.speaker, "audio streaming service")
        }
        if s.contains("_ipp._tcp") || s.contains("_ipps._tcp") || s.contains("_printer._tcp") || s.contains("_pdl-datastream._tcp") || p.contains(9100) || p.contains(631) {
            return (.printer, "printing service")
        }
        if p.contains(554) || ["hikvision", "dahua", "reolink", "amcrest", "axis", "wyze", "arlo"].contains(where: vendor.contains) {
            return (.camera, p.contains(554) ? "RTSP video port" : "camera maker")
        }
        if ["synology", "qnap", "western digital", "asustor", "terramaster", "buffalo"].contains(where: vendor.contains)
            || p.contains(5000) && p.contains(5001) || s.contains("_adisk._tcp") && !s.contains("_rfb._tcp") {
            return (.nas, vendor.isEmpty ? "NAS ports" : "NAS maker")
        }
        if s.contains("_hap._tcp") || s.contains("_hue._tcp") || s.contains("_matter._tcp") || s.contains("_esphomelib._tcp")
            || s.contains("_home-assistant._tcp") || p.contains(1883) || p.contains(8123)
            || ["espressif", "tuya", "shelly", "signify", "philips lighting", "ecobee", "nest", "ring", "ikea", "tp-link kasa", "sonoff", "itead"].contains(where: vendor.contains) {
            return (.smartHome, "smart-home service or maker")
        }
        if ["nintendo", "sony interactive", "microsoft xbox"].contains(where: vendor.contains) || names.contains("xbox") || names.contains("playstation") {
            return (.gameConsole, "console maker")
        }
        if ["samsung", "lg electronics", "vizio", "roku", "tcl", "hisense"].contains(where: vendor.contains) && (p.contains(8001) || p.contains(8008) || names.contains("tv")) {
            return (.tv, "TV maker")
        }
        if s.contains("_rfb._tcp") || s.contains("_afpovertcp._tcp") || s.contains("_companion-link._tcp") && s.contains("_ssh._tcp")
            || (vendor.contains("apple") && (p.contains(22) || p.contains(5900) || p.contains(548))) {
            return (.mac, "macOS sharing service")
        }
        if s.contains("_companion-link._tcp") || s.contains("_airplay._tcp") || vendor.contains("apple") {
            return (names.contains("ipad") ? .iPad : names.contains("tv") ? .appleTV : .iPhone, "Apple device")
        }
        if p.contains(3389) || (p.contains(445) && p.contains(139) && !p.contains(22)) {
            return (.windows, p.contains(3389) ? "Remote Desktop port" : "Windows file sharing")
        }
        if let ssh = d.banners[22] {
            let b = ssh.lowercased()
            if ["ubuntu", "debian", "raspbian", "fedora", "arch", "alpine", "centos", "linux"].contains(where: b.contains) || b.contains("dropbear") {
                return (.linux, ssh)
            }
        }
        if vendor.contains("raspberry") { return (.linux, "Raspberry Pi") }
        if s.contains("_workstation._tcp") || p.contains(22) || p.contains(8006) || p.contains(32400) {
            return (.linux, p.contains(8006) ? "Proxmox port" : p.contains(32400) ? "Plex server" : "SSH")
        }
        if p.contains(53) && (p.contains(80) || p.contains(443)) { return (.router, "DNS + web admin") }
        if ["samsung", "google", "xiaomi", "oneplus", "huawei", "motorola", "oppo", "vivo"].contains(where: vendor.contains) {
            return (.phone, "phone maker")
        }
        if ["intel", "dell", "lenovo", "hewlett", "asustek", "micro-star", "gigabyte", "realtek"].contains(where: vendor.contains) {
            return (.computer, "PC maker")
        }
        if !models.isEmpty { return (.unknown, models) }
        if d.mac.map(MACAddress.isPrivate) == true { return (.phone, "private Wi-Fi address") }
        return (.unknown, "")
    }
}

public enum IPv4 {
    public static func parse(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let b = UInt8(p) else { return nil }
            v = v << 8 | UInt32(b)
        }
        return v
    }

    public static func format(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }

    /// Hosts to sweep: the subnet, capped to the /22 around `address`, its own /24 first.
    public static func hosts(address: String, netmask: String) -> [UInt32] {
        guard let a = parse(address), var m = parse(netmask) else { return [] }
        if m < 0xFFFF_FC00 { m = 0xFFFF_FC00 }
        let network = a & m
        let broadcast = network | ~m
        guard broadcast > network + 1 else { return [] }
        let all = Array((network + 1)..<broadcast)
        let near = a & 0xFFFF_FF00
        return all.filter { $0 & 0xFFFF_FF00 == near } + all.filter { $0 & 0xFFFF_FF00 != near }
    }
}
