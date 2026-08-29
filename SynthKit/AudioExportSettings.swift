import Foundation

/// The container an export is written into (REQ-026).
///
/// Two, and deliberately only two. The definition names WAV and AIFF and lists
/// compressed formats as a non-goal, so there is no MP3 case waiting to be
/// filled in — an uncompressed export is the only kind that can carry the
/// "equal to live playback" claim byte for byte.
public enum AudioExportFormat: String, CaseIterable, Sendable, Codable, Equatable {
    /// RIFF/WAVE, little-endian PCM.
    case wav
    /// Apple/IFF AIFF, big-endian PCM.
    case aiff

    public var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aiff: return "aiff"
        }
    }

    public var displayName: String {
        switch self {
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        }
    }

    /// The UTI a save panel filters on.
    public var contentTypeIdentifier: String {
        switch self {
        case .wav: return "com.microsoft.waveform-audio"
        case .aiff: return "public.aiff-audio"
        }
    }
}

/// How many bits each sample is quantized to.
///
/// 16 is the CD-quality floor the issue asks for; 24 is offered because the
/// engine renders in float and throwing eight bits away is the owner's choice
/// to make, not this leaf's.
public enum AudioExportBitDepth: Int, CaseIterable, Sendable, Codable, Equatable {
    case bits16 = 16
    case bits24 = 24

    public var bytesPerSample: Int { rawValue / 8 }

    public var displayName: String { "\(rawValue)-bit" }
}

/// Sample rates the export offers.
///
/// 44.1 kHz is the CD-quality floor; the other two exist because the engine is
/// rate-agnostic — a program is rebuilt at whatever rate it is asked for — so
/// offering them costs nothing and refusing them would be arbitrary.
public enum AudioExportSampleRate: Int, CaseIterable, Sendable, Codable, Equatable {
    case rate44100 = 44_100
    case rate48000 = 48_000
    case rate96000 = 96_000

    public var hertz: Double { Double(rawValue) }

    public var displayName: String {
        switch self {
        case .rate44100: return "44.1 kHz"
        case .rate48000: return "48 kHz"
        case .rate96000: return "96 kHz"
        }
    }
}

/// Everything about the file an export produces, other than where it goes.
public struct AudioExportSettings: Sendable, Equatable, Codable {
    public var format: AudioExportFormat
    public var sampleRate: AudioExportSampleRate
    public var bitDepth: AudioExportBitDepth

    public init(
        format: AudioExportFormat = .wav,
        sampleRate: AudioExportSampleRate = .rate48000,
        bitDepth: AudioExportBitDepth = .bits24
    ) {
        self.format = format
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }

    /// Exactly CD quality: 44.1 kHz, 16-bit, WAV. The floor the issue names.
    public static let cdQuality = AudioExportSettings(
        format: .wav, sampleRate: .rate44100, bitDepth: .bits16
    )

    /// What the export sheet opens on: the engine's own working rate, at the
    /// depth that keeps the float render's dynamic range intact.
    public static let standard = AudioExportSettings()

    /// True when this is at least 44.1 kHz and at least 16-bit.
    ///
    /// Structurally always true, because neither enum can express less — which
    /// is the point of making them enums rather than numbers. Asserted by
    /// `AudioExportTests` so a later case cannot quietly drop below the floor.
    public var meetsCDQualityFloor: Bool {
        sampleRate.rawValue >= 44_100 && bitDepth.rawValue >= 16
    }

    /// Stereo, always: the engine's graph is stereo and a mono fold-down would
    /// no longer be what live playback sounds like.
    public var channelCount: Int { 2 }

    public var bytesPerFrame: Int { channelCount * bitDepth.bytesPerSample }

    /// "WAV · 44.1 kHz · 16-bit"
    public var displayName: String {
        "\(format.displayName) · \(sampleRate.displayName) · \(bitDepth.displayName)"
    }

    /// Exact size of the audio payload for `frameCount` frames.
    public func payloadByteCount(frameCount: Int64) -> Int64 {
        frameCount * Int64(bytesPerFrame)
    }
}

/// File names an export uses: the one it suggests, and the hidden sibling it
/// stages the bytes in.
///
/// **Both live here, because they have to agree.** The staged name wraps the
/// destination's own name, so its length is the destination's length plus a
/// fixed overhead — and if the suggested name and the staged name derive their
/// limits separately, the app can suggest a name in its own save panel whose
/// staged sibling is then too long for the filesystem to create. Every bound
/// below is computed from `maximumFileNameBytes`, once.
public enum AudioExportNaming {
    /// Characters a file name may not contain, plus the ones that make a name
    /// awkward rather than illegal.
    private static let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\u{0}")

    /// The longest file name every macOS filesystem accepts, in bytes
    /// (`NAME_MAX`). Bytes, not characters: a title in Greek or Japanese
    /// reaches it in a third of the characters an English one does.
    public static let maximumFileNameBytes = 255

    /// What `stagedFileName(for:)` adds around a destination's own name:
    /// the leading dot, the `.synth-partial-` marker, and a UUID.
    static let stagedNameOverheadBytes = 1 + ".synth-partial-".utf8.count + 36

    /// The longest destination name whose staged sibling still fits.
    ///
    /// 203 bytes. Anything the app itself suggests is capped here, so the
    /// staged file for a suggestion is never truncated; a longer name the owner
    /// typed themselves is still exported, because the staged name truncates
    /// its embedded copy rather than refusing.
    public static let maximumSuggestedNameBytes =
        maximumFileNameBytes - stagedNameOverheadBytes

    /// `"Prelude in C — Chamber.wav"`, with the preset dropped when it is the
    /// only one and the piece already says everything.
    public static func suggestedFileName(
        pieceTitle: String,
        presetName: String?,
        format: AudioExportFormat
    ) -> String {
        var stem = sanitized(pieceTitle)
        if stem.isEmpty { stem = "Untitled piece" }
        if let presetName, !presetName.isEmpty {
            let preset = sanitized(presetName)
            if !preset.isEmpty { stem += " — \(preset)" }
        }
        let limit = maximumSuggestedNameBytes - format.fileExtension.utf8.count - 1  // the dot
        stem = truncated(stem, toByteCount: max(0, limit))
        stem = stem.trimmingCharacters(in: .whitespaces)
        if stem.isEmpty { stem = "Untitled piece" }
        return "\(stem).\(format.fileExtension)"
    }

    /// The hidden sibling an export stages its bytes in, for a destination
    /// called `destinationName`.
    ///
    /// Dot-prefixed so it is invisible in Finder, and uniquely suffixed so two
    /// exports of one piece at once cannot collide. **The UUID carries the
    /// uniqueness; the embedded destination name is only there to make a
    /// leftover file self-explaining**, so it is the part that gives way when
    /// the total would exceed `NAME_MAX`.
    public static func stagedFileName(
        for destinationName: String, uniqueSuffix: String = UUID().uuidString
    ) -> String {
        let overhead = 1 + ".synth-partial-".utf8.count + uniqueSuffix.utf8.count
        let room = max(0, maximumFileNameBytes - overhead)
        let embedded = truncated(destinationName, toByteCount: room)
        return ".\(embedded).synth-partial-\(uniqueSuffix)"
    }

    /// `text` shortened to at most `byteCount` UTF-8 bytes, never splitting a
    /// character.
    static func truncated(_ text: String, toByteCount byteCount: Int) -> String {
        guard text.utf8.count > byteCount else { return text }
        var shortened = text
        while shortened.utf8.count > byteCount, !shortened.isEmpty {
            shortened.removeLast()
        }
        return shortened
    }

    static func sanitized(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            forbidden.contains(scalar) ? "-" : Character(scalar)
        }
        return String(scalars)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
