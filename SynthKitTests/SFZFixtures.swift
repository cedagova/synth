import Foundation
@testable import SynthKit

/// Builds small SFZ instruments on disk, one per opcode family.
///
/// **CI never sees the curated set.** The three real libraries are 3.2 GB and
/// are downloaded into the app's own container by INS001; committing them, or
/// fetching them in a workflow, would make the build depend on 3.2 GB of
/// third-party bytes for claims that a few kilobytes can prove. So every
/// automated check here runs against instruments generated in a temporary
/// directory, and the real libraries are exercised in the manual smoke on the
/// owner's machine, where they already are.
///
/// The fixtures are built so that *what played is visible in the samples*. Each
/// generated WAV is a constant level, and no two samples in one fixture share a
/// level, so a rendered buffer says which region sounded — which velocity
/// layer, which round robin, which articulation — without the test having to
/// ask the player what it thinks it did. Where pitch is the claim, the sample
/// is a sine at a known frequency instead, and the test measures the frequency
/// that came out.
enum SFZFixtures {
    /// A fresh temporary directory for one fixture library.
    static func makeLibraryDirectory(_ name: String = "fixture") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "synth-sfz-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - WAV writing

    enum Encoding {
        case pcm16, pcm24, pcm32, float32
    }

    /// Write `frames` (one value per frame, duplicated across channels) as a
    /// WAV file.
    ///
    /// `loop` writes an `smpl` chunk, which is how a real library declares a
    /// sustain loop without any SFZ opcode at all — the case
    /// `SampleWaveform.readHeader` has to find by walking chunks.
    /// `extraChunkBeforeData` writes a junk chunk ahead of the audio, which is
    /// what 455 of the curated set's files do and what makes a fixed 44-byte
    /// header wrong.
    static func writeWave(
        _ frames: [Float],
        to url: URL,
        sampleRate: Double = 44_100,
        channels: Int = 1,
        encoding: Encoding = .pcm16,
        loop: (start: Int, end: Int)? = nil,
        extraChunkBeforeData: Bool = false
    ) throws {
        var body = Data()

        func appendChunk(_ identifier: String, _ payload: Data) {
            body.append(contentsOf: Array(identifier.utf8))
            body.append(littleEndian: UInt32(payload.count))
            body.append(payload)
            if payload.count % 2 == 1 { body.append(0) }
        }

        let bits: Int
        let audioFormat: UInt16
        switch encoding {
        case .pcm16: bits = 16; audioFormat = 1
        case .pcm24: bits = 24; audioFormat = 1
        case .pcm32: bits = 32; audioFormat = 1
        case .float32: bits = 32; audioFormat = 3
        }
        let blockAlign = channels * bits / 8

        var format = Data()
        format.append(littleEndian: audioFormat)
        format.append(littleEndian: UInt16(channels))
        format.append(littleEndian: UInt32(sampleRate))
        format.append(littleEndian: UInt32(Int(sampleRate) * blockAlign))
        format.append(littleEndian: UInt16(blockAlign))
        format.append(littleEndian: UInt16(bits))
        appendChunk("fmt ", format)

        if extraChunkBeforeData {
            appendChunk("junk", Data(repeating: 0, count: 30))
        }

        var audio = Data()
        audio.reserveCapacity(frames.count * blockAlign)
        for value in frames {
            for _ in 0..<channels {
                switch encoding {
                case .pcm16:
                    audio.append(littleEndian: UInt16(bitPattern: Int16(clamping16(value))))
                case .pcm24:
                    let scaled = Int32(clamping24(value))
                    audio.append(UInt8(truncatingIfNeeded: scaled))
                    audio.append(UInt8(truncatingIfNeeded: scaled >> 8))
                    audio.append(UInt8(truncatingIfNeeded: scaled >> 16))
                case .pcm32:
                    audio.append(littleEndian: UInt32(bitPattern: clamping32(value)))
                case .float32:
                    audio.append(littleEndian: value.bitPattern)
                }
            }
        }
        appendChunk("data", audio)

        if let loop {
            var chunk = Data(repeating: 0, count: 36)
            chunk.replaceSubrange(28..<32, with: bytes(of: UInt32(1).littleEndian))
            var entry = Data(repeating: 0, count: 24)
            entry.replaceSubrange(8..<12, with: bytes(of: UInt32(loop.start).littleEndian))
            entry.replaceSubrange(12..<16, with: bytes(of: UInt32(loop.end).littleEndian))
            appendChunk("smpl", chunk + entry)
        }

        var file = Data()
        file.append(contentsOf: Array("RIFF".utf8))
        file.append(littleEndian: UInt32(body.count + 4))
        file.append(contentsOf: Array("WAVE".utf8))
        file.append(body)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try file.write(to: url)
    }

    private static func clamping16(_ value: Float) -> Int {
        Int((min(max(value, -1), 1) * 32767).rounded())
    }
    private static func clamping24(_ value: Float) -> Int {
        Int((min(max(value, -1), 1) * 8388607).rounded())
    }
    private static func clamping32(_ value: Float) -> Int32 {
        Int32((Double(min(max(value, -1), 1)) * 2147483647).rounded())
    }

    /// A constant level, `seconds` long.
    static func constant(_ level: Float, seconds: Double = 0.5, sampleRate: Double = 44_100)
        -> [Float] {
        [Float](repeating: level, count: Int(seconds * sampleRate))
    }

    /// A sine at `hertz`, for the tests whose claim is about pitch.
    static func sine(
        hertz: Double, seconds: Double = 0.5, sampleRate: Double = 44_100, amplitude: Float = 0.5
    ) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * hertz * Double(index) / sampleRate))
        }
    }

    // MARK: - Instruments

    /// Write an SFZ file and return the `AvailableInstrument` that names it, so
    /// a fixture goes through exactly the same entry point as a real download.
    @discardableResult
    static func writeInstrument(
        _ sfz: String,
        named fileName: String = "instrument.sfz",
        in root: URL,
        instrumentName: String = "Fixture",
        family: InstrumentCoverage.Family = .keyboards,
        dynamicLayerCount: Int = 1,
        alternates: [String] = []
    ) throws -> AvailableInstrument {
        let url = root.appending(path: fileName)
        try sfz.write(to: url, atomically: true, encoding: .utf8)

        let coverage = InstrumentCoverage(
            identifier: "fixture.\(instrumentName.lowercased())",
            name: instrumentName,
            family: family,
            sfzPath: fileName,
            alternateSFZPaths: alternates,
            dynamicLayerCount: dynamicLayerCount
        )
        return AvailableInstrument(
            libraryID: "fixture-library",
            libraryName: "Fixture Library",
            coverage: coverage,
            sfzURL: url,
            alternateSFZURLs: alternates.map { root.appending(path: $0) },
            libraryRootURL: root,
            requiredAttribution: ""
        )
    }

    // MARK: - Ready-made instruments, one per opcode family

    /// Key mapping and pitch: one sine sample, keycentred, spanning an octave.
    static func pitchedInstrument(in root: URL, sampleRate: Double = 44_100) throws
        -> AvailableInstrument {
        try writeWave(
            sine(hertz: 440, seconds: 1.0, sampleRate: sampleRate),
            to: root.appending(path: "samples/a440.wav"),
            sampleRate: sampleRate
        )
        return try writeInstrument(
            """
            <control>
            default_path=samples\\

            <group>
            ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0
            <region> sample=a440.wav lokey=48 hikey=96 pitch_keycenter=69
            """,
            in: root, instrumentName: "Pitched"
        )
    }

    /// Velocity layers: three levels on one key, each a different constant, so
    /// the rendered level says which layer was chosen.
    static func velocityLayeredInstrument(in root: URL) throws -> AvailableInstrument {
        try writeWave(constant(0.10), to: root.appending(path: "soft.wav"))
        try writeWave(constant(0.40), to: root.appending(path: "mid.wav"))
        try writeWave(constant(0.80), to: root.appending(path: "loud.wav"))
        return try writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=soft.wav lokey=60 hikey=60 pitch_keycenter=60 lovel=1 hivel=42
            <region> sample=mid.wav lokey=60 hikey=60 pitch_keycenter=60 lovel=43 hivel=84
            <region> sample=loud.wav lokey=60 hikey=60 pitch_keycenter=60 lovel=85 hivel=127
            """,
            in: root, instrumentName: "Layers", dynamicLayerCount: 3
        )
    }

    /// Round robins: `seq_length`/`seq_position` on one key, three alternates.
    static func sequencedInstrument(in root: URL) throws -> AvailableInstrument {
        try writeWave(constant(0.10), to: root.appending(path: "rr1.wav"))
        try writeWave(constant(0.40), to: root.appending(path: "rr2.wav"))
        try writeWave(constant(0.70), to: root.appending(path: "rr3.wav"))
        return try writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
              seq_length=3 lokey=60 hikey=60 pitch_keycenter=60
            <region> sample=rr1.wav seq_position=1
            <region> sample=rr2.wav seq_position=2
            <region> sample=rr3.wav seq_position=3
            """,
            in: root, instrumentName: "Sequenced"
        )
    }

    /// Random round robins: `lorand`/`hirand` split two ways.
    static func randomisedInstrument(in root: URL) throws -> AvailableInstrument {
        try writeWave(constant(0.20), to: root.appending(path: "randA.wav"))
        try writeWave(constant(0.60), to: root.appending(path: "randB.wav"))
        return try writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
              lokey=60 hikey=60 pitch_keycenter=60
            <region> sample=randA.wav lorand=0 hirand=0.5
            <region> sample=randB.wav lorand=0.5 hirand=1
            """,
            in: root, instrumentName: "Randomised"
        )
    }

    /// A sustain loop, declared the way a real library declares one: in the
    /// WAV's own `smpl` chunk, with no SFZ opcode at all.
    ///
    /// The sample is 0.6 for its first tenth of a second and 0.2 after that,
    /// with the loop over the second part — so a render longer than the sample
    /// proves the loop by still producing 0.2 where an unlooped sample would
    /// have gone silent.
    static func loopedInstrument(in root: URL, sampleRate: Double = 44_100) throws
        -> AvailableInstrument {
        let head = [Float](repeating: 0.6, count: Int(0.1 * sampleRate))
        let body = [Float](repeating: 0.2, count: Int(0.1 * sampleRate))
        try writeWave(
            head + body,
            to: root.appending(path: "looped.wav"),
            sampleRate: sampleRate,
            loop: (start: head.count, end: head.count + body.count - 1)
        )
        return try writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=looped.wav lokey=60 hikey=60 pitch_keycenter=60
            """,
            in: root, instrumentName: "Looped"
        )
    }

    /// Release triggers with `rt_decay`: a note layer and a release layer, at
    /// distinguishable levels.
    static func releaseTriggeredInstrument(
        in root: URL, releaseDecayDBPerSecond: Double = 6
    ) throws -> AvailableInstrument {
        try writeWave(constant(0.50, seconds: 4.0), to: root.appending(path: "note.wav"))
        try writeWave(constant(0.20, seconds: 1.0), to: root.appending(path: "release.wav"))
        return try writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=note.wav lokey=60 hikey=60 pitch_keycenter=60

            <group> trigger=release ampeg_attack=0 ampeg_release=0.5 amp_veltrack=0
              pitch_keytrack=0 rt_decay=\(releaseDecayDBPerSecond)
            <region> sample=release.wav lokey=60 hikey=60 pitch_keycenter=60
            """,
            in: root, instrumentName: "Released"
        )
    }

    /// Sixteen velocity layers with sampled releases: the shape Salamander has,
    /// and the one INS003's dynamics-response control is gated on.
    ///
    /// Every layer is a constant at a different level so a rendered level says
    /// which one sounded, and `amp_veltrack` is left at SFZ's default so the
    /// engine's own velocity curve — the thing `dynamicsResponse` reshapes — is
    /// what varies the loudness inside a layer.
    static func deeplyLayeredInstrument(in root: URL) throws -> AvailableInstrument {
        let layers = 16
        var regions: [String] = []
        for index in 0..<layers {
            let name = "layer\(index).wav"
            try writeWave(
                constant(0.05 + 0.05 * Float(index), seconds: 2.0),
                to: root.appending(path: name)
            )
            let low = index * 8 + 1
            let high = index == layers - 1 ? 127 : (index + 1) * 8
            regions.append(
                "<region> sample=\(name) lokey=60 hikey=60 pitch_keycenter=60 "
                    + "lovel=\(low) hivel=\(high)"
            )
        }
        try writeWave(constant(0.04, seconds: 1.0), to: root.appending(path: "release.wav"))
        return try writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.2 pitch_keytrack=0
            \(regions.joined(separator: "\n"))

            <group> trigger=release ampeg_attack=0 ampeg_release=0.3 amp_veltrack=0
              pitch_keytrack=0 rt_decay=6
            <region> sample=release.wav lokey=60 hikey=60 pitch_keycenter=60
            """,
            in: root, instrumentName: "Deep Layers", dynamicLayerCount: layers,
            alternates: ["alt.sfz"]
        )
    }

    /// A patch made entirely of one-shots: the sample always plays to its end
    /// and note-off does nothing, which is what a percussion map is.
    static func oneShotInstrument(in root: URL) throws -> AvailableInstrument {
        try writeWave(constant(0.4, seconds: 0.5), to: root.appending(path: "hit.wav"))
        return try writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
              loop_mode=one_shot
            <region> sample=hit.wav lokey=60 hikey=60 pitch_keycenter=60
            """,
            in: root, instrumentName: "One Shots", family: .percussion
        )
    }

    /// A pitched instrument with two velocity layers and a long sustaining
    /// sine, for the render tests that need both a measurable pitch and a
    /// dynamics response to reshape.
    static func pitchedLayeredInstrument(in root: URL, sampleRate: Double = 44_100) throws
        -> AvailableInstrument {
        try writeWave(
            sine(hertz: 440, seconds: 3.0, sampleRate: sampleRate),
            to: root.appending(path: "soft440.wav"),
            sampleRate: sampleRate
        )
        try writeWave(
            sine(hertz: 440, seconds: 3.0, sampleRate: sampleRate),
            to: root.appending(path: "loud440.wav"),
            sampleRate: sampleRate
        )
        return try writeInstrument(
            """
            <group> ampeg_attack=0.001 ampeg_release=0.2
            <region> sample=soft440.wav lokey=48 hikey=96 pitch_keycenter=69 lovel=1 hivel=63
            <region> sample=loud440.wav lokey=48 hikey=96 pitch_keycenter=69 lovel=64 hivel=127
            """,
            in: root, instrumentName: "Pitched Layers", family: .strings, dynamicLayerCount: 2
        )
    }

    /// Keyswitched articulations, written the way VSCO 2's `-KS` files are:
    /// one `<control>` per articulation, each with its own `default_path`, and
    /// `sw_default`/`sw_lokey`/`sw_hikey`/`sw_last` on every group.
    static func keyswitchedInstrument(in root: URL) throws -> AvailableInstrument {
        try writeWave(constant(0.30), to: root.appending(path: "artA/sample.wav"))
        try writeWave(constant(0.70), to: root.appending(path: "artB/sample.wav"))
        return try writeInstrument(
            """
            <control>
            default_path=artA\\

            <group>
            sw_default=c1 sw_lokey=c1 sw_hikey=c#1 sw_last=c1 sw_label=A
            ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=sample.wav lokey=60 hikey=60 pitch_keycenter=60

            <control>
            default_path=artB\\

            <group>
            sw_default=c1 sw_lokey=c1 sw_hikey=c#1 sw_last=c#1 sw_label=B
            ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=sample.wav lokey=60 hikey=60 pitch_keycenter=60
            """,
            in: root, instrumentName: "Keyswitched"
        )
    }
}

// MARK: - Little-endian appending

extension Data {
    fileprivate mutating func append(littleEndian value: UInt16) {
        append(SFZFixtures.bytes(of: value.littleEndian))
    }
    fileprivate mutating func append(littleEndian value: UInt32) {
        append(SFZFixtures.bytes(of: value.littleEndian))
    }
}

extension SFZFixtures {
    static func bytes<T>(of value: T) -> Data {
        var copy = value
        return withUnsafeBytes(of: &copy) { Data($0) }
    }
}
