import Foundation
import Network

public struct DiscoveredService: Sendable, Hashable {
    public var name: String
    public var type: String
    /// nil for records with no port to connect to (`_device-info._tcp`).
    public var ip: String?
    public var txt: [String: String]

    /// Model hints in TXT records: `model=Mac14,2`, `am=AudioAccessory5,1`, `md=Chromecast`, `ty=HP LaserJet`.
    public var model: String? {
        for key in ["model", "am", "md", "ty", "usb_MDL", "product"] {
            if let v = txt[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
        }
        return nil
    }
}

/// Bonjour browsing. Each type must also be listed in the app's `NSBonjourServices`.
public enum ServiceDiscovery {
    public static let types = [
        "_ssh._tcp", "_sftp-ssh._tcp", "_rfb._tcp", "_smb._tcp", "_afpovertcp._tcp", "_adisk._tcp", "_nfs._tcp",
        "_http._tcp", "_https._tcp", "_workstation._tcp", "_device-info._tcp", "_companion-link._tcp",
        "_apple-mobdev2._tcp", "_airplay._tcp", "_raop._tcp", "_mediaremotetv._tcp", "_homekit._tcp", "_hap._tcp",
        "_matter._tcp", "_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp", "_scanner._tcp",
        "_uscan._tcp", "_googlecast._tcp", "_androidtvremote2._tcp", "_amzn-wplay._tcp", "_spotify-connect._tcp",
        "_sonos._tcp", "_hue._tcp", "_home-assistant._tcp", "_esphomelib._tcp", "_daap._tcp",
    ]

    /// Browses every type for `seconds`, reporting each service once with its IPv4 address when it resolves.
    public static func browse(for seconds: TimeInterval, onFound: @escaping @Sendable (DiscoveredService) -> Void) async {
        let queue = DispatchQueue(label: "service-discovery")
        let state = BrowseState()
        let browsers = types.map { type in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint, state.claim(name + type) else { continue }
                    var txt: [String: String] = [:]
                    if case .bonjour(let record) = result.metadata { txt = record.dictionary }
                    let found = DiscoveredService(name: name, type: type, ip: nil, txt: txt)
                    if type == "_device-info._tcp" {
                        onFound(found)
                    } else {
                        resolve(result.endpoint, queue: queue, state: state) { ip in
                            var found = found
                            found.ip = ip
                            onFound(found)
                        }
                    }
                }
            }
            browser.start(queue: queue)
            return browser
        }
        try? await Task.sleep(for: .seconds(seconds))
        browsers.forEach { $0.cancel() }
        state.cancelAll()
    }

    /// Connects just long enough to learn the address behind a service.
    private static func resolve(_ endpoint: NWEndpoint, queue: DispatchQueue, state: BrowseState,
                                done: @escaping @Sendable (String?) -> Void) {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: params)
        let once = BrowseState()
        let finish: @Sendable (String?) -> Void = { ip in
            guard once.claim("done") else { return }
            connection.cancel()
            done(ip)
        }
        connection.stateUpdateHandler = { s in
            switch s {
            case .ready:
                if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint, case .ipv4(let v4) = host {
                    finish("\(v4)".replacingOccurrences(of: "%.*", with: "", options: .regularExpression))
                } else {
                    finish(nil)
                }
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        state.track(connection)
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { finish(nil) }
    }
}

private final class BrowseState: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<String>()
    private var connections: [NWConnection] = []

    func claim(_ key: String) -> Bool { lock.withLock { seen.insert(key).inserted } }
    func track(_ c: NWConnection) { lock.withLock { connections.append(c) } }
    func cancelAll() { lock.withLock { connections.forEach { $0.cancel() } } }
}
