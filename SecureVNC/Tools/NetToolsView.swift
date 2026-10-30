import SecureVNCKit
import SwiftUI

/// Ping, traceroute, DNS and port checks, run from this iPhone or from the server.
struct NetToolsView: View {
    let system: RemoteSystem?
    @State private var tool = NetTool.ping
    @State private var fromServer = false
    @State private var target = ""
    @State private var port = "443"
    @State private var output = ""
    @State private var running: Task<Void, Never>?

    private var runsOnServer: Bool { system != nil && (fromServer || tool == .traceroute) }

    var body: some View {
        Form {
            Section {
                Picker("Tool", selection: $tool) { ForEach(NetTool.allCases, id: \.self) { Text($0.label) } }
                    .pickerStyle(.segmented)
                if system != nil {
                    Picker("Run from", selection: $fromServer) {
                        Text("This iPhone").tag(false)
                        Text("Server").tag(true)
                    }
                    .disabled(tool == .traceroute)
                }
                TextField(tool == .dns ? "Name or IP address" : "Host or IP address", text: $target)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onSubmit(run)
                if tool == .port {
                    TextField("Port", text: $port).keyboardType(.numberPad)
                }
                Button(running == nil ? "Run" : "Stop") { running == nil ? run() : stop() }
                    .disabled(target.trimmed.isEmpty || (tool == .traceroute && system == nil))
            } footer: {
                if tool == .traceroute { Text(system == nil ? "Traceroute needs a server: iOS doesn't let apps set packet TTLs." : "Runs on the server.") }
            }
            if !output.isEmpty || running != nil {
                Section("Output") {
                    if running != nil { ProgressView() }
                    Text(output).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Network Tools")
        .onDisappear(perform: stop)
    }

    private func stop() {
        running?.cancel()
        running = nil
    }

    private func run() {
        let host = target.trimmed
        guard !host.isEmpty else { return }
        stop()
        output = ""
        let tool = tool, port = Int(port.trimmed) ?? 0, system = runsOnServer ? system : nil
        running = Task {
            defer { running = nil }
            if let system {
                do { output = try await system.tool(tool, target: host, port: port) } catch { output = error.localizedDescription }
                return
            }
            await runHere(tool, host: host, port: port)
        }
    }

    private func runHere(_ tool: NetTool, host: String, port: Int) async {
        func off<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T { await Task.detached { work() }.value }
        switch tool {
        case .ping:
            guard let ip = await off({ Probes.resolveIPv4(host) }) else { output = "Can't resolve \(host)."; return }
            output = "PING \(host) (\(IPv4.format(ip)))\n"
            var times: [Double] = []
            for seq in 0..<4 where !Task.isCancelled {
                let started = Date()
                let rtt = await off { Probes.ping([ip], sequence: UInt16(seq), timeout: 1)[ip] }
                if let rtt {
                    times.append(rtt * 1000)
                    output += String(format: "reply seq=%d time=%.1f ms\n", seq, rtt * 1000)
                } else {
                    output += "timeout seq=\(seq)\n"
                }
                try? await Task.sleep(for: .seconds(max(0, 1 - Date().timeIntervalSince(started))))
            }
            let loss = 100 - times.count * 25
            output += "\n\(times.count)/4 received, \(loss)% loss"
            if let lo = times.min(), let hi = times.max() {
                output += String(format: "\nmin/avg/max %.1f/%.1f/%.1f ms", lo, times.reduce(0, +) / Double(times.count), hi)
            }
        case .dns:
            let found = await off { Probes.lookup(host) }
            output = found.isEmpty ? "No records for \(host)." : found.joined(separator: "\n")
        case .port:
            guard (1...65535).contains(port) else { output = "Enter a port from 1 to 65535."; return }
            guard let ip = await off({ Probes.resolveIPv4(host) }) else { output = "Can't resolve \(host)."; return }
            let state = await off { Probes.connect([(ip, UInt16(port))], timeout: 3)[0] }
            let verdict = switch state {
            case .open: "open"
            case .closed: "closed (refused)"
            case .silent: "no answer (filtered or host down)"
            }
            output = "\(host):\(port) \(verdict)"
        case .traceroute:
            output = "Traceroute runs on a server."
        }
    }
}
