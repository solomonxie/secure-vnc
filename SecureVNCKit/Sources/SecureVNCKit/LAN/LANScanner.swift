import Foundation

/// Finds devices on this device's subnet and gathers what identifies them: ping, TCP ports, Bonjour,
/// NetBIOS, reverse DNS and, when a server on the same network is connected, its ARP table for MACs.
public enum LANScanner {
    /// Probed on every address to find hosts that drop pings (a refusal proves the host is there).
    static let discoveryPorts: [UInt16] = [80, 443, 22, 445, 62078]
    /// Then on every host found.
    public static let ports: [UInt16] = [
        21, 22, 23, 53, 80, 139, 443, 445, 548, 554, 631, 1400, 1883, 3000, 3389, 5000, 5001, 5900,
        7000, 8006, 8008, 8009, 8080, 8123, 8443, 9100, 32400, 62078,
    ]

    public typealias Neighbors = @Sendable (_ addresses: [String]) async -> [String: String]

    public static func scan(address: String, netmask: String, gateway: String? = nil, neighbors: Neighbors? = nil,
                            update: @escaping @Sendable ([LANDevice], String) -> Void) async {
        let hosts = IPv4.hosts(address: address, netmask: netmask)
        guard !hosts.isEmpty, let me = IPv4.parse(address) else { return update([], "No subnet to scan.") }
        let state = ScanState(me: address, update: update)
        let cancel = CancelFlag()
        await withTaskCancellationHandler {
            await state.mark(address) { $0.isSelf = true }
            await state.status("Pinging \(hosts.count) addresses…")
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await ServiceDiscovery.browse(for: 6) { service in Task { await state.add(service) } }
                }
                group.addTask {
                    let replies = await blocking { Probes.ping(hosts.filter { $0 != me }, timeout: 2) }
                    for (ip, rtt) in replies { await state.mark(IPv4.format(ip)) { $0.latency = rtt } }
                    await state.status("Looking for devices that ignore ping…")
                    let ports = hosts.count > 254 ? Array(discoveryPorts.prefix(2)) + [62078] : discoveryPorts
                    let targets = hosts.filter { $0 != me }.flatMap { ip in ports.map { (ip: ip, port: $0) } }
                    let states = await blocking { Probes.connect(targets, timeout: 0.7, concurrency: 128, cancelled: cancel.isSet) }
                    for (t, s) in zip(targets, states) where s != .silent {
                        await state.mark(IPv4.format(t.ip)) { if s == .open { $0.openPorts.insert(Int(t.port)) } }
                    }
                }
                if let neighbors {
                    group.addTask {
                        for (ip, mac) in await neighbors(hosts.map(IPv4.format)) where hosts.contains(IPv4.parse(ip) ?? 0) {
                            await state.mark(ip) { $0.mac = $0.mac ?? mac }
                        }
                    }
                }
            }
            guard !cancel.isSet() else { return }
            let found = await state.addresses().filter { $0 != me }
            let first = (me & 0xFFFF_FF00) + 1
            let gatewayIP = gateway ?? (found.contains(first) ? IPv4.format(first) : nil)
            if let gatewayIP { await state.mark(gatewayIP) { $0.isGateway = true } }

            await state.status("Scanning \(found.count) devices…")
            let rest = LANScanner.ports.filter { !discoveryPorts.prefix(2).contains($0) && $0 != 62078 }
            let targets = found.flatMap { ip in rest.map { (ip: ip, port: $0) } }
            async let names = blocking { Probes.netbios(found, timeout: 1.5) }
            let states = await blocking { Probes.connect(targets, timeout: 1.2, concurrency: 128, cancelled: cancel.isSet) }
            for (t, s) in zip(targets, states) where s == .open {
                await state.mark(IPv4.format(t.ip)) { $0.openPorts.insert(Int(t.port)) }
            }
            for (ip, nb) in await names {
                await state.mark(IPv4.format(ip)) {
                    if !$0.names.contains(nb.name) { $0.names.append(nb.name) }
                    $0.mac = $0.mac ?? nb.mac
                }
            }
            guard !cancel.isSet() else { return }

            await state.status("Reading banners and names…")
            let devices = await state.snapshot()
            await withTaskGroup(of: Void.self) { group in
                for d in devices where !d.isSelf {
                    guard let ip = IPv4.parse(d.ip) else { continue }
                    if d.openPorts.contains(22) {
                        group.addTask { if let b = await blocking({ Probes.sshBanner(ip) }) { await state.mark(d.ip) { $0.banners[22] = b } } }
                    }
                    for port in [80, 8080, 5000] where d.openPorts.contains(port) {
                        group.addTask {
                            if let b = await blocking({ Probes.httpServer(ip, port: UInt16(port)) }) { await state.mark(d.ip) { $0.banners[port] = b } }
                        }
                    }
                    group.addTask {
                        if let name = await blocking({ Probes.reverseName(ip) }), name != d.ip {
                            await state.mark(d.ip) { if !$0.names.contains(name) { $0.names.append(name) } }
                        }
                    }
                }
            }
            await state.status(nil)
        } onCancel: {
            cancel.set()
        }
    }

    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: work()) }
        }
    }
}

private actor ScanState {
    private var devices: [String: LANDevice] = [:]
    /// `_device-info` models by service name, until a device with that name turns up.
    private var models: [String: String] = [:]
    private var text: String?
    private let me: String
    private let update: @Sendable ([LANDevice], String) -> Void

    init(me: String, update: @escaping @Sendable ([LANDevice], String) -> Void) {
        self.me = me
        self.update = update
    }

    func mark(_ ip: String, _ change: (inout LANDevice) -> Void) {
        var d = devices[ip] ?? LANDevice(ip: ip)
        change(&d)
        devices[ip] = d
        publish()
    }

    func add(_ service: DiscoveredService) {
        if service.ip == nil, let model = service.model {
            models[service.name] = model
            for (ip, d) in devices where d.names.contains(service.name) && !d.models.contains(model) {
                devices[ip]?.models.insert(model, at: 0)
            }
            return publish()
        }
        guard var ip = service.ip else { return }
        // This device's own services resolve to loopback.
        if ip.hasPrefix("127.") { ip = me }
        mark(ip) { d in
            if !d.names.contains(service.name) { d.names.insert(service.name, at: 0) }
            d.services.insert(service.type)
            if let m = service.model, !d.models.contains(m) { d.models.append(m) }
            if let m = models[service.name], !d.models.contains(m) { d.models.insert(m, at: 0) }
        }
    }

    func status(_ text: String?) {
        self.text = text
        publish()
    }

    func addresses() -> [UInt32] { devices.keys.compactMap(IPv4.parse) }
    func snapshot() -> [LANDevice] { devices.values.sorted { $0.sortKey < $1.sortKey } }

    private func publish() { update(snapshot(), text ?? "") }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func isSet() -> Bool { lock.withLock { value } }
}
