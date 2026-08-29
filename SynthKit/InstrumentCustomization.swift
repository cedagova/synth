import Foundation

/// What the owner may change about a downloaded instrument (REQ-021, D7).
///
/// **The whole control set, and deliberately no more.** D7 names tone/EQ,
/// dynamics response, envelope shaping within realistic bounds, vibrato depth
/// and rate, a tuning offset, and per-line volume/pan/room send. The first six
/// are here because they are properties of *the sound*; volume, pan and room
/// send are not, because they are properties of *the line* — they live in
/// `LineMixerState` beside mute and solo, where the mixer already writes them
/// straight to the engine while the piece plays (REQ-008). Splitting them that
/// way is what keeps one value in one place: a variant assigned to two lines is
/// the same tone on both and may still sit differently in the mix.
///
/// **Nothing here edits samples.** Every field is a parameter the render core
/// applies over the recorded audio: shelves on the output, a multiplier on the
/// playback rate, a scale on the envelope the SFZ file already declared. The
/// downloaded assets are read-only and stay read-only — a variant is a
/// description of how to play them, never a rewrite of them.
///
/// **Bounds are realistic rather than generous.** `releaseScale` stops at four
/// times the library's own release because a sampled release is a recording of
/// a real decay and stretching it further sounds like a tape effect, not like
/// an instrument. `vibratoDepthCents` stops at a semitone for the same reason.
/// A control that could be pushed somewhere no instrument goes is a control
/// that fakes, which is exactly what REQ-021 forbids.
public struct InstrumentCustomization: Equatable, Sendable, Codable {
    // MARK: Tone

    /// Low shelf at 250 Hz, in decibels. Body and weight.
    public var toneLowDecibels: Double

    /// High shelf at 4 kHz, in decibels. Air and bow noise.
    public var toneHighDecibels: Double

    // MARK: Dynamics

    /// How strongly playing harder changes the level, relative to what the
    /// library recorded. 1 is exactly as sampled; below 1 flattens the
    /// difference, above 1 exaggerates it.
    ///
    /// **Only meaningful on an instrument with more than one sampled dynamic
    /// layer.** On a one-layer patch there is nothing sampled to respond with,
    /// so `InstrumentCapabilities` disables this control rather than letting it
    /// move a gain and call it dynamics.
    public var dynamicsResponse: Double

    // MARK: Envelope

    /// Extra attack softening, in seconds, added to whatever the library
    /// declares. A bowed line eased in; never a faster attack than the
    /// recording has, because that would mean cutting into the sample.
    public var attackSeconds: Double

    /// Multiplier on the library's own release time. 1 leaves it exactly as
    /// recorded.
    public var releaseScale: Double

    // MARK: Pitch

    /// Vibrato depth in cents, 0 for none.
    public var vibratoDepthCents: Double

    /// Vibrato rate in hertz.
    public var vibratoRateHz: Double

    /// Fixed pitch offset in cents, for playing with an ensemble tuned to
    /// something other than A=440.
    public var tuningOffsetCents: Double

    // MARK: Articulation

    /// Which of the instrument's SFZ files this variant plays, by file name, or
    /// nil for its entry point.
    ///
    /// Not a tone control, but it belongs with them: it is the other thing the
    /// owner chooses about a downloaded instrument, and INS002 left the choice
    /// here on purpose (`SampledInstrumentVoiceProvider.init(available:articulation:)`).
    /// A file name rather than a URL, because a variant outlives the container
    /// path an install happened to use.
    public var articulationFileName: String?

    public init(
        toneLowDecibels: Double = 0,
        toneHighDecibels: Double = 0,
        dynamicsResponse: Double = 1,
        attackSeconds: Double = 0,
        releaseScale: Double = 1,
        vibratoDepthCents: Double = 0,
        vibratoRateHz: Double = 5,
        tuningOffsetCents: Double = 0,
        articulationFileName: String? = nil
    ) {
        self.toneLowDecibels = toneLowDecibels
        self.toneHighDecibels = toneHighDecibels
        self.dynamicsResponse = dynamicsResponse
        self.attackSeconds = attackSeconds
        self.releaseScale = releaseScale
        self.vibratoDepthCents = vibratoDepthCents
        self.vibratoRateHz = vibratoRateHz
        self.tuningOffsetCents = tuningOffsetCents
        self.articulationFileName = articulationFileName
    }

    /// The instrument exactly as the library recorded it.
    public static let asRecorded = InstrumentCustomization()

    /// True when nothing has been changed from the recording.
    public var isAsRecorded: Bool {
        var neutral = InstrumentCustomization.asRecorded
        neutral.articulationFileName = articulationFileName
        return self == neutral
    }

    // MARK: Bounds

    public static let toneDecibelRange: ClosedRange<Double> = -12...12
    public static let dynamicsResponseRange: ClosedRange<Double> = 0...2
    public static let attackSecondsRange: ClosedRange<Double> = 0...0.5
    public static let releaseScaleRange: ClosedRange<Double> = 0.25...4
    public static let vibratoDepthCentsRange: ClosedRange<Double> = 0...100
    public static let vibratoRateHzRange: ClosedRange<Double> = 0.5...9
    public static let tuningOffsetCentsRange: ClosedRange<Double> = -100...100

    /// Every field brought inside its bound, with a non-finite value replaced by
    /// the recorded default.
    ///
    /// Applied on the way in and on the way out of storage, so no value the
    /// render core sees can be outside the range the UI offers — and a document
    /// hand-edited to `1e300` becomes an instrument rather than a NaN.
    public func clamped() -> InstrumentCustomization {
        func bound(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        return InstrumentCustomization(
            toneLowDecibels: bound(toneLowDecibels, Self.toneDecibelRange, 0),
            toneHighDecibels: bound(toneHighDecibels, Self.toneDecibelRange, 0),
            dynamicsResponse: bound(dynamicsResponse, Self.dynamicsResponseRange, 1),
            attackSeconds: bound(attackSeconds, Self.attackSecondsRange, 0),
            releaseScale: bound(releaseScale, Self.releaseScaleRange, 1),
            vibratoDepthCents: bound(vibratoDepthCents, Self.vibratoDepthCentsRange, 0),
            vibratoRateHz: bound(vibratoRateHz, Self.vibratoRateHzRange, 5),
            tuningOffsetCents: bound(tuningOffsetCents, Self.tuningOffsetCentsRange, 0),
            articulationFileName: articulationFileName
        )
    }

    // MARK: Decoding

    /// Every field defaults to the recorded value when a document does not name
    /// it.
    ///
    /// Additive by construction: a variant written by a build that gains a
    /// control still reads here, minus that control, instead of failing to open
    /// — the same forward tolerance `LineMixerState` uses for `roomSend`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try container.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        self.init(
            toneLowDecibels: try value(.toneLowDecibels, 0),
            toneHighDecibels: try value(.toneHighDecibels, 0),
            dynamicsResponse: try value(.dynamicsResponse, 1),
            attackSeconds: try value(.attackSeconds, 0),
            releaseScale: try value(.releaseScale, 1),
            vibratoDepthCents: try value(.vibratoDepthCents, 0),
            vibratoRateHz: try value(.vibratoRateHz, 5),
            tuningOffsetCents: try value(.tuningOffsetCents, 0),
            articulationFileName: try container.decodeIfPresent(
                String.self, forKey: .articulationFileName
            )
        )
    }
}

// MARK: - Display

extension InstrumentCustomization {
    /// One short sentence naming what has been changed, or nil when nothing
    /// has.
    ///
    /// Here rather than in a `View` for the reason `PieceDisplay` gives: a
    /// sentence assembled inside a `body` cannot be asserted, and this one is
    /// read by VoiceOver on the variant row.
    public var changeSummary: String? {
        var parts: [String] = []
        if toneLowDecibels != 0 {
            parts.append("low \(Self.signed(toneLowDecibels)) dB")
        }
        if toneHighDecibels != 0 {
            parts.append("high \(Self.signed(toneHighDecibels)) dB")
        }
        if dynamicsResponse != 1 {
            parts.append("dynamics \(Self.rounded(dynamicsResponse, places: 2))×")
        }
        if attackSeconds != 0 {
            parts.append("attack +\(Self.rounded(attackSeconds * 1000, places: 0)) ms")
        }
        if releaseScale != 1 {
            parts.append("release \(Self.rounded(releaseScale, places: 2))×")
        }
        if vibratoDepthCents != 0 {
            parts.append(
                "vibrato \(Self.rounded(vibratoDepthCents, places: 0)) cents "
                    + "at \(Self.rounded(vibratoRateHz, places: 1)) Hz"
            )
        }
        if tuningOffsetCents != 0 {
            parts.append("tuning \(Self.signed(tuningOffsetCents)) cents")
        }
        if let articulationFileName {
            parts.append("articulation \(articulationFileName)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func signed(_ value: Double) -> String {
        let text = rounded(abs(value), places: 1)
        return value < 0 ? "−\(text)" : "+\(text)"
    }

    /// `value` to at most `places` decimals, with trailing zeros removed.
    ///
    /// **`%f`, not `%g`.** Driving the built app showed why: `%g`'s precision is
    /// *significant digits*, so a twelve-decibel boost came out of
    /// `changeSummary` as "1e+01 dB" and went straight into the name the Save
    /// as Variant sheet suggested. A number the owner is about to accept as a
    /// name has to read like a number.
    static func rounded(_ value: Double, places: Int) -> String {
        let scale = pow(10.0, Double(places))
        let snapped = (value * scale).rounded() / scale
        guard places > 0 else { return String(Int(snapped.rounded())) }

        var text = String(format: "%.\(places)f", snapped)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
