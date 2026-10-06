import Foundation
import zlib

enum ZRLEError: Error { case inflate(Int32), truncated, badSubencoding(UInt8) }

/// One zlib stream for the whole connection, as ZRLE requires.
final class Inflater {
    private var stream = z_stream()
    private var ready = false

    deinit { if ready { inflateEnd(&stream) } }

    func inflate(_ input: [UInt8], sizeHint: Int) throws -> [UInt8] {
        if !ready {
            let r = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard r == Z_OK else { throw ZRLEError.inflate(r) }
            ready = true
        }
        var output = [UInt8](repeating: 0, count: max(sizeHint, 4096))
        var produced = 0
        try input.withUnsafeBufferPointer { inBuf in
            stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
            stream.avail_in = UInt32(inBuf.count)
            while true {
                if produced == output.count { output += [UInt8](repeating: 0, count: output.count) }
                let r: Int32 = output.withUnsafeMutableBufferPointer { ob in
                    stream.next_out = ob.baseAddress! + produced
                    stream.avail_out = UInt32(ob.count - produced)
                    let r = zlib.inflate(&stream, Z_SYNC_FLUSH)
                    produced = ob.count - Int(stream.avail_out)
                    return r
                }
                if r == Z_BUF_ERROR { break }
                guard r == Z_OK || r == Z_STREAM_END else { throw ZRLEError.inflate(r) }
                if stream.avail_in == 0 && stream.avail_out > 0 { break }
            }
        }
        return Array(output[0..<produced])
    }
}

/// Decodes inflated ZRLE data into the framebuffer. Assumes 3-byte CPIXELs (32bpp, depth 24, little-endian).
enum ZRLE {
    static func decode(_ d: [UInt8], x: Int, y: Int, w: Int, h: Int, into fb: Framebuffer) throws {
        var p = 0
        func byte() throws -> UInt8 {
            guard p < d.count else { throw ZRLEError.truncated }
            defer { p += 1 }
            return d[p]
        }
        func cpixel() throws -> UInt32 {
            guard p + 3 <= d.count else { throw ZRLEError.truncated }
            defer { p += 3 }
            return UInt32(d[p]) | UInt32(d[p + 1]) << 8 | UInt32(d[p + 2]) << 16
        }
        func runLength() throws -> Int {
            var n = 1
            while true {
                let b = try byte()
                n += Int(b)
                if b != 255 { return n }
            }
        }

        let stride = fb.width
        try fb.lock.withLock {
            try fb.pixels.withUnsafeMutableBufferPointer { px in
                for ty in Swift.stride(from: y, to: y + h, by: 64) {
                    let th = min(64, y + h - ty)
                    for tx in Swift.stride(from: x, to: x + w, by: 64) {
                        let tw = min(64, x + w - tx)
                        let count = tw * th
                        @inline(__always) func put(_ i: Int, _ c: UInt32) {
                            px[(ty + i / tw) * stride + tx + i % tw] = c
                        }
                        let sub = try byte()
                        switch sub {
                        case 0:
                            for i in 0..<count { put(i, try cpixel()) }
                        case 1:
                            let c = try cpixel()
                            for row in 0..<th {
                                let base = (ty + row) * stride + tx
                                for col in 0..<tw { px[base + col] = c }
                            }
                        case 2...16:
                            let palette = try (0..<Int(sub)).map { _ in try cpixel() }
                            let bits = sub == 2 ? 1 : sub <= 4 ? 2 : 4
                            let mask = UInt8((1 << bits) - 1)
                            for row in 0..<th {
                                var shift = 8
                                var cur: UInt8 = 0
                                for col in 0..<tw {
                                    if shift == 8 { cur = try byte(); shift = 0 }
                                    shift += bits
                                    let idx = Int((cur >> UInt8(8 - shift)) & mask)
                                    guard idx < palette.count else { throw ZRLEError.truncated }
                                    px[(ty + row) * stride + tx + col] = palette[idx]
                                }
                            }
                        case 128:
                            var i = 0
                            while i < count {
                                let c = try cpixel()
                                let n = try runLength()
                                guard i + n <= count else { throw ZRLEError.truncated }
                                for k in i..<i + n { put(k, c) }
                                i += n
                            }
                        case 130...255:
                            let palette = try (0..<Int(sub - 128)).map { _ in try cpixel() }
                            var i = 0
                            while i < count {
                                let b = try byte()
                                let idx = Int(b & 0x7F)
                                guard idx < palette.count else { throw ZRLEError.truncated }
                                let n = b & 0x80 != 0 ? try runLength() : 1
                                guard i + n <= count else { throw ZRLEError.truncated }
                                for k in i..<i + n { put(k, palette[idx]) }
                                i += n
                            }
                        default:
                            throw ZRLEError.badSubencoding(sub)
                        }
                    }
                }
            }
        }
    }
}
