import Darwin
import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// Where `prewarmAttack` accumulates the bytes it read.
///
/// It exists so the compiler cannot conclude that the prewarm loop's loads are
/// dead and delete the very page faults the loop is there to take. Nothing ever
/// reads it, and nothing should.
nonisolated(unsafe) private var samplePrewarmSink: UInt8 = 0

/// One WAV file, mapped read-only, described well enough for the render core to
/// interpolate it.
///
/// **Mapped rather than read.** The curated set is 3.2 GB and one instrument
/// alone can be 1.2 GB of it (Salamander's 641 samples), so reading a whole
/// instrument into memory to play a handful of its notes is not an option. A
/// mapping costs address space instead: the kernel pages in what is actually
/// touched, and pages the rest back out under pressure.
///
/// That trade puts one risk on the audio thread — a page that is not resident
/// faults, and a fault is a blocking read. `prewarmAttack()` is the answer:
/// the control thread faults in the beginning of every sample when the
/// instrument is loaded, so a note-on always starts from resident memory and
/// only a long, sustained note can reach a cold page. What that residual costs
/// is measured against the orchestral reference rather than assumed away.
///
/// Nothing here decodes. The render core reads the file's own frames and
/// converts one sample at a time, so a 24-bit VSCO sample is 3 bytes on disk
/// and 3 bytes in memory rather than 4 bytes of float.
final class SampleWaveform: @unchecked Sendable {
    /// Where the file's first audio frame is, inside the mapping.
    let frames: UnsafeRawPointer

    let frameCount: Int64
    let channelCount: Int32

    /// A `SampleFrameFormat`.
    let format: Int32

    let sampleRate: Double

    /// Loop points from the `smpl` chunk, or -1 when the file declares none.
    let fileLoopStart: Int64
    let fileLoopEnd: Int64

    /// Bytes of address space this mapping occupies.
    let mappedByteCount: Int

    private let mappingBase: UnsafeMutableRawPointer

    /// How much of each sample's beginning is faulted in when the instrument
    /// loads.
    ///
    /// 256 kB is about 1.5 seconds of 44.1 kHz stereo 16-bit audio, which
    /// covers the attack and early body of every note in the curated set. It
    /// costs 164 MB across Salamander's 641 samples — page-cache pages the
    /// kernel can reclaim, not an allocation — and it is what turns a note-on
    /// from a possible disk read into a memory read.
    static let attackWarmByteCount = 256 * 1024

    enum LoadFailure: Error, CustomStringConvertible, Equatable {
        case unreadable(path: String, reason: String)
        case notAWaveFile(path: String)
        case unsupportedFormat(path: String, reason: String)

        var description: String {
            switch self {
            case .unreadable(let path, let reason):
                return "Could not read \(path): \(reason)"
            case .notAWaveFile(let path):
                return "\(path) is not a WAV file."
            case .unsupportedFormat(let path, let reason):
                return "\(path) is a WAV file this player cannot read: \(reason)"
            }
        }
    }

    /// Map `url` and read its header.
    ///
    /// Throws rather than returning nil so the reason travels: a missing or
    /// corrupt sample makes its whole instrument unavailable with something the
    /// owner can act on, which is the failure behaviour issue #23 asks for.
    init(contentsOf url: URL) throws {
        let path = url.path(percentEncoded: false)

        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw LoadFailure.unreadable(path: url.lastPathComponent,
                                         reason: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw LoadFailure.unreadable(path: url.lastPathComponent,
                                         reason: String(cString: strerror(errno)))
        }
        let byteCount = Int(status.st_size)
        guard byteCount > 44 else {
            throw LoadFailure.notAWaveFile(path: url.lastPathComponent)
        }

        let mapped = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard let base = mapped, base != UnsafeMutableRawPointer(bitPattern: -1) else {
            throw LoadFailure.unreadable(path: url.lastPathComponent,
                                         reason: "the file could not be mapped into memory.")
        }

        do {
            let header = try SampleWaveform.readHeader(
                base: UnsafeRawPointer(base), byteCount: byteCount, name: url.lastPathComponent
            )
            self.mappingBase = base
            self.mappedByteCount = byteCount
            self.frames = UnsafeRawPointer(base).advanced(by: header.dataOffset)
            self.frameCount = header.frameCount
            self.channelCount = header.channelCount
            self.format = header.format
            self.sampleRate = header.sampleRate
            self.fileLoopStart = header.loopStart
            self.fileLoopEnd = header.loopEnd
        } catch {
            munmap(base, byteCount)
            throw error
        }
    }

    deinit { munmap(mappingBase, mappedByteCount) }

    /// Fault in the beginning of the audio data, on the calling (control)
    /// thread.
    ///
    /// `madvise` asks the kernel to read ahead; the loop that follows is what
    /// guarantees the pages are actually resident when it returns, because
    /// `MADV_WILLNEED` is a hint and a hint is not a proof. Returns the bytes
    /// touched, which is the honest figure for the instrument's resident cost.
    @discardableResult
    func prewarmAttack() -> Int {
        let dataOffset = frames - UnsafeRawPointer(mappingBase)
        let available = mappedByteCount - dataOffset
        let length = min(Self.attackWarmByteCount, max(0, available))
        guard length > 0 else { return 0 }

        madvise(UnsafeMutableRawPointer(mutating: frames), length, MADV_WILLNEED)

        let pageSize = Int(getpagesize())
        var touched = 0
        var offset = 0
        // Accumulated into a value that escapes this function, so the loads
        // cannot be optimised away — which is the entire point of the loop.
        var sink: UInt8 = 0
        while offset < length {
            sink ^= frames.load(fromByteOffset: offset, as: UInt8.self)
            offset += pageSize
            touched += pageSize
        }
        samplePrewarmSink ^= sink
        return min(touched, length)
    }

    /// The C-side description the render core reads.
    var renderData: SampleWaveformData {
        SampleWaveformData(
            frames: frames,
            frameCount: frameCount,
            channelCount: channelCount,
            format: format,
            sampleRate: sampleRate,
            fileLoopStart: fileLoopStart,
            fileLoopEnd: fileLoopEnd
        )
    }
}

// MARK: - Header

extension SampleWaveform {
    private struct Header {
        var dataOffset: Int
        var frameCount: Int64
        var channelCount: Int32
        var format: Int32
        var sampleRate: Double
        var loopStart: Int64
        var loopEnd: Int64
    }

    /// Walk the RIFF chunks for `fmt `, `data` and `smpl`.
    ///
    /// Written as a walk rather than "read the first 44 bytes" because the
    /// installed libraries do not have 44-byte headers: 455 of their files
    /// carry a `junk` chunk, 163 a broadcast-wave `bext`, and 83 an `_PMX`
    /// metadata chunk after the audio. A fixed offset would read metadata as
    /// audio.
    private static func readHeader(
        base: UnsafeRawPointer, byteCount: Int, name: String
    ) throws -> Header {
        func fourCC(at offset: Int) -> UInt32 {
            base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        func word(at offset: Int) -> UInt32 {
            UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
        func half(at offset: Int) -> UInt16 {
            UInt16(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }

        guard fourCC(at: 0) == Self.riff, fourCC(at: 8) == Self.wave else {
            throw LoadFailure.notAWaveFile(path: name)
        }

        var audioFormat: UInt16 = 0
        var channels: UInt16 = 0
        var rate: UInt32 = 0
        var bits: UInt16 = 0
        var dataOffset = -1
        var dataLength = 0
        var loopStart: Int64 = -1
        var loopEnd: Int64 = -1

        var cursor = 12
        while cursor + 8 <= byteCount {
            let identifier = fourCC(at: cursor)
            let size = Int(word(at: cursor + 4))
            let body = cursor + 8
            // A chunk claiming to run past the end of the file is corruption,
            // not a chunk; stop rather than read out of bounds. `data` is the
            // one exception, because a truncated recording is still playable up
            // to where it stops.
            guard body + size <= byteCount || identifier == Self.data else { break }

            if identifier == Self.fmt, size >= 16 {
                audioFormat = half(at: body)
                channels = half(at: body + 2)
                rate = word(at: body + 4)
                bits = half(at: body + 14)
                // WAVE_FORMAT_EXTENSIBLE puts the real format in the SubFormat
                // GUID's first two bytes.
                if audioFormat == 0xFFFE, size >= 40 {
                    audioFormat = half(at: body + 24)
                }
            } else if identifier == Self.data {
                dataOffset = body
                dataLength = min(size, byteCount - body)
            } else if identifier == Self.smpl, size >= 36 {
                let loopCount = Int(word(at: body + 28))
                if loopCount > 0, size >= 36 + 24 {
                    loopStart = Int64(word(at: body + 36 + 8))
                    loopEnd = Int64(word(at: body + 36 + 12))
                }
            }

            cursor = body + size + (size % 2)
        }

        guard dataOffset >= 0, dataLength > 0 else {
            throw LoadFailure.unsupportedFormat(path: name, reason: "it has no audio data chunk.")
        }
        guard channels == 1 || channels == 2 else {
            throw LoadFailure.unsupportedFormat(
                path: name, reason: "it has \(channels) channels; only mono and stereo are read."
            )
        }
        guard rate > 0 else {
            throw LoadFailure.unsupportedFormat(path: name, reason: "it declares no sample rate.")
        }

        let format: Int32
        switch (audioFormat, bits) {
        case (1, 16): format = Int32(SampleFrameFormatPCM16.rawValue)
        case (1, 24): format = Int32(SampleFrameFormatPCM24.rawValue)
        case (1, 32): format = Int32(SampleFrameFormatPCM32.rawValue)
        case (3, 32): format = Int32(SampleFrameFormatFloat32.rawValue)
        case (3, 64): format = Int32(SampleFrameFormatFloat64.rawValue)
        default:
            throw LoadFailure.unsupportedFormat(
                path: name,
                reason: "it is format \(audioFormat) at \(bits) bits, and this player reads "
                    + "16-, 24- and 32-bit PCM and 32- and 64-bit float."
            )
        }

        let bytesPerFrame = Int(channels) * Int(bits) / 8
        guard bytesPerFrame > 0 else {
            throw LoadFailure.unsupportedFormat(path: name, reason: "its frame size is zero.")
        }

        // No alignment requirement is imposed on `dataOffset`. A `data` chunk
        // begins wherever the chunks before it end, and 618 of the curated
        // set's files put a `junk` or `bext` chunk there, so requiring the
        // audio to be aligned to its own sample size would reject perfectly
        // ordinary files. The render core reads frames through fixed-size
        // `__builtin_memcpy` loads instead, which carry no alignment
        // assumption and compile to the same instruction.

        let frames = Int64(dataLength / bytesPerFrame)
        guard frames > 0 else {
            throw LoadFailure.unsupportedFormat(path: name, reason: "it contains no frames.")
        }

        // A loop that runs past the end of the audio is a stale chunk, not a
        // loop; drop it rather than read out of range at playback time.
        if loopEnd >= frames || loopStart < 0 || loopEnd <= loopStart {
            loopStart = -1
            loopEnd = -1
        }

        return Header(
            dataOffset: dataOffset,
            frameCount: frames,
            channelCount: Int32(channels),
            format: format,
            sampleRate: Double(rate),
            loopStart: loopStart,
            loopEnd: loopEnd
        )
    }

    private static let riff: UInt32 = 0x4646_4952 // "RIFF"
    private static let wave: UInt32 = 0x4556_4157 // "WAVE"
    private static let fmt: UInt32 = 0x2074_6d66  // "fmt "
    private static let data: UInt32 = 0x6174_6164 // "data"
    private static let smpl: UInt32 = 0x6c70_6d73 // "smpl"
}
