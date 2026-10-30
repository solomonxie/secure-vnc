import Darwin
import XCTest
@testable import SecureVNCKit

final class SystemStatsTests: XCTestCase {
    func sh(_ script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testStatsScriptOnThisMac() throws {
        let s = SystemStats.parse(try sh(RemoteSystem.statsScript))
        XCTAssertFalse(s.hostname.isEmpty)
        XCTAssertTrue(s.os.hasPrefix("macOS"), s.os)
        XCTAssertGreaterThan(s.cpuCount, 0)
        XCTAssertNotNil(s.cpuUsage)
        XCTAssertEqual(s.load.count, 3)
        XCTAssertGreaterThan(s.memoryTotal, 0)
        XCTAssertGreaterThan(s.memoryUsed, 0)
        XCTAssertLessThan(s.memoryUsed, s.memoryTotal)
        XCTAssertNotNil(s.bootTime)
        XCTAssertTrue(s.disks.contains { $0.mount == "/" }, "\(s.disks)")
        XCTAssertFalse(s.ipv4Addresses.isEmpty)
        XCTAssertTrue(s.interfaces.contains { $0.rxBytes > 0 })
    }

    func testLinuxSections() {
        let text = """
        @@info
        host\tpi
        os\tDebian GNU/Linux 12 (bookworm)
        cpus\t4
        now\t1000
        uptime\t100.5
        load\t0.10 0.20 0.30
        gateway\t192.168.1.1
        cputicks\tcpu  100 0 50 800 50 0 0 0 0 0
        @@meminfo
        MemTotal:        8000000 kB
        MemAvailable:    6000000 kB
        SwapTotal:       1000 kB
        SwapFree:        1000 kB
        @@battery
        @@addr
        eth0\tether\tdc:a6:32:01:02:03
        eth0\tup\t1
        eth0\tinet\t192.168.1.20
        eth0\tinet6\tfe80::1
        lo\tinet\t127.0.0.1
        @@netdev
        Inter-|   Receive
         face |bytes    packets
            lo: 10 1 0 0 0 0 0 0 10 1 0 0 0 0 0 0
          eth0:5000 20 0 0 0 0 0 0 7000 30 0 0 0 0 0 0
        @@df
        Filesystem     1024-blocks    Used Available Capacity Mounted on
        /dev/root         30000000 10000000  18000000      36% /
        tmpfs               100000       0    100000       0% /dev/shm
        /dev/loop0           50000   50000         0     100% /snap/core
        """
        var s = SystemStats.parse(text, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(s.memoryUsed, 2_000_000 * 1024)
        XCTAssertEqual(s.bootTime, Date(timeIntervalSince1970: 899.5))
        XCTAssertEqual(s.disks.map(\.mount), ["/"])
        XCTAssertEqual(s.activeInterfaces.map(\.name), ["eth0"])
        XCTAssertEqual(s.activeInterfaces[0].addresses, ["192.168.1.20"])
        XCTAssertEqual(s.activeInterfaces[0].rxBytes, 5000)
        XCTAssertEqual(s.activeInterfaces[0].mac, "dc:a6:32:01:02:03")
        XCTAssertNil(s.cpuUsage)

        var later = s
        later.sampledAt = s.sampledAt.addingTimeInterval(2)
        later.cpuTicks = (busy: 300, total: 1200)
        later.interfaces[0].rxBytes = 9000
        s = later.updatingRates(from: s)
        XCTAssertEqual(s.cpuUsage ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(s.interfaces.first { $0.name == "eth0" }?.rxRate ?? 0, 2000, accuracy: 0.1)
    }

    func testMacParsers() {
        XCTAssertEqual(SystemStats.parseTopCPU("CPU usage: 5.12% user, 3.45% sys, 91.43% idle") ?? 0, 0.0857, accuracy: 0.0001)
        let swap = SystemStats.parseSwapUsage("total = 2048.00M  used = 1024.00M  free = 1024.00M  (encrypted)")
        XCTAssertEqual(swap.total, 2048 << 20)
        XCTAssertEqual(swap.used, 1024 << 20)
        let batt = SystemStats.parseBattery(["Now drawing from 'AC Power'", " -InternalBattery-0 (id=1)\t87%; charging; 1:00 remaining present: true"])
        XCTAssertEqual(batt, SystemStats.Battery(percent: 87, state: "charging"))
        let net = SystemStats.parseNetstat([
            "Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll",
            "lo0        16384 <Link#1>                          100     0      2000      100     0      2000     0",
            "en0        1500  <Link#11>   aa:bb:cc:dd:ee:ff    500     0     90000      400     0     30000     0",
            "en0        1500  192.168.1     192.168.1.5        500     -     90000      400     -     30000     -",
        ])
        XCTAssertEqual(net["en0"]?.rx, 90000)
        XCTAssertEqual(net["en0"]?.tx, 30000)
        XCTAssertEqual(net["lo0"]?.rx, 2000)
    }

    func testProcesses() {
        let p = RemoteProcess.parse("  123  12.5  1.0  20480 me  Google Chrome Helper\n    1   0.0  0.1   1000 root /sbin/launchd\n")
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].name, "Google Chrome Helper")
        XCTAssertEqual(p[0].cpu, 12.5)
        XCTAssertEqual(p[1].name, "launchd")
    }

    func testDeviceStatsSample() {
        let a = DeviceStats.sample()
        usleep(200_000)
        let b = DeviceStats.sample().updatingRates(from: a)
        XCTAssertNotNil(b.cpuUsage)
        XCTAssertGreaterThan(b.memoryUsed, 0)
        XCTAssertEqual(b.disks.count, 1)
        XCTAssertFalse(b.interfaces.isEmpty)
        XCTAssertNotNil(DeviceStats.appMemory)
    }
}

final class LANTests: XCTestCase {
    func testMACAndVendor() {
        XCTAssertEqual(MACAddress.normalize("a0:b1:2:d3:e4:f5"), "A0:B1:02:D3:E4:F5")
        XCTAssertNil(MACAddress.normalize("(incomplete)"))
        XCTAssertNil(MACAddress.normalize("ff:ff:ff:ff:ff:ff"))
        XCTAssertTrue(MACAddress.isPrivate("DA:11:22:33:44:55"))
        XCTAssertEqual(MACAddress.vendor("B8:27:EB:00:00:01"), "Raspberry Pi Foundation")
        XCTAssertEqual(MACAddress.vendor("F0:B3:EC:00:00:01"), "Apple")
        XCTAssertNil(MACAddress.vendor("DA:11:22:33:44:55"))
    }

    func testNeighbors() {
        let n = RemoteSystem.parseNeighbors("""
        ? (192.168.1.1) at a0:b1:2:d3:e4:f5 on en0 ifscope [ethernet]
        ? (192.168.1.9) at (incomplete) on en0 ifscope [ethernet]
        192.168.1.20 dev eth0 lladdr dc:a6:32:01:02:03 REACHABLE
        """)
        XCTAssertEqual(n, ["192.168.1.1": "A0:B1:02:D3:E4:F5", "192.168.1.20": "DC:A6:32:01:02:03"])
    }

    func testGuesses() {
        var mac = LANDevice(ip: "192.168.1.5")
        mac.models = ["Mac14,2"]
        XCTAssertEqual(mac.guess.kind, .mac)
        var phone = LANDevice(ip: "192.168.1.6")
        phone.openPorts = [62078]
        XCTAssertEqual(phone.guess.kind, .iPhone)
        var printer = LANDevice(ip: "192.168.1.7")
        printer.services = ["_ipp._tcp"]
        XCTAssertEqual(printer.guess.kind, .printer)
        var pi = LANDevice(ip: "192.168.1.8")
        pi.mac = "B8:27:EB:00:00:01"
        XCTAssertEqual(pi.guess.kind, .linux)
        var router = LANDevice(ip: "192.168.1.1")
        router.isGateway = true
        XCTAssertEqual(router.guess.kind, .router)
    }

    func testSubnet() {
        let hosts = IPv4.hosts(address: "192.168.1.37", netmask: "255.255.255.0")
        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(IPv4.format(hosts.first!), "192.168.1.1")
        let wide = IPv4.hosts(address: "192.168.5.9", netmask: "255.255.0.0")
        XCTAssertEqual(wide.count, 1022)
        XCTAssertEqual(IPv4.format(wide[0]), "192.168.5.0")
        XCTAssertEqual(IPv4.format(wide[256]), "192.168.4.1")
    }

    func testNetbiosParse() {
        let query = Probes.netbiosQuery()
        XCTAssertEqual(query.count, 50)
        var reply = Array(query.prefix(12)) + [0x20] + [UInt8](repeating: 0x41, count: 32) + [0, 0, 0x21, 0, 1, 0, 0, 0, 0, 0, 0]
        let name = Array("WINBOX         ".utf8)
        reply += [2] + name + [0x00, 0x04, 0x00] + Array("WORKGROUP      ".utf8) + [0x00, 0x84, 0x00]
        reply += [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]
        let parsed = Probes.parseNetbios(reply)
        XCTAssertEqual(parsed?.name, "WINBOX")
        XCTAssertEqual(parsed?.mac, "00:11:22:33:44:55")
    }

    func testProbesOnLoopback() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = Probes.sockaddrIn(0x7F00_0001, port: 0)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(fd, 4)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: bound.sin_port)
        defer { close(fd) }

        let states = Probes.connect([(0x7F00_0001, port), (0x7F00_0001, 1)], timeout: 1)
        XCTAssertEqual(states, [.open, .closed])
        XCTAssertNotNil(Probes.ping([0x7F00_0001], timeout: 1)[0x7F00_0001])
        XCTAssertEqual(Probes.resolveIPv4("localhost"), 0x7F00_0001)
    }
}

/// `SECUREVNC_LAN=1 swift test --filter LiveLANTests`: scans this Mac's Wi-Fi subnet and prints it.
final class LiveLANTests: XCTestCase {
    func testScan() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SECUREVNC_LAN"] == "1")
        let wifi = try XCTUnwrap(DeviceStats.wifiIPv4())
        let last = Box()
        await LANScanner.scan(address: wifi.address, netmask: wifi.netmask) { devices, _ in last.set(devices) }
        for d in last.get() {
            let g = d.guess
            print("LAN", d.ip, g.kind.label, "(\(g.reason))", d.names, d.mac ?? "-", d.vendor ?? "-", d.openPorts.sorted(), d.models, d.banners)
        }
        XCTAssertGreaterThan(last.get().count, 1)
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [LANDevice] = []
    func set(_ d: [LANDevice]) { lock.withLock { devices = d } }
    func get() -> [LANDevice] { lock.withLock { devices } }
}
