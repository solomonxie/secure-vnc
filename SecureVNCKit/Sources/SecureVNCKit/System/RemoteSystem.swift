import Foundation

/// Stats, processes and network tools on a macOS or Linux server, as `sh` over exec channels.
public struct RemoteSystem: Sendable {
    let tunnel: SSHTunnel

    public init(tunnel: SSHTunnel) { self.tunnel = tunnel }

    /// Takes about a second on macOS, where `top` measures CPU over one.
    public func stats() async throws -> SystemStats {
        SystemStats.parse(try await run(Self.statsScript))
    }

    static let statsScript = #"""
    sec() { printf '@@%s\n' "$1"; }
    kv() { printf '%s\t%s\n' "$1" "$2"; }
    sec info
    kv host "$(hostname)"
    kv kernel "$(uname -sr)"
    kv now "$(date +%s)"
    if [ "$(uname -s)" = Darwin ]; then
      kv os "$(sw_vers -productName) $(sw_vers -productVersion)"
      kv model "$(sysctl -n hw.model)"
      kv cpuname "$(sysctl -n machdep.cpu.brand_string)"
      kv cpus "$(sysctl -n hw.ncpu)"
      kv boot "$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/')"
      kv load "$(sysctl -n vm.loadavg | tr -d '{}' | sed 's/^ *//')"
      kv memtotal "$(sysctl -n hw.memsize)"
      kv gateway "$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
      kv cpu "$(top -l 2 -n 0 -s 1 | awk '/^CPU usage/{l=$0} END{print l}')"
      sec vm; vm_stat
      sec swap; sysctl -n vm.swapusage
      sec battery; pmset -g batt 2>/dev/null
      sec addr
      ifconfig | awk '/^[a-z0-9]+:/{i=$1; sub(":$","",i)} $1=="ether"{print i"\tether\t"$2} $1=="inet"{print i"\tinet\t"$2} $1=="inet6"{a=$2; sub("%.*","",a); print i"\tinet6\t"a} /status: active/{print i"\tup\t1"}'
      sec net; netstat -ibn
    else
      kv os "$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")"
      kv model "$(cat /proc/device-tree/model /sys/devices/virtual/dmi/id/product_name 2>/dev/null | tr -d '\0' | head -n1)"
      kv cpuname "$(awk -F': *' '/^model name|^Model|^Hardware/{print $2; exit}' /proc/cpuinfo)"
      kv cpus "$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)"
      kv uptime "$(cut -d' ' -f1 /proc/uptime)"
      kv load "$(cut -d' ' -f1-3 /proc/loadavg)"
      kv gateway "$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
      kv cputicks "$(head -n1 /proc/stat)"
      sec meminfo; cat /proc/meminfo
      sec battery
      for b in /sys/class/power_supply/BAT*; do [ -r "$b/capacity" ] && printf '%s%%; %s\n' "$(cat "$b/capacity")" "$(cat "$b/status")"; done
      sec addr
      for d in /sys/class/net/*; do
        n=${d##*/}; printf '%s\tether\t%s\n' "$n" "$(cat "$d/address" 2>/dev/null)"
        [ "$(cat "$d/operstate" 2>/dev/null)" = up ] && printf '%s\tup\t1\n' "$n"
      done
      ip -o addr 2>/dev/null | awk '{a=$4; sub("/.*","",a); print $2"\t"$3"\t"a}'
      sec netdev; cat /proc/net/dev
    fi
    sec df; df -kP 2>/dev/null
    """#

    public func processes() async throws -> [RemoteProcess] {
        RemoteProcess.parse(try await run(#"""
        if [ "$(uname -s)" = Darwin ]; then ps -Aco pid=,pcpu=,pmem=,rss=,user=,comm=
        else ps -eo pid=,pcpu=,pmem=,rss=,user=,comm=; fi
        """#))
    }

    public func kill(_ pid: Int, force: Bool) async throws {
        try await run(#"kill -"$1" "$2""#, [force ? "KILL" : "TERM", String(pid)])
    }

    private static let awakeFile = #"/tmp/securevnc-awake-$(id -u).pid"#

    /// nil when the server has no way to hold off sleep.
    public func keepingAwake() async throws -> Bool? {
        let out = try await run(#"""
        f=\#(Self.awakeFile)
        command -v caffeinate >/dev/null || command -v systemd-inhibit >/dev/null || { echo none; exit 0; }
        [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null && echo on || echo off
        """#)
        return switch out.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "on": true
        case "off": false
        default: nil
        }
    }

    /// Holds off idle and system sleep (`caffeinate -ims`, or `systemd-inhibit`) until turned off;
    /// survives disconnecting. A Mac with its lid closed and no display still sleeps.
    public func keepAwake(_ on: Bool) async throws {
        try await run(on ? #"""
        f=\#(Self.awakeFile)
        [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null && exit 0
        if command -v caffeinate >/dev/null; then
          nohup caffeinate -ims >/dev/null 2>&1 </dev/null &
        else
          nohup systemd-inhibit --what=idle:sleep --who="Secure VNC" --why="Kept awake from iPhone" sleep 2147483647 >/dev/null 2>&1 </dev/null &
        fi
        echo $! > "$f"
        sleep 1
        kill -0 "$(cat "$f")" 2>/dev/null || { rm -f "$f"; echo "Couldn't hold off sleep (not allowed for this user?)" >&2; exit 1; }
        """# : #"""
        f=\#(Self.awakeFile)
        [ -f "$f" ] && { pkill -P "$(cat "$f")" 2>/dev/null; kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; }
        exit 0
        """#)
    }

    public func publicIP() async throws -> PublicIP {
        let out = try await tunnel.exec(RemoteFiles.command(#"""
        curl -fsS -m 8 "$1" 2>/dev/null || wget -qO- -T 8 "$1"
        """#, [PublicIP.url.absoluteString]))
        guard out.status == 0 else { throw RemoteFileError.failed("Couldn't reach ipinfo.io from the server (needs curl or wget).") }
        return try PublicIP.decode(out.output)
    }

    /// Runs a network tool there; returns its output, errors included.
    public func tool(_ tool: NetTool, target: String, port: Int? = nil) async throws -> String {
        let script: String = switch tool {
        case .ping: #"ping -c 4 "$1" 2>&1"#
        case .traceroute: #"""
            if command -v traceroute >/dev/null; then traceroute -n -w 1 -q 1 -m 20 "$1" 2>&1
            elif command -v tracepath >/dev/null; then tracepath -n -m 20 "$1" 2>&1
            else echo "No traceroute or tracepath on the server."; fi
            """#
        case .dns: #"""
            if command -v dig >/dev/null; then
              case "$1" in *[!0-9.:]*) dig +noall +answer "$1" A "$1" AAAA ;; *) dig +noall +answer -x "$1" ;; esac
            elif command -v host >/dev/null; then host "$1"
            else nslookup "$1"; fi 2>&1
            """#
        case .port: #"""
            if command -v nc >/dev/null; then
              nc -z -w 3 "$1" "$2" 2>/dev/null && echo "$1:$2 open" || echo "$1:$2 closed or filtered"
            else
              (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null && echo "$1:$2 open" || echo "$1:$2 closed or filtered"
            fi
            """#
        }
        let result = try await tunnel.exec(RemoteFiles.command(script, [target, String(port ?? 0)]))
        let text = result.text + (result.errorText.isEmpty ? "" : "\n" + result.errorText)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pings `addresses` from the server, then reads its ARP table: IP → MAC. MAC addresses can't be
    /// read on iOS, so this is where devices get a manufacturer. Recent macOS may hide the table.
    public func neighbors(_ addresses: [String]) async throws -> [String: String] {
        let out = try await run(#"""
        n=0
        for ip in "$@"; do
          if [ "$(uname -s)" = Darwin ]; then ping -c 1 -t 1 "$ip"; else ping -c 1 -W 1 "$ip"; fi >/dev/null 2>&1 &
          n=$((n + 1)); [ $((n % 128)) -eq 0 ] && wait
        done
        wait
        arp -an 2>/dev/null; ip neigh 2>/dev/null
        exit 0
        """#, addresses)
        return Self.parseNeighbors(out)
    }

    static func parseNeighbors(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let s = String(line)
            var ip: String?
            var mac: String?
            if let r = s.range(of: #"\(([0-9.]+)\) at ([0-9a-fA-F:]+)"#, options: .regularExpression) {
                let m = s[r].split(separator: " ")
                ip = m.first.map { String($0.dropFirst().dropLast()) }
                mac = m.last.map(String.init)
            } else if s.contains(" lladdr ") {
                let f = s.split(separator: " ")
                ip = f.first.map(String.init)
                mac = f.firstIndex(of: "lladdr").flatMap { $0 + 1 < f.count ? String(f[$0 + 1]) : nil }
            }
            guard let ip, let mac = mac.flatMap(MACAddress.normalize) else { continue }
            out[ip] = mac
        }
        return out
    }

    @discardableResult
    private func run(_ script: String, _ args: [String] = []) async throws -> String {
        let result = try await tunnel.exec(RemoteFiles.command(script, args))
        guard result.status == 0 else {
            throw RemoteFileError.failed(result.errorText.isEmpty ? "Command failed (\(result.status))." : result.errorText)
        }
        return result.text
    }
}

public enum NetTool: String, CaseIterable, Sendable {
    case ping, traceroute, dns, port

    public var label: String {
        switch self {
        case .ping: "Ping"
        case .traceroute: "Traceroute"
        case .dns: "DNS"
        case .port: "Port"
        }
    }
}
