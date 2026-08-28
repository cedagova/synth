import Compression
import Foundation

/// Streaming decompression over Apple's `Compression` framework.
///
/// Used by both archive readers, because a `.tar.xz` and a `.zip` differ only
/// in their container: underneath, one is an xz stream and the other is a run
/// of raw DEFLATE members, and `compression_stream` decodes both.
///
/// Streaming rather than `compression_decode_buffer` is not a refinement: the
/// piano archive is 412 MB compressed and roughly 1.5 GB expanded, and holding
/// either end of that in memory to install an instrument is not something a
/// desktop app should do.
struct StreamingInflate {
    enum Failure: Error, Equatable {
        case couldNotStart
        case corruptStream(bytesProduced: Int64)
        case truncatedStream(bytesProduced: Int64)
    }

    /// Which stream format the bytes are in.
    enum Format {
        /// The `.xz` container, as `xz(1)` writes it — including the
        /// multi-block form `xz -T0` produces.
        case xz

        /// Raw DEFLATE with no zlib or gzip wrapper, which is what a ZIP
        /// member's compressed bytes are.
        case rawDeflate

        var algorithm: compression_algorithm {
            switch self {
            case .xz: return COMPRESSION_LZMA
            case .rawDeflate: return COMPRESSION_ZLIB
            }
        }
    }

    private static let outputCapacity = 256 * 1024

    /// Decodes `read`'s output until the stream ends, handing plain bytes to
    /// `write`.
    ///
    /// - Parameters:
    ///   - format: which container the compressed bytes are in.
    ///   - read: returns the next compressed chunk, or an empty `Data` at end
    ///     of input.
    ///   - write: receives decoded bytes in order. Its throws propagate, which
    ///     is how a disk-full during extraction stops the whole unpack.
    /// - Returns: how many decoded bytes were produced.
    @discardableResult
    static func decode(
        format: Format,
        read: () throws -> Data,
        write: (Data) throws -> Void
    ) throws -> Int64 {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }

        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, format.algorithm)
            == COMPRESSION_STATUS_OK
        else { throw Failure.couldNotStart }
        defer { compression_stream_destroy(stream) }

        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
        defer { output.deallocate() }
        stream.pointee.dst_ptr = output
        stream.pointee.dst_size = outputCapacity
        stream.pointee.src_size = 0

        var produced: Int64 = 0
        var pending: [UInt8] = []
        var reachedEndOfInput = false

        while true {
            if stream.pointee.src_size == 0 && !reachedEndOfInput {
                let chunk = try read()
                if chunk.isEmpty {
                    reachedEndOfInput = true
                    pending = []
                } else {
                    pending = [UInt8](chunk)
                }
            }

            let status: compression_status = pending.withUnsafeBufferPointer { buffer in
                if stream.pointee.src_size == 0, let base = buffer.baseAddress, !buffer.isEmpty {
                    stream.pointee.src_ptr = base
                    stream.pointee.src_size = buffer.count
                }
                let flags = reachedEndOfInput ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                return compression_stream_process(stream, flags)
            }

            let decoded = outputCapacity - stream.pointee.dst_size
            if decoded > 0 {
                try write(Data(bytes: output, count: decoded))
                produced += Int64(decoded)
                stream.pointee.dst_ptr = output
                stream.pointee.dst_size = outputCapacity
            }

            switch status {
            case COMPRESSION_STATUS_END:
                return produced
            case COMPRESSION_STATUS_ERROR:
                throw Failure.corruptStream(bytesProduced: produced)
            default:
                break
            }

            // The decoder consumed everything it was given and asked for more,
            // but the input is finished and it never said END. The stream stops
            // mid-symbol: truncated, not merely empty.
            if reachedEndOfInput, stream.pointee.src_size == 0, decoded == 0 {
                throw Failure.truncatedStream(bytesProduced: produced)
            }

            if stream.pointee.src_size == 0 { pending = [] }
        }
    }
}
