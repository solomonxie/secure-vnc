import SecureVNCKit
import SwiftUI

/// Devices on this iPhone's Wi-Fi, with a guess at what each one is.
struct LANScanView: View {
    /// A connected server, used for MAC addresses when it's on the same network.
    let system: RemoteSystem?
    let peer: String?
    @State private var devices: [LANDevice] = []
    @State private var status = ""
    @State private var scanning: Task<Void, Never>?
    @State private var note: String?
    @State private var scanID = UUID()

    var body: some View {
        List {
            Section {
                if scanning != nil {
                    HStack { ProgressView(); Text(status.isEmpty ? "Scanning…" : status).foregroundStyle(.secondary) }
                }
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            Section(devices.isEmpty ? "" : "\(devices.count) devices") {
                ForEach(devices) { d in
                    NavigationLink { LANDeviceView(device: d) } label: { LANDeviceRow(device: d) }
                }
            }
        }
        .navigationTitle("Local Network")
        .toolbar {
            Button(scanning == nil ? "Scan" : "Stop") { scanning == nil ? scan() : stop() }
        }
        .onAppear { if devices.isEmpty { scan() } }
        .onDisappear(perform: stop)
    }

    private func stop() {
        scanning?.cancel()
        scanning = nil
        scanID = UUID()
    }

    private func scan() {
        guard let wifi = DeviceStats.wifiIPv4() else {
            note = "Join a Wi-Fi network to scan it."
            return
        }
        let subnet = Set(IPv4.hosts(address: wifi.address, netmask: wifi.netmask))
        let sameNetwork = peer.flatMap(IPv4.parse).map(subnet.contains) ?? false
        let server = sameNetwork ? system : nil
        note = server != nil ? "MAC addresses and makers come from the connected server's ARP table."
            : "iOS hides MAC addresses from apps, so makers show only for devices that report their own (Windows, Samba). Scan from a session to a Mac or Linux machine on this Wi-Fi to see more."
        let neighbors: LANScanner.Neighbors? = server.map { s in { (try? await s.neighbors($0)) ?? [:] } }
        devices = []
        let id = UUID()
        scanID = id
        scanning = Task {
            await LANScanner.scan(address: wifi.address, netmask: wifi.netmask, neighbors: neighbors) { found, text in
                Task { @MainActor in
                    guard scanID == id else { return }
                    devices = found
                    status = text
                }
            }
            if scanID == id { scanning = nil }
        }
    }
}

struct LANDeviceRow: View {
    let device: LANDevice

    var body: some View {
        let guess = device.guess
        HStack(spacing: 12) {
            Image(systemName: guess.kind.symbol)
                .font(.title3)
                .frame(width: 36)
                .foregroundStyle(device.isSelf ? Color.accentColor : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.isSelf ? "This iPhone" : device.name ?? guess.kind.label).lineLimit(1)
                Text([device.ip, device.vendor ?? (device.name == nil ? nil : guess.kind.label)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !device.openPorts.isEmpty {
                Text("\(device.openPorts.count) open").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct LANDeviceView: View {
    let device: LANDevice
    @State private var browsing: URL?

    var body: some View {
        let guess = device.guess
        List {
            Section {
                LabeledContent("Probably", value: guess.kind.label)
                if !guess.reason.isEmpty { LabeledContent("Because", value: guess.reason) }
                LabeledContent("IP address", value: device.ip)
                if let mac = device.mac {
                    LabeledContent("MAC address", value: mac + (MACAddress.isPrivate(mac) ? " (private)" : ""))
                }
                if let v = device.vendor { LabeledContent("Maker", value: v) }
                if let ms = device.latency { LabeledContent("Ping", value: String(format: "%.1f ms", ms * 1000)) }
                if device.isGateway { LabeledContent("Role", value: "Default gateway") }
            }
            .textSelection(.enabled)
            if !device.names.isEmpty {
                Section("Names") { ForEach(device.names, id: \.self) { Text($0).textSelection(.enabled) } }
            }
            if !device.models.isEmpty {
                Section("Reported model") { ForEach(device.models, id: \.self) { Text($0) } }
            }
            if !device.openPorts.isEmpty {
                Section("Open ports") {
                    ForEach(device.openPorts.sorted(), id: \.self) { p in
                        HStack {
                            Text("\(p)").monospacedDigit().frame(width: 60, alignment: .leading)
                            VStack(alignment: .leading) {
                                Text(Self.service(p))
                                if let b = device.banners[p] { Text(b).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let url = Self.webURL(device.ip, p) {
                                Button { browsing = url } label: { Image(systemName: "safari") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            if !device.services.isEmpty {
                Section("Bonjour services") {
                    ForEach(device.services.sorted(), id: \.self) { Text($0).font(.callout.monospaced()) }
                }
            }
            Section {
                Button("Copy IP Address") { UIPasteboard.general.string = device.ip }
            }
        }
        .navigationTitle(device.isSelf ? "This iPhone" : device.name ?? device.ip)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $browsing) { SafariView(url: $0).ignoresSafeArea() }
    }

    static func webURL(_ ip: String, _ port: Int) -> URL? {
        switch port {
        case 80, 3000, 5000, 8008, 8080, 8123, 32400: URL(string: "http://\(ip):\(port)/")
        case 443, 5001, 8006, 8443: URL(string: "https://\(ip):\(port)/")
        default: nil
        }
    }

    static func service(_ port: Int) -> String {
        switch port {
        case 21: "FTP"
        case 22: "SSH"
        case 23: "Telnet"
        case 53: "DNS"
        case 80: "Web"
        case 139: "NetBIOS"
        case 443: "Web (HTTPS)"
        case 445: "File sharing (SMB)"
        case 548: "File sharing (AFP)"
        case 554: "Video stream (RTSP)"
        case 631: "Printing (IPP)"
        case 1400: "Sonos"
        case 1883: "MQTT"
        case 3000: "Dev / web app"
        case 3389: "Remote Desktop"
        case 5000: "Web / AirPlay / Synology"
        case 5001: "Synology (HTTPS)"
        case 5900: "Screen Sharing (VNC)"
        case 7000: "AirPlay"
        case 8006: "Proxmox"
        case 8008, 8009: "Google Cast"
        case 8080: "Web (alt)"
        case 8123: "Home Assistant"
        case 8443: "Web (alt HTTPS)"
        case 9100: "Printing (raw)"
        case 32400: "Plex"
        case 62078: "iPhone / iPad sync"
        default: ""
        }
    }
}
