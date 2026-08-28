import Foundation

/// The seeded pseudo-noise humanization draws its micro-variation from.
///
/// **Not a generator.** A generator holds a position in a stream, so what it
/// produces for one note depends on how many notes came before it — and an
/// event list that is assembled per line, then merged, then sorted has no one
/// true "before". A single reordering, a `Dictionary` iterated in launch
/// order, or a line realized on another thread would all silently change the
/// interpretation.
///
/// So this is a *function* instead: `value(seed:key:)` maps one event's own
/// canonical identity to one 64-bit value. Nothing accumulates, nothing has to
/// be visited in order, and two realizations agree even if they build their
/// events in a completely different sequence. That is what makes REQ-012's
/// byte-identity claim structural rather than a property the tests happen to
/// observe.
///
/// FNV-1a rather than Swift's `Hasher`: `Hasher` is seeded once per process,
/// so the same key hashes differently on the next launch. FNV-1a is a fixed
/// specification and gives the same bytes on every machine and every build.
enum SeededJitter {
    /// The two 64-bit words a realization's noise is keyed by.
    struct Seed: Equatable, Sendable {
        let high: UInt64
        let low: UInt64
    }

    /// Derives the seed for one (piece, preset, humanization) configuration.
    ///
    /// Everything the interpretation may legitimately depend on goes into the
    /// digest, and nothing else can: change the piece, the stored bytes, the
    /// preset or a humanization control and the noise moves; change nothing
    /// and it cannot.
    static func seed(
        pieceID: String,
        contentSHA256: String,
        settings: RealizationSettings
    ) -> Seed {
        let hex = seedHex(pieceID: pieceID, contentSHA256: contentSHA256, settings: settings)
        return Seed(high: word(ofHex: hex, at: 0), low: word(ofHex: hex, at: 16))
    }

    /// The hexadecimal seed digest, which the timeline carries so an owner —
    /// or a later export — can tell two interpretations apart at a glance.
    static func seedHex(
        pieceID: String,
        contentSHA256: String,
        settings: RealizationSettings
    ) -> String {
        let canonical = [
            "synth/humanization/v1",
            pieceID,
            contentSHA256,
            settings.presetIdentifier,
            settings.humanization.isEnabled ? "on" : "off",
            String(settings.humanization.intensity)
        ].joined(separator: "\u{1F}")
        return MusicXMLImporter.sha256Hex(Data(canonical.utf8))
    }

    /// One value for `key` under `seed`, in the full 64-bit range.
    static func value(seed: Seed, key: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return mix((hash ^ seed.high) &+ seed.low)
    }

    /// A second, independent value for the same key, so one event can be given
    /// a timing offset and a loudness offset that do not track each other.
    static func secondValue(seed: Seed, key: String) -> UInt64 {
        mix(value(seed: seed, key: key) ^ 0x9e37_79b9_7f4a_7c15)
    }

    /// A value in `-magnitude ... magnitude`, evenly spread.
    static func signed(_ value: UInt64, magnitude: Int) -> Int {
        guard magnitude > 0 else { return 0 }
        let span = UInt64(2 * magnitude + 1)
        return Int(value % span) - magnitude
    }

    /// SplitMix64's finalizer: the standard avalanche step that turns a
    /// counter-like input into a well-spread 64-bit value.
    private static func mix(_ input: UInt64) -> UInt64 {
        var z = input &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// The 64-bit word starting at hexadecimal character `offset`.
    private static func word(ofHex hex: String, at offset: Int) -> UInt64 {
        let characters = Array(hex.utf8)
        var result: UInt64 = 0
        for index in offset..<min(offset + 16, characters.count) {
            let byte = characters[index]
            let digit: UInt64
            switch byte {
            case 0x30...0x39: digit = UInt64(byte - 0x30)
            case 0x61...0x66: digit = UInt64(byte - 0x61 + 10)
            case 0x41...0x46: digit = UInt64(byte - 0x41 + 10)
            default: digit = 0
            }
            result = (result << 4) | digit
        }
        return result
    }
}
