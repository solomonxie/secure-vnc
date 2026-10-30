import SecureVNCKit
import SwiftUI

/// Stats and tools for the connected server, or for this iPhone and its network.
struct SystemView: View {
    let title: String
    @StateObject private var monitor: SystemMonitor
    @ObservedObject var forwards: ForwardList
    @Environment(\.dismiss) private var dismiss

    init(title: String, tunnel: SSHTunnel?, forwards: ForwardList) {
        self.title = title
        self.forwards = forwards
        _monitor = StateObject(wrappedValue: SystemMonitor(tunnel: tunnel))
    }

    var body: some View {
        NavigationStack {
            List {
                if let s = monitor.stats {
                    overview(s)
                    usage(s)
                    network(s)
                } else if let error = monitor.error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    HStack { ProgressView(); Text("Reading stats…").foregroundStyle(.secondary) }
                }
                publicIP
                power
                tools
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await monitor.run() }
            .alert("Error", isPresented: .init(get: { monitor.toolError != nil }, set: { if !$0 { monitor.toolError = nil } })) {
                Button("OK") {}
            } message: {
                Text(monitor.toolError ?? "")
            }
        }
    }

    @ViewBuilder private func overview(_ s: SystemStats) -> some View {
        Section {
            if !s.hostname.isEmpty { row("Name", s.hostname) }
            if !s.os.isEmpty { row("System", s.os) }
            if !s.model.isEmpty { row("Model", s.model) }
            if !s.cpuName.isEmpty { row("CPU", s.cpuName) }
            if let boot = s.bootTime { row("Up", Format.uptime(since: boot)) }
            if monitor.isDevice {
                row("Thermal", Self.thermal(ProcessInfo.processInfo.thermalState))
            }
        }
    }

    @ViewBuilder private func usage(_ s: SystemStats) -> some View {
        Section("Usage") {
            if let cpu = s.cpuUsage {
                Meter(label: "CPU", value: cpu,
                      detail: (s.cpuCount > 0 ? "\(s.cpuCount) cores" : "") + (s.load.isEmpty ? "" : " · load " + s.load.map { String(format: "%.2f", $0) }.joined(separator: " ")))
            } else {
                row("CPU", "measuring…")
            }
            if s.memoryTotal > 0 {
                Meter(label: "Memory", value: Double(s.memoryUsed) / Double(s.memoryTotal),
                      detail: "\(Format.bytes(s.memoryUsed)) of \(Format.bytes(s.memoryTotal))"
                          + (s.swapUsed > 0 ? " · swap \(Format.bytes(s.swapUsed))" : "")
                          + (monitor.isDevice ? DeviceStats.appMemory.map { " · this app \(Format.bytes($0))" } ?? "" : ""))
            }
            ForEach(s.disks, id: \.mount) { d in
                Meter(label: s.disks.count == 1 ? "Disk" : d.mount, value: Double(d.used) / Double(max(d.total, 1)),
                      detail: "\(Format.size(d.available)) free of \(Format.size(d.total))")
            }
        }
    }

    @ViewBuilder private func network(_ s: SystemStats) -> some View {
        Section("Network") {
            ForEach(s.activeInterfaces, id: \.name) { i in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(monitor.isDevice ? "\(DeviceStats.label(i.name)) (\(i.name))" : i.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Label(Format.rate(i.rxRate), systemImage: "arrow.down").labelStyle(.titleAndIcon)
                        Label(Format.rate(i.txRate), systemImage: "arrow.up").labelStyle(.titleAndIcon)
                    }
                    .font(.caption.monospacedDigit())
                    ForEach(i.addresses, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if let mac = i.mac { Text(mac).font(.caption.monospaced()).foregroundStyle(.tertiary) }
                }
                .textSelection(.enabled)
            }
            if let gw = s.gateway { row("Gateway", gw) }
        }
    }

    private var publicIP: some View {
        Section {
            if let ip = monitor.publicIP {
                row("Public IP", ip.ip)
                if let org = ip.org { row("Network", org) }
                if !ip.place.isEmpty { row("Location", ip.place) }
            }
            Button {
                monitor.lookUpPublicIP()
            } label: {
                HStack {
                    Text(monitor.publicIP == nil ? "Look Up Public IP" : "Look Up Again")
                    if monitor.lookingUp { Spacer(); ProgressView() }
                }
            }
            .disabled(monitor.lookingUp)
        } footer: {
            Text(monitor.isDevice ? "Asks ipinfo.io from this iPhone." : "Asks ipinfo.io from the server.")
        }
    }

    @ViewBuilder private var power: some View {
        let battery = monitor.isDevice ? DeviceBattery.current : monitor.stats?.battery
        if battery != nil || monitor.awake != nil {
            Section {
                if let b = battery { row("Battery", "\(b.percent)%" + (b.state.isEmpty ? "" : " · \(b.state)")) }
                if let awake = monitor.awake {
                    Toggle("Keep Awake", isOn: .init(get: { awake }, set: { monitor.setAwake($0) }))
                }
            } footer: {
                if monitor.awake != nil {
                    Text("Holds off idle and system sleep until turned off, even after disconnecting. A Mac with its lid closed and no display still sleeps.")
                }
            }
        }
    }

    private var tools: some View {
        Section("Tools") {
            if let remote = monitor.remote {
                NavigationLink { ProcessesView(system: remote) } label: { Label("Processes", systemImage: "list.bullet.rectangle") }
            }
            NavigationLink { NetToolsView(system: monitor.remote) } label: {
                Label("Ping, Traceroute, DNS, Port", systemImage: "point.3.connected.trianglepath.dotted")
            }
            if let tunnel = monitor.tunnel {
                NavigationLink { ForwardsView(tunnel: tunnel, forwards: forwards) } label: {
                    Label("Open a Port There", systemImage: "safari")
                }
            }
            NavigationLink { LANScanView(system: monitor.remote, peer: monitor.tunnel?.peerAddress) } label: {
                Label("Scan Local Network", systemImage: "network")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).textSelection(.enabled).multilineTextAlignment(.trailing) }
    }

    static func thermal(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: "normal"
        case .fair: "warm"
        case .serious: "hot"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// A labelled usage bar; turns orange then red past 85% and 95%, with the number always shown.
struct Meter: View {
    let label: String
    let value: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(Format.percent(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(value, 0), 1))
                .tint(value > 0.95 ? .red : value > 0.85 ? .orange : .accentColor)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}

enum DeviceBattery {
    @MainActor static var current: SystemStats.Battery? {
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        guard d.batteryLevel >= 0 else { return nil }
        let state = switch d.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "on battery"
        default: ""
        }
        return SystemStats.Battery(percent: Int((d.batteryLevel * 100).rounded()), state: state)
    }
}
