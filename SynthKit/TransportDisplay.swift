import Foundation

/// The words and numbers the transport puts on screen and into VoiceOver
/// (REQ-009, REQ-027).
///
/// **In SynthKit, not in a `View`, on purpose.** The position readout is the
/// only positional orientation the product has — no score is drawn (D2) — so
/// getting `1:03.4` or `measure 12, beat 3.2` wrong is a product defect, not a
/// cosmetic one. Text assembled inside a SwiftUI `body` cannot be tested;
/// everything here can be, and is.
///
/// All of it is built with integer arithmetic and no formatter. A
/// locale-sensitive formatter would put a comma where this owner expects a
/// point, or reorder a duration, and the elapsed readout has to be readable
/// the same way on every machine.
public enum TransportDisplay {
    // MARK: Elapsed time

    /// `0:00.0`, `1:23.4`, or `1:02:03.4` once a piece passes an hour.
    ///
    /// Tenths rather than hundredths: the playhead is sampled by a UI timer, so
    /// a hundredths digit would be honest about the number and dishonest about
    /// the precision.
    public static func elapsedText(microseconds: Int64) -> String {
        let clamped = max(0, microseconds)
        let tenths = (clamped + 50_000) / 100_000
        let totalSeconds = tenths / 10
        let tenth = tenths % 10
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3_600

        let twoDigitSeconds = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        if hours > 0 {
            let twoDigitMinutes = minutes < 10 ? "0\(minutes)" : "\(minutes)"
            return "\(hours):\(twoDigitMinutes):\(twoDigitSeconds).\(tenth)"
        }
        return "\(minutes):\(twoDigitSeconds).\(tenth)"
    }

    /// `1:23.4 of 4:05.0` — elapsed against the length of the piece.
    public static func elapsedOfTotalText(microseconds: Int64, total: Int64) -> String {
        "\(elapsedText(microseconds: microseconds)) of \(elapsedText(microseconds: total))"
    }

    /// A duration spoken rather than punctuated, so VoiceOver does not read
    /// `1:23.4` as a time of day.
    public static func spokenElapsed(microseconds: Int64) -> String {
        let clamped = max(0, microseconds)
        let tenths = (clamped + 50_000) / 100_000
        let totalSeconds = tenths / 10
        let tenth = tenths % 10
        let seconds = totalSeconds % 60
        let minutes = totalSeconds / 60

        var parts: [String] = []
        if minutes > 0 {
            parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")")
        }
        if tenth == 0 {
            parts.append("\(seconds) second\(seconds == 1 ? "" : "s")")
        } else {
            parts.append("\(seconds).\(tenth) seconds")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Measure and beat

    /// `3.2`, one decimal, always with the point.
    public static func beatText(_ beat: Double) -> String {
        guard beat.isFinite else { return "1.0" }
        let tenths = Int((max(0, beat) * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }

    /// `Measure 12 · beat 3.2`, with the pass appended only when the piece is
    /// past its first time through that measure — which is the whole point of
    /// showing it, since a repeat plays one printed number several times.
    public static func positionText(_ position: ScorePosition?) -> String {
        guard let position else { return "—" }
        let pass = position.pass > 1 ? " (pass \(position.pass))" : ""
        return "Measure \(position.measureNumber)\(pass) · beat \(beatText(position.beat))"
    }

    /// The whole readout as one sentence, for VoiceOver.
    public static func spokenPosition(
        _ position: ScorePosition?,
        microseconds: Int64,
        total: Int64
    ) -> String {
        let elapsed = "\(spokenElapsed(microseconds: microseconds)) "
            + "of \(spokenElapsed(microseconds: total))"
        guard let position else {
            return "Position: end of the piece, \(elapsed)."
        }
        let pass = position.pass > 1 ? ", pass \(position.pass)" : ""
        return "Position: measure \(position.measureNumber)\(pass), "
            + "beat \(beatText(position.beat)), \(elapsed)."
    }

    // MARK: Parsing what the owner types

    /// Reads `83`, `83.4`, `1:23`, `1:23.4` or `1:02:03.4` as microseconds.
    ///
    /// Returns nil for anything else, so the field can refuse rather than seek
    /// somewhere the owner did not mean. Deliberately strict: only digits, at
    /// most two colons, and at most one decimal point.
    public static func parseTime(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }

        var total: Int64 = 0
        for (offset, part) in parts.enumerated() {
            let isLast = offset == parts.count - 1
            guard let seconds = isLast ? parseSecondsField(String(part)) : parseWholeField(String(part))
            else { return nil }
            // Every field but the last is a whole number of the next unit up.
            total = total * 60 + (isLast ? 0 : seconds)
            if isLast { return total * 1_000_000 + seconds }
        }
        return nil
    }

    /// A whole number of minutes or hours.
    private static func parseWholeField(_ text: String) -> Int64? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), text.count <= 4,
              let value = Int64(text)
        else { return nil }
        return value
    }

    /// Seconds, optionally with a fractional part, as microseconds.
    private static func parseSecondsField(_ text: String) -> Int64? {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let whole = parseWholeField(String(pieces[0])) else { return nil }
        guard pieces.count == 2 else { return whole * 1_000_000 }

        let fraction = String(pieces[1])
        guard !fraction.isEmpty, fraction.allSatisfy({ $0.isASCII && $0.isNumber }),
              fraction.count <= 6
        else { return nil }
        // "5" is five tenths, "05" five hundredths: pad to microseconds.
        let padded = fraction + String(repeating: "0", count: 6 - fraction.count)
        guard let micro = Int64(padded) else { return nil }
        return whole * 1_000_000 + micro
    }

    /// Reads a 1-based beat, whole or fractional. Values below 1 and anything
    /// unparseable are refused rather than silently clamped, so a typo does not
    /// look like a successful seek.
    public static func parseBeat(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2, !pieces[0].isEmpty,
              pieces[0].allSatisfy({ $0.isASCII && $0.isNumber }), pieces[0].count <= 4,
              let whole = Double(pieces[0])
        else { return nil }

        var beat = whole
        if pieces.count == 2 {
            let fraction = String(pieces[1])
            guard !fraction.isEmpty, fraction.allSatisfy({ $0.isASCII && $0.isNumber }),
                  fraction.count <= 4, let value = Double(fraction)
            else { return nil }
            beat += value / pow(10, Double(fraction.count))
        }
        return beat >= 1 ? beat : nil
    }
}
