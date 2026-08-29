import Foundation

/// Everything the assignment and mixer surface says, as pure functions.
///
/// The same split `TransportDisplay` uses, and for the same reason: a sentence
/// assembled inside a SwiftUI `body` cannot be tested, and a mixer strip is
/// exactly where that matters — its spoken form is REQ-027 acceptance, and its
/// decibel mapping is the difference between a slider that behaves like a fader
/// and one that behaves like a ratio.
///
/// **Nothing here writes anything.** ASN001 owns the preset model; this owns
/// how it reads.
public enum AssignmentDisplay {

    // MARK: Volume, as a fader

    /// The bottom of the fader. Below this the line is silent rather than very
    /// quiet, because a fader that bottoms out at "almost nothing" is a fader
    /// the owner cannot use to turn a line off.
    public static let minimumDecibels: Double = -60

    /// The top. `LineMixerState.maximumVolume` is 8, which is +18.06 dB, so
    /// +18 is the largest whole decibel the store will accept.
    public static let maximumDecibels: Double = 18

    /// What one press of Louder or Quieter moves.
    public static let decibelStep: Double = 3

    /// What one press of Pan Left or Pan Right moves.
    public static let panStep: Double = 0.1

    /// What one press of More Room or Less Room moves (D7).
    public static let roomSendStep: Double = 0.1

    /// The fader position for a stored linear gain.
    public static func decibels(forVolume volume: Double) -> Double {
        guard volume > 0 else { return minimumDecibels }
        return min(max(20 * log10(volume), minimumDecibels), maximumDecibels)
    }

    /// The linear gain for a fader position. The bottom of the travel is
    /// silence, not −60 dB of it.
    public static func volume(forDecibels decibels: Double) -> Double {
        guard decibels > minimumDecibels else { return 0 }
        let clamped = min(decibels, maximumDecibels)
        return min(pow(10, clamped / 20), LineMixerState.maximumVolume)
    }

    /// `-6.0 dB`, `0.0 dB`, `Silent`.
    public static func volumeText(_ volume: Double) -> String {
        guard volume > 0 else { return "Silent" }
        return String(format: "%.1f dB", decibels(forVolume: volume))
    }

    /// What VoiceOver says a volume slider is set to. Spelled out, because
    /// "minus six point zero d B" is not a sentence.
    public static func spokenVolume(_ volume: Double) -> String {
        guard volume > 0 else { return "silent" }
        let value = decibels(forVolume: volume)
        if abs(value) < 0.05 { return "unity" }
        let magnitude = String(format: "%.1f", abs(value))
        return value < 0 ? "\(magnitude) decibels down" : "\(magnitude) decibels up"
    }

    // MARK: Pan

    /// `Centre`, `L60`, `R100` — the short form a strip has room for.
    public static func panText(_ pan: Double) -> String {
        let percent = Int((abs(pan) * 100).rounded())
        guard percent > 0 else { return "Centre" }
        return pan < 0 ? "L\(percent)" : "R\(percent)"
    }

    /// …and the long form VoiceOver reads.
    public static func spokenPan(_ pan: Double) -> String {
        let percent = Int((abs(pan) * 100).rounded())
        guard percent > 0 else { return "centre" }
        let side = pan < 0 ? "left" : "right"
        return percent >= 100 ? "hard \(side)" : "\(percent) percent \(side)"
    }

    // MARK: Where a line's sound came from

    /// The note a strip shows beside the sound's name when it is not simply a
    /// live library reference, or nil when it is.
    ///
    /// REQ-029 asks for the embedded case to be visible; the missing case is
    /// visible for the same reason — the line is playing something the owner
    /// did not choose, and it must not do that silently.
    public static func sourceNote(_ source: ResolvedSoundSource) -> String? {
        switch source {
        case .library:
            return nil
        case .embedded(_, let name):
            return "Embedded copy of “\(name)” — the sound it came from was deleted."
        case .missing:
            return "That sound is no longer in your library, so this line is playing "
                + "Synth's default voice."
        case .instrumentNotInstalled:
            // Deliberately silent here: `LineInstrumentAdvice` already writes
            // the sentence for this case, and it says considerably more than
            // this function could — which library to download, and what the
            // line is doing meanwhile. Two notes on one strip would be one
            // note too many.
            return nil
        }
    }

    // MARK: The instrument flags (issue #24)

    /// Every sentence a line's flags contribute, in order.
    ///
    /// One string per flag rather than one joined paragraph, so the panel can
    /// draw each with its own badge and VoiceOver reads them as separate
    /// statements rather than as a run-on.
    public static func adviceNotes(_ line: ResolvedLine) -> [String] {
        line.advice.map(\.explanation)
    }

    /// The label for the button that accepts a substitute on this line, or nil
    /// when there is nothing to offer.
    public static func substitutionOffer(_ line: ResolvedLine) -> String? {
        guard line.canOfferSubstitution, let substitute = line.substitute else { return nil }
        return "Play “\(substitute.name)” here meanwhile"
    }

    /// The label for the button that takes a substitute back off a line.
    public static func substitutionWithdrawal(_ line: ResolvedLine) -> String? {
        guard line.acceptsSubstitution, let substitute = line.substitute else { return nil }
        return "Stop playing “\(substitute.name)” here"
    }

    // MARK: Room send (D7)

    /// `Dry`, `Room 40%` — the short form a strip has room for.
    public static func roomSendText(_ send: Double) -> String {
        let percent = Int((send * 100).rounded())
        return percent <= 0 ? "Dry" : "Room \(percent)%"
    }

    /// …and the long form VoiceOver reads.
    public static func spokenRoomSend(_ send: Double) -> String {
        let percent = Int((send * 100).rounded())
        return percent <= 0 ? "dry, no room" : "\(percent) percent to the room"
    }

    // MARK: A whole strip

    /// One sentence for one mixer strip.
    ///
    /// Built on `ResolvedLine.accessibilityDescription`, which ASN001 wrote for
    /// exactly this, plus the values a strip has that a line does not.
    public static func spokenStrip(_ line: ResolvedLine) -> String {
        "\(line.accessibilityDescription). Volume \(spokenVolume(line.mixer.volume)), "
            + "pan \(spokenPan(line.mixer.pan)), \(spokenRoomSend(line.mixer.roomSend))."
    }

    // MARK: The mix as a whole

    /// True when this line is routed to the output: mute wins over solo, and an
    /// unsoloed line is silent while anything is soloed.
    ///
    /// The engine's rule, restated here so the panel can say how the mixer is
    /// set without asking the render thread. **Routed is not the same as
    /// heard** — see `isHeard` below — and the two were the same thing only
    /// while every line had a sound it could actually play.
    public static func isRouted(_ line: ResolvedLine, whileSoloing isSoloing: Bool) -> Bool {
        if line.mixer.isMuted { return false }
        return isSoloing ? line.mixer.isSoloed : true
    }

    /// True when this line is producing sound.
    ///
    /// **Routed *and* able to play.** A line whose instrument is not
    /// downloaded is routed — nothing is muted and nothing is soloed over it —
    /// and produces nothing, because issue #24 requires exactly that rather
    /// than a substitute the owner did not ask for. Counting it as heard was
    /// this summary telling the owner six lines were sounding while the banner
    /// directly above it named one of them as silent.
    public static func isHeard(_ line: ResolvedLine, whileSoloing isSoloing: Bool) -> Bool {
        isRouted(line, whileSoloing: isSoloing) && !line.isSilent
    }

    public static func isSoloing(_ lines: [ResolvedLine]) -> Bool {
        lines.contains { $0.mixer.isSoloed }
    }

    public static func audibleLineCount(_ lines: [ResolvedLine]) -> Int {
        let soloing = isSoloing(lines)
        return lines.count { isHeard($0, whileSoloing: soloing) }
    }

    /// Lines that are routed but producing nothing, because the sound they were
    /// given is not available to play.
    public static func silentLineCount(_ lines: [ResolvedLine]) -> Int {
        let soloing = isSoloing(lines)
        return lines.count { isRouted($0, whileSoloing: soloing) && $0.isSilent }
    }

    /// `4 lines · 1 soloed · 1 heard`, and `6 lines · 1 silent · 5 heard` when a
    /// line is routed and has nothing to play.
    ///
    /// **The one line that says whether what the owner is hearing is what they
    /// think they are hearing** — which is why the silent count is here and not
    /// only on the line. Until increment 005 a routed line always sounded, so
    /// "heard" and "routed" were the same number; a line whose instrument is
    /// missing is deliberately routed and deliberately silent, and folding it
    /// into "heard" made this sentence contradict the banner above it.
    public static func mixSummary(_ lines: [ResolvedLine]) -> String {
        guard !lines.isEmpty else { return "No lines." }

        var parts = ["\(lines.count) line\(lines.count == 1 ? "" : "s")"]
        let soloed = lines.count { $0.mixer.isSoloed }
        if soloed > 0 { parts.append("\(soloed) soloed") }
        let muted = lines.count { $0.mixer.isMuted }
        if muted > 0 { parts.append("\(muted) muted") }
        let silent = silentLineCount(lines)
        if silent > 0 { parts.append("\(silent) silent") }
        parts.append("\(audibleLineCount(lines)) heard")
        return parts.joined(separator: " · ")
    }

    // MARK: Presets

    /// REQ-024's auto-save indication. There is no Save button because there is
    /// nothing to save: every change is one committed transaction, and the
    /// revision is the proof it happened.
    public static func autoSaveText(_ preset: Preset?) -> String {
        guard let preset else { return "No preset yet." }
        return "Saved automatically — “\(preset.name)”, revision \(preset.revision)."
    }

    /// What VoiceOver says the preset chooser is.
    public static func spokenPreset(_ preset: Preset?, of total: Int) -> String {
        guard let preset else { return "No preset" }
        let position = total <= 1 ? "the only preset" : "one of \(total) presets"
        return "\(preset.name), active, \(position)"
    }
}
