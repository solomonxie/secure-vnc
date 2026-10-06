import CoreGraphics
import Foundation

/// 32-bit pixels laid out as little-endian 0x00RRGGBB, i.e. BGRX in memory — the format we ask the server for.
public final class Framebuffer: @unchecked Sendable {
    public private(set) var width = 0
    public private(set) var height = 0
    var pixels: [UInt32] = []
    let lock = NSLock()

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        .union(.byteOrder32Little)

    public init() {}

    func resize(width: Int, height: Int) {
        lock.withLock {
            self.width = width
            self.height = height
            pixels = Array(repeating: 0, count: width * height)
        }
    }

    func contains(x: Int, y: Int, w: Int, h: Int) -> Bool {
        x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= width && y + h <= height
    }

    public func pixel(x: Int, y: Int) -> UInt32 { lock.withLock { pixels[y * width + x] } }

    public func makeImage() -> CGImage? {
        lock.withLock {
            guard width > 0, height > 0 else { return nil }
            let data = pixels.withUnsafeBytes { Data($0) }
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo,
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }
}

public struct CursorShape: @unchecked Sendable {
    public let image: CGImage?
    public let hotspot: CGPoint
    public let size: CGSize
}
