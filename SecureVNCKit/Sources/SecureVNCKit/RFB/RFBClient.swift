import CoreGraphics
import Foundation

public enum VNCAuth: Sendable {
    case none
    case password(String)
    /// macOS Screen Sharing account login (security type 30).
    case macOS(username: String, password: String)
}

public enum RFBError: Error, LocalizedError {
    case badVersion(String)
    case refused(String)
    case unsupportedSecurity(offered: [UInt8])
    case authFailed(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .badVersion(let v): "Not a VNC server (\(v))"
        case .refused(let why): "VNC server refused: \(why)"
        case .unsupportedSecurity(let offered):
            "The VNC server wants a login type this host isn't set to use (offered: \(offered.map(String.init).joined(separator: ", ")))"
        case .authFailed(let why): "VNC login rejected" + (why.isEmpty ? "" : ": \(why)")
        case .protocolError(let why): "VNC protocol error: \(why)"
        }
    }
}

public enum MouseButton: UInt8, Sendable {
    case left = 1, middle = 2, right = 4, scrollUp = 8, scrollDown = 16, scrollLeft = 32, scrollRight = 64
}

/// RFB 3.8 client over any ByteTransport. Callbacks fire on the reading task, not the main thread.
public final class RFBClient: @unchecked Sendable {
    public let framebuffer = Framebuffer()
    public private(set) var desktopName = ""
    public var onUpdate: (() -> Void)?
    public var onResize: ((Int, Int) -> Void)?
    public var onCursor: ((CursorShape) -> Void)?
    public var onBell: (() -> Void)?
    public var onClipboard: ((String) -> Void)?

    private let transport: ByteTransport
    private let inflater = Inflater()

    enum Encoding: Int32 {
        case raw = 0, copyRect = 1, zrle = 16, cursor = -239, desktopSize = -223
    }

    public init(transport: ByteTransport) { self.transport = transport }

    // MARK: Handshake

    public func handshake(auth: VNCAuth) async throws {
        let version = String(decoding: try await read(12), as: UTF8.self)
        guard version.hasPrefix("RFB "), let minor = Int(version.dropFirst(8).prefix(3)),
              let major = Int(version.dropFirst(4).prefix(3)), major == 3
        else { throw RFBError.badVersion(version.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let ours = minor >= 8 ? 8 : minor >= 7 ? 7 : 3
        transport.send(Array(String(format: "RFB 003.%03d\n", ours).utf8))

        let type: UInt8
        if ours == 3 {
            let t = try await u32()
            if t == 0 { throw RFBError.refused(try await reason()) }
            type = UInt8(truncatingIfNeeded: t)
        } else {
            let n = Int(try await u8())
            if n == 0 { throw RFBError.refused(try await reason()) }
            let offered = try await read(n)
            guard let pick = Self.choose(auth, offered: offered) else {
                throw RFBError.unsupportedSecurity(offered: offered)
            }
            type = pick
            transport.send([type])
        }

        switch (type, auth) {
        case (1, _):
            if ours < 8 { break }
            try await securityResult()
        case (2, .password(let pw)):
            transport.send(RFBAuth.vncResponse(challenge: try await read(16), password: pw))
            try await securityResult()
        case (30, .macOS(let user, let pw)):
            let generator = try await read(2)
            let keyLength = Int(try await u16())
            let prime = try await read(keyLength)
            let serverKey = try await read(keyLength)
            let response = await Task.detached(priority: .userInitiated) {
                RFBAuth.appleResponse(generator: generator, prime: prime, serverKey: serverKey,
                                      username: user, password: pw)
            }.value
            transport.send(response)
            try await securityResult()
        default:
            throw RFBError.unsupportedSecurity(offered: [type])
        }

        transport.send([1]) // ClientInit: shared session
        let w = Int(try await u16()), h = Int(try await u16())
        _ = try await read(16) // server pixel format; we override it below
        desktopName = String(decoding: try await read(Int(try await u32())), as: UTF8.self)
        framebuffer.resize(width: w, height: h)
        onResize?(w, h)

        sendPixelFormat()
        sendEncodings([.zrle, .copyRect, .raw, .cursor, .desktopSize])
        requestUpdate(incremental: false)
    }

    static func choose(_ auth: VNCAuth, offered: [UInt8]) -> UInt8? {
        let wanted: [UInt8] = switch auth {
        case .none: [1]
        case .password: [2]
        case .macOS: [30]
        }
        return wanted.first(where: offered.contains)
    }

    private func securityResult() async throws {
        guard try await u32() != 0 else { return }
        throw RFBError.authFailed((try? await reason()) ?? "")
    }

    private func reason() async throws -> String {
        String(decoding: try await read(Int(try await u32())), as: UTF8.self)
    }

    // MARK: Message loop

    /// Reads server messages until the connection ends.
    public func run() async throws {
        while true {
            switch try await u8() {
            case 0: try await framebufferUpdate()
            case 1:
                _ = try await read(3)
                let n = Int(try await u16())
                _ = try await read(n * 6)
            case 2: onBell?()
            case 3:
                _ = try await read(3)
                let text = try await read(Int(try await u32()))
                onClipboard?(String(decoding: text, as: UTF8.self))
            case let t: throw RFBError.protocolError("unknown message \(t)")
            }
        }
    }

    private func framebufferUpdate() async throws {
        _ = try await u8()
        let count = Int(try await u16())
        for _ in 0..<count {
            let x = Int(try await u16()), y = Int(try await u16())
            let w = Int(try await u16()), h = Int(try await u16())
            let raw = Int32(bitPattern: try await u32())
            guard let enc = Encoding(rawValue: raw) else {
                throw RFBError.protocolError("unrequested encoding \(raw)")
            }
            if enc.rawValue >= 0, !framebuffer.contains(x: x, y: y, w: w, h: h) {
                throw RFBError.protocolError("rectangle outside screen")
            }
            switch enc {
            case .raw:
                let bytes = try await read(w * h * 4)
                framebuffer.lock.withLock {
                    bytes.withUnsafeBytes { src in
                        let s = src.bindMemory(to: UInt32.self)
                        for row in 0..<h {
                            let dst = (y + row) * framebuffer.width + x
                            for col in 0..<w { framebuffer.pixels[dst + col] = UInt32(littleEndian: s[row * w + col]) }
                        }
                    }
                }
            case .copyRect:
                let sx = Int(try await u16()), sy = Int(try await u16())
                guard framebuffer.contains(x: sx, y: sy, w: w, h: h) else {
                    throw RFBError.protocolError("copy source outside screen")
                }
                framebuffer.lock.withLock {
                    let fw = framebuffer.width
                    let rows = sy < y ? Array((0..<h).reversed()) : Array(0..<h)
                    for row in rows {
                        let src = Array(framebuffer.pixels[(sy + row) * fw + sx..<(sy + row) * fw + sx + w])
                        framebuffer.pixels.replaceSubrange((y + row) * fw + x..<(y + row) * fw + x + w, with: src)
                    }
                }
            case .zrle:
                let length = Int(try await u32())
                let data = try inflater.inflate(try await read(length), sizeHint: w * h * 3 + 1024)
                try ZRLE.decode(data, x: x, y: y, w: w, h: h, into: framebuffer)
            case .cursor:
                let pixels = try await read(w * h * 4)
                let mask = try await read((w + 7) / 8 * h)
                onCursor?(Self.cursor(pixels: pixels, mask: mask, w: w, h: h, hotX: x, hotY: y))
            case .desktopSize:
                framebuffer.resize(width: w, height: h)
                onResize?(w, h)
            }
        }
        onUpdate?()
        requestUpdate(incremental: true)
    }

    static func cursor(pixels: [UInt8], mask: [UInt8], w: Int, h: Int, hotX: Int, hotY: Int) -> CursorShape {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let rowBytes = (w + 7) / 8
        for y in 0..<h {
            for x in 0..<w where mask[y * rowBytes + x / 8] & (0x80 >> UInt8(x % 8)) != 0 {
                let s = (y * w + x) * 4
                rgba[s] = pixels[s + 2]; rgba[s + 1] = pixels[s + 1]; rgba[s + 2] = pixels[s]; rgba[s + 3] = 255
            }
        }
        var image: CGImage?
        if w > 0, h > 0, let provider = CGDataProvider(data: Data(rgba) as CFData) {
            image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: Framebuffer.colorSpace,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return CursorShape(image: image, hotspot: CGPoint(x: hotX, y: hotY), size: CGSize(width: w, height: h))
    }

    // MARK: Client messages

    private func sendPixelFormat() {
        var m: [UInt8] = [0, 0, 0, 0]
        m += [32, 24, 0, 1] // bpp, depth, little-endian, true colour
        m += [0, 255, 0, 255, 0, 255] // max r, g, b
        m += [16, 8, 0, 0, 0, 0] // shifts + padding
        transport.send(m)
    }

    private func sendEncodings(_ list: [Encoding]) {
        var m: [UInt8] = [2, 0] + be16(list.count)
        for e in list { m += be32(UInt32(bitPattern: e.rawValue)) }
        transport.send(m)
    }

    public func requestUpdate(incremental: Bool) {
        transport.send([3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(framebuffer.width) + be16(framebuffer.height))
    }

    public func pointer(x: Int, y: Int, buttons: UInt8) {
        let cx = max(0, min(x, framebuffer.width - 1)), cy = max(0, min(y, framebuffer.height - 1))
        transport.send([5, buttons] + be16(cx) + be16(cy))
    }

    public func key(_ keysym: UInt32, down: Bool) {
        transport.send([4, down ? 1 : 0, 0, 0] + be32(keysym))
    }

    public func clipboard(_ text: String) {
        let bytes = Array(text.utf8)
        transport.send([6, 0, 0, 0] + be32(UInt32(bytes.count)) + bytes)
    }

    public func close() { transport.close() }

    // MARK: Bytes

    private func read(_ n: Int) async throws -> [UInt8] { n == 0 ? [] : try await transport.read(n) }
    private func u8() async throws -> UInt8 { try await read(1)[0] }
    private func u16() async throws -> UInt16 {
        let b = try await read(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }
    private func u32() async throws -> UInt32 {
        let b = try await read(4)
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }
    private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}
