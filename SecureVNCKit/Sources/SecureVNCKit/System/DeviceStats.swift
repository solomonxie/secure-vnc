import Darwin
import Foundation

/// This device's own stats, through the Mach and BSD calls iOS still allows apps.
public enum DeviceStats {
    public static func sample() -> SystemStats {
        var s = SystemStats()
        let info = ProcessInfo.processInfo
        s.hostname = info.hostName
        s.os = info.operatingSystemVersionString
        s.model = sysctlString("hw.machine") ?? ""
        s.kernel = sysctlString("kern.osrelease").map { "Darwin \($0)" } ?? ""
        s.cpuCount = info.activeProcessorCount
        s.bootTime = Date().addingTimeInterval(-info.systemUptime)
        s.cpuTicks = cpuTicks()
        s.memoryTotal = info.physicalMemory
        s.memoryUsed = memoryUsed()
        if let disk = disk() { s.disks = [disk] }
        s.interfaces = interfaces()
        return s
    }

    public static var appMemory: UInt64? {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? vm.phys_footprint : nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var cpus: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(cpus) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    private static func memoryUsed() -> UInt64 {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(vm.internal_page_count) - min(UInt64(vm.internal_page_count), UInt64(vm.purgeable_count))
        return (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
    }

    private static func disk() -> SystemStats.Disk? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity else { return nil }
        let available = v.volumeAvailableCapacityForImportantUsage.map(UInt64.init) ?? 0
        return SystemStats.Disk(mount: "/", total: UInt64(total), available: available)
    }

    /// Addresses and byte counters (`if_data`, 32-bit) per interface.
    static func interfaces() -> [SystemStats.Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var order: [String] = []
        var map: [String: SystemStats.Interface] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let e = entry.pointee
            guard let addr = e.ifa_addr else { continue }
            let name = String(cString: e.ifa_name)
            if map[name] == nil {
                order.append(name)
                map[name] = SystemStats.Interface(name: name, counterWidth: 1 << 32)
            }
            if e.ifa_flags & UInt32(IFF_UP) != 0, e.ifa_flags & UInt32(IFF_RUNNING) != 0 { map[name]?.up = true }
            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                if let data = e.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    map[name]?.rxBytes = UInt64(data.pointee.ifi_ibytes)
                    map[name]?.txBytes = UInt64(data.pointee.ifi_obytes)
                }
            case AF_INET, AF_INET6:
                if let ip = numericHost(addr), !ip.lowercased().hasPrefix("fe80"), ip != "::1" { map[name]?.addresses.append(ip) }
            default: break
            }
        }
        return order.compactMap { map[$0] }
    }

    /// This device's IPv4 address and netmask on Wi-Fi (`en0`).
    public static func wifiIPv4() -> (address: String, netmask: String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let e = entry.pointee
            guard String(cString: e.ifa_name) == "en0", let addr = e.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let ip = numericHost(addr), let mask = e.ifa_netmask.flatMap(numericHost) else { continue }
            return (ip, mask)
        }
        return nil
    }

    static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return String(cString: name).replacingOccurrences(of: "%.*", with: "", options: .regularExpression)
    }

    /// `en0` → Wi-Fi and so on, for this device's interface names.
    public static func label(_ interface: String) -> String {
        switch interface {
        case "en0": "Wi-Fi"
        case let n where n.hasPrefix("pdp_ip"): "Cellular"
        case let n where n.hasPrefix("utun") || n.hasPrefix("ipsec"): "VPN"
        case let n where n.hasPrefix("bridge"): "Hotspot"
        case let n where n.hasPrefix("en"): "Ethernet"
        default: interface
        }
    }
}
