import Foundation

public enum TransportError: Error, LocalizedError {
    case closed

    public var errorDescription: String? { "Connection closed" }
}

/// A reliable, ordered byte pipe. `send` is fire-and-forget and keeps call order.
public protocol ByteTransport: AnyObject {
    func read(_ count: Int) async throws -> [UInt8]
    func send(_ bytes: [UInt8])
    func close()
}

/// Buffers chunks from an async stream so callers can read exact lengths.
final class ChunkReader {
    private var iterator: AsyncThrowingStream<[UInt8], Error>.AsyncIterator
    private var buffer: [UInt8] = []
    private var offset = 0

    init(_ stream: AsyncThrowingStream<[UInt8], Error>) { iterator = stream.makeAsyncIterator() }

    func read(_ count: Int) async throws -> [UInt8] {
        while buffer.count - offset < count {
            guard let chunk = try await iterator.next() else { throw TransportError.closed }
            if offset > 0 && offset > buffer.count / 2 {
                buffer.removeFirst(offset)
                offset = 0
            }
            buffer.append(contentsOf: chunk)
        }
        let out = Array(buffer[offset..<offset + count])
        offset += count
        return out
    }

    func readAvailable() async throws -> [UInt8] {
        if offset < buffer.count {
            defer { buffer = []; offset = 0 }
            return Array(buffer[offset...])
        }
        guard let chunk = try await iterator.next() else { throw TransportError.closed }
        return chunk
    }
}
