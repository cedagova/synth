import Foundation

/// Writes interleaved PCM into a WAV or AIFF container, one block at a time.
///
/// **Written by hand rather than through `AVAudioFile`, for one reason: the
/// header has to be complete before a single sample is written.** The export is
/// streamed — the render never exists in memory all at once — and it publishes
/// itself with one `rename(2)`, so there is no moment at which the writer may
/// seek back to patch a length field. The exact frame count is known before the
/// render starts (`RenderProgram.totalFrames`), so the sizes are computed up
/// front and the file is append-only from there. Anything that produces fewer
/// frames than promised is a failed export, not a file with a wrong header.
///
/// Both formats here are plain uncompressed PCM, which is the whole point:
/// REQ-026's "equal to live playback" is a claim about samples, and a codec
/// would make it a claim about a codec instead.
///
/// The only difference between the two is byte order and the chunk grammar.
/// WAV is RIFF: little-endian, sizes as `UInt32`, a `fmt ` chunk and a `data`
/// chunk. AIFF is IFF: big-endian, an 80-bit IEEE 754 extended sample rate, a
/// `COMM` chunk and an `SSND` chunk with two offset words before the samples.
public struct AudioFileWriter {
    public let settings: AudioExportSettings
    public let frameCount: Int64

    public init(settings: AudioExportSettings, frameCount: Int64) {
        self.settings = settings
        self.frameCount = max(0, frameCount)
    }

    /// Total size of the finished file, header included.
    public var totalByteCount: Int64 {
        Int64(header().count) + settings.payloadByteCount(frameCount: frameCount)
    }

    // MARK: Header

    /// The complete leading bytes of the file, up to the first sample.
    public func header() -> Data {
        switch settings.format {
        case .wav: return waveHeader()
        case .aiff: return aiffHeader()
        }
    }

    private func waveHeader() -> Data {
        let channels = settings.channelCount
        let bits = settings.bitDepth.rawValue
        let rate = settings.sampleRate.rawValue
        let blockAlign = settings.bytesPerFrame
        let payload = settings.payloadByteCount(frameCount: frameCount)

        var fmt = Data()
        fmt.appendLittle(UInt16(1))                       // WAVE_FORMAT_PCM
        fmt.appendLittle(UInt16(channels))
        fmt.appendLittle(UInt32(rate))
        fmt.appendLittle(UInt32(rate * blockAlign))       // average bytes per second
        fmt.appendLittle(UInt16(blockAlign))
        fmt.appendLittle(UInt16(bits))

        var body = Data("WAVE".utf8)
        body.append(Data("fmt ".utf8))
        body.appendLittle(UInt32(fmt.count))
        body.append(fmt)
        body.append(Data("data".utf8))
        body.appendLittle(UInt32(clampToUInt32(payload)))

        var file = Data("RIFF".utf8)
        // RIFF size counts everything after this field: "WAVE", both chunk
        // headers, the fmt payload, and the samples.
        file.appendLittle(UInt32(clampToUInt32(Int64(body.count) + payload)))
        file.append(body)
        return file
    }

    private func aiffHeader() -> Data {
        let channels = settings.channelCount
        let bits = settings.bitDepth.rawValue
        let payload = settings.payloadByteCount(frameCount: frameCount)

        var comm = Data()
        comm.appendBig(UInt16(channels))
        comm.appendBig(UInt32(clampToUInt32(frameCount)))  // numSampleFrames
        comm.appendBig(UInt16(bits))
        comm.append(Self.extended80(settings.sampleRate.hertz))

        // SSND carries two words before the audio: the offset of the first
        // sample inside the chunk and the block-alignment hint. Both zero, which
        // is what every writer that is not aligning to a hardware block emits.
        let ssndPayload = Int64(8) + payload

        var body = Data("AIFF".utf8)
        body.append(Data("COMM".utf8))
        body.appendBig(UInt32(comm.count))
        body.append(comm)
        body.append(Data("SSND".utf8))
        body.appendBig(UInt32(clampToUInt32(ssndPayload)))
        body.appendBig(UInt32(0))                          // offset
        body.appendBig(UInt32(0))                          // blockSize

        var file = Data("FORM".utf8)
        file.appendBig(UInt32(clampToUInt32(Int64(body.count) + payload)))
        file.append(body)
        return file
    }

    /// A `Double` as the 80-bit IEEE 754 extended float AIFF stores its sample
    /// rate in — the one piece of the format with no modern equivalent.
    ///
    /// Sign bit, a 15-bit exponent biased by 16383, and a 64-bit significand
    /// whose leading one is *explicit* (unlike IEEE 754 binary32/binary64).
    static func extended80(_ value: Double) -> Data {
        var bytes = [UInt8](repeating: 0, count: 10)
        guard value > 0, value.isFinite else { return Data(bytes) }

        let exponent = value.exponent                       // value = significand × 2^exponent
        let biased = Int(exponent) + 16_383
        bytes[0] = UInt8((biased >> 8) & 0x7F)
        bytes[1] = UInt8(biased & 0xFF)

        // `significand` is in [1, 2); scaling by 2^63 puts its leading one in
        // bit 63, which is exactly where the explicit-integer-bit format wants
        // it. Written as the hexadecimal float literal `0x1p63` rather than
        // `1 << 63`, which is `Int64.min` and would make every AIFF header a
        // trap at run time.
        let scaled = (value.significand * 0x1p63).rounded()
        let mantissa = scaled >= 0x1p64 ? UInt64.max : UInt64(max(0, scaled))
        for index in 0..<8 {
            bytes[2 + index] = UInt8((mantissa >> (56 - 8 * index)) & 0xFF)
        }
        return Data(bytes)
    }

    private func clampToUInt32(_ value: Int64) -> UInt32 {
        UInt32(min(max(0, value), Int64(UInt32.max)))
    }

    // MARK: Samples

    /// One block of the render as the interleaved bytes the container wants.
    ///
    /// **Rounding, never dithering.** Dither would need a random source, and a
    /// random source would break the one property this whole leaf exists to
    /// prove: exporting the same configuration twice must produce the same
    /// bytes. `.toNearestOrAwayFromZero` is deterministic and is what every
    /// value below the least significant bit rounds by, on every machine.
    ///
    /// Clamping is asymmetric on purpose. A 16-bit sample runs from -32768 to
    /// +32767, so the positive full-scale multiplier is the smaller magnitude;
    /// using 32768 for both would wrap the loudest positive peak to silence.
    public func encode(left: ArraySlice<Float>, right: ArraySlice<Float>) -> Data {
        let frames = min(left.count, right.count)
        var data = Data(capacity: frames * settings.bytesPerFrame)
        var leftIndex = left.startIndex
        var rightIndex = right.startIndex

        for _ in 0..<frames {
            appendSample(left[leftIndex], to: &data)
            appendSample(right[rightIndex], to: &data)
            leftIndex = left.index(after: leftIndex)
            rightIndex = right.index(after: rightIndex)
        }
        return data
    }

    private func appendSample(_ sample: Float, to data: inout Data) {
        switch settings.bitDepth {
        case .bits16:
            let value = Self.quantize(sample, maximum: 32_767, minimum: -32_768)
            let word = Int16(truncatingIfNeeded: value)
            switch settings.format {
            case .wav: data.appendLittle(UInt16(bitPattern: word))
            case .aiff: data.appendBig(UInt16(bitPattern: word))
            }
        case .bits24:
            let value = Self.quantize(sample, maximum: 8_388_607, minimum: -8_388_608)
            let word = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
            switch settings.format {
            case .wav:
                data.append(UInt8(word & 0xFF))
                data.append(UInt8((word >> 8) & 0xFF))
                data.append(UInt8((word >> 16) & 0xFF))
            case .aiff:
                data.append(UInt8((word >> 16) & 0xFF))
                data.append(UInt8((word >> 8) & 0xFF))
                data.append(UInt8(word & 0xFF))
            }
        }
    }

    /// Float in [-1, 1] to an integer sample, saturating rather than wrapping.
    static func quantize(_ sample: Float, maximum: Int64, minimum: Int64) -> Int64 {
        guard sample.isFinite else { return 0 }
        let scaled = Double(sample) * Double(sample < 0 ? -minimum : maximum)
        let rounded = scaled.rounded(.toNearestOrAwayFromZero)
        if rounded >= Double(maximum) { return maximum }
        if rounded <= Double(minimum) { return minimum }
        return Int64(rounded)
    }
}

// MARK: - Byte-order helpers

extension Data {
    mutating func appendLittle<T: FixedWidthInteger>(_ value: T) {
        // `Swift.withUnsafeBytes`, qualified: inside a `Data` extension the bare
        // name resolves to `Data`'s own instance method, which reads this
        // buffer instead of the argument's.
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendBig<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
