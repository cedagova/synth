import Foundation

/// An SFZ instrument definition, parsed down to the subset this player renders.
///
/// **The subset is what the curated set actually uses, and nothing more** (AD6,
/// and the plan's `## Instrument source evidence`). Every opcode in the three
/// installed libraries was enumerated before this was written; the ones that
/// affect what a note sounds like are implemented, and the ones that do not are
/// recorded by name so INS003 can show the owner exactly what was ignored. That
/// is the REQ-014 honesty principle applied to instruments: nothing is silently
/// dropped, and an unrecognised opcode is never fatal.
///
/// Parsing is pure. It takes text and returns regions and a report; it opens no
/// files, so a malformed instrument fails at the point where its own text is
/// read rather than somewhere inside the loader.
///
/// ## The two things about real SFZ files that a naive parser gets wrong
///
/// 1. **An opcode value can contain spaces.** VSCO 2 writes
///    `default_path=Strings\Cello Section\susvib\`, and splitting on whitespace
///    truncates it to `Strings\Cello`. A value therefore runs to the start of
///    the next `opcode=` or `<header>`, which is how every real SFZ player
///    reads them and is what makes all 78 installed files resolve.
/// 2. **Paths are written with Windows separators.** Every one of the three
///    libraries does this — Salamander in `sample=`, VSCO 2 and Etherealwinds
///    in `default_path=` — so a backslash is a separator here, not a literal.
public struct SFZDocument: Sendable, Equatable {
    /// Every `<region>`, in file order, with its `<global>`, `<master>` and
    /// `<group>` opcodes already folded in.
    public let regions: [SFZRegion]

    /// Opcodes and headers that were recognised as SFZ but not applied, with
    /// how often each was encountered and why it was not applied.
    ///
    /// INS003 reads this. It is deliberately a report rather than an error:
    /// an instrument that uses one unsupported opcode still plays, and the
    /// owner is owed the difference between "we ignored `ampeg_dynamic`" and
    /// "this instrument is broken".
    public let unsupported: [SFZUnsupportedFeature]

    /// The keyswitch range this instrument reserves, when it has one.
    ///
    /// VSCO 2's `-KS` articulation files put four articulations behind
    /// switches at C2–D#2. A note landing in this range selects an articulation
    /// instead of sounding, which is what stops a keyswitched patch from
    /// playing all four articulations at once.
    public let switchKeyRange: ClosedRange<Int>?

    /// The articulation a voice starts on: `sw_default`, or the first
    /// `sw_last` seen when the file only declares that.
    public let defaultSwitchKey: Int?

    public init(
        regions: [SFZRegion],
        unsupported: [SFZUnsupportedFeature],
        switchKeyRange: ClosedRange<Int>?,
        defaultSwitchKey: Int?
    ) {
        self.regions = regions
        self.unsupported = unsupported
        self.switchKeyRange = switchKeyRange
        self.defaultSwitchKey = defaultSwitchKey
    }
}

// MARK: - Region

/// One `<region>`: a sample, the keys and velocities that reach it, and how it
/// is pitched, shaped and sequenced.
public struct SFZRegion: Sendable, Equatable {
    /// `sample`, joined to the `default_path` in force and normalised to
    /// forward slashes. Relative to the SFZ file's own directory.
    public let samplePath: String

    public var loKey: Int = 0
    public var hiKey: Int = 127
    public var loVelocity: Int = 1
    public var hiVelocity: Int = 127

    /// `pitch_keycenter`. Defaults to 60, as SFZ does.
    public var pitchKeycenter: Int = 60

    /// `tune`/`tuning` in cents plus `transpose` in semitones, as semitones.
    public var tuneSemitones: Double = 0

    /// `pitch_keytrack`/100. 1 tracks the keyboard normally; 0 pins the sample
    /// to its recorded pitch.
    public var pitchKeytrack: Double = 1

    /// `volume`, in decibels.
    public var volumeDecibels: Double = 0

    /// `pan`, -100…100. Parsed and reported rather than applied: the
    /// line-voice interface renders mono and the engine owns pan (PLY003), so a
    /// region cannot place itself in the stereo image. Nothing in the curated
    /// set writes one. See `unsupportedReasons["pan"]`.
    public var pan: Double = 0

    /// `amp_veltrack`/100.
    public var amplitudeVelocityTracking: Double = 1

    public var attackSeconds: Double = 0
    public var decaySeconds: Double = 0
    public var sustainLevel: Double = 1
    public var releaseSeconds: Double = 0

    public enum Trigger: String, Sendable, Equatable {
        case attack, release, first, legato
    }
    public var trigger: Trigger = .attack

    /// `rt_decay`, in decibels per second the note was held.
    public var releaseTriggerDecayDecibelsPerSecond: Double = 0

    public enum LoopMode: String, Sendable, Equatable {
        case noLoop, oneShot, loopContinuous, loopSustain
    }

    /// `loop_mode`. Nil means the file's own loop points decide, which is what
    /// SFZ 1.0 specifies: a sample with loop points loops, one without does
    /// not.
    public var loopMode: LoopMode?
    public var loopStart: Int64?
    public var loopEnd: Int64?

    /// `offset` and `end`, in frames.
    public var sampleOffset: Int64 = 0
    public var sampleEnd: Int64?

    /// `seq_length`/`seq_position`, 1-based.
    public var sequenceLength: Int = 1
    public var sequencePosition: Int = 1

    /// `lorand`/`hirand`.
    public var randomLow: Double = 0
    public var randomHigh: Double = 1

    /// `sw_last`, falling back to `sw_default`, or nil when this region sits
    /// behind no keyswitch.
    public var switchKey: Int?

    public init(samplePath: String) {
        self.samplePath = samplePath
    }
}

// MARK: - Unsupported features

/// One SFZ feature the player recognised and did not apply.
public struct SFZUnsupportedFeature: Sendable, Equatable, Hashable {
    /// The opcode or header, exactly as SFZ spells it.
    public let name: String

    /// How many times it was encountered. An opcode written once on a
    /// `<group>` counts once per region that inherited it, because that is how
    /// many places it would have changed the sound.
    public let occurrences: Int

    /// Why it was not applied, in language that can be shown to the owner.
    public let reason: String

    public init(name: String, occurrences: Int, reason: String) {
        self.name = name
        self.occurrences = occurrences
        self.reason = reason
    }
}

// MARK: - Parsing

extension SFZDocument {
    /// Parse SFZ text.
    ///
    /// Never throws. An SFZ file that says something this player does not
    /// understand still yields the regions it does understand, plus a report —
    /// the alternative would be an instrument that refuses to load because of
    /// one decorative opcode.
    public static func parse(_ text: String) -> SFZDocument {
        var parser = Parser()
        parser.run(text)
        return parser.finish()
    }

    /// Why each recognised-but-unapplied opcode is not applied.
    ///
    /// Kept as data rather than woven into the parser so the whole list can be
    /// read at once, and so a test can assert that every opcode present in the
    /// installed libraries is either implemented or explained here.
    static let unsupportedReasons: [String: String] = [
        "ampeg_dynamic": "an ARIA extension that re-scales the envelope with velocity; the "
            + "envelope follows the written ampeg_attack/decay/sustain/release instead.",
        "ampeg_hold": "a hold segment between attack and decay; the envelope goes straight from "
            + "attack to decay.",
        "ampeg_delay": "a delay before the attack; the note starts immediately.",
        "ampeg_vel2attack": "velocity-scaled attack time; the attack is the written one.",
        "ampeg_vel2release": "velocity-scaled release time; the release is the written one.",
        "group": "an exclusive group, which silences other regions when this one starts. Only "
            + "the pedal-noise layers use it, and those are not started.",
        "off_by": "the other half of an exclusive group; see group.",
        "off_mode": "how an exclusive group silences what it replaces; see group.",
        "on_locc64": "starts a region from a sustain-pedal position rather than a note. The "
            + "pedal-action samples this selects are not played.",
        "on_hicc64": "the other half of a pedal-triggered region; see on_locc64.",
        "pan": "the line-voice interface renders mono and the engine owns pan, mute and solo "
            + "(PLY003), so a region cannot place itself in the stereo image.",
        "width": "stereo width of a region; the interface renders mono.",
        "position": "stereo position of a region; the interface renders mono.",
        "sw_label": "a display name for a keyswitch; the switch itself is honoured.",
        "group_label": "a display name for a group; it does not affect the sound.",
        "polyphony": "a per-region voice limit; the voice's own 128-slot ceiling applies.",
        "cutoff": "a per-region filter; the sampler has no filter, and INS003 owns tone "
            + "customization.",
        "resonance": "a per-region filter; see cutoff.",
        "fil_type": "a per-region filter; see cutoff.",
        "fil_veltrack": "a per-region filter; see cutoff.",
        "bend_up": "pitch-bend range; the performance timeline sends no pitch bend.",
        "bend_down": "pitch-bend range; see bend_up.",
        "delay": "a per-region start delay; the note starts on the frame the timeline asked for.",
        "#include": "an include directive; no installed instrument uses one, so included files "
            + "are not read.",
        "#define": "a macro definition; no installed instrument uses one, so macros are not "
            + "expanded."
    ]

    /// Headers whose contents are skipped whole.
    static let unsupportedHeaderReasons: [String: String] = [
        "<curve>": "a custom modulation curve; the sampler applies no modulation curves.",
        "<effect>": "an instrument-level effect; the mixer and the synthesizer own effects.",
        "<midi>": "MIDI-file triggering; playback is driven by the performance timeline.",
        "<sample>": "an embedded sample definition; samples are read from the library's files."
    ]
}

extension SFZDocument {
    /// The single-pass parser.
    ///
    /// A struct rather than free functions because the inheritance rule needs
    /// four levels of accumulated opcodes at once — control, global, master and
    /// group — and threading those through free functions reads far worse than
    /// naming them.
    private struct Parser {
        /// Opcodes in force at each level. A region's value is the deepest one
        /// set, which is exactly SFZ's inheritance rule.
        private var global: [String: String] = [:]
        private var master: [String: String] = [:]
        private var group: [String: String] = [:]
        private var region: [String: String] = [:]

        /// `default_path` from the `<control>` in force. Resets when a new
        /// `<control>` appears, which is how VSCO 2's `-KS` files give each
        /// articulation its own folder.
        private var defaultPath = ""

        /// Which header the parser is inside. SFZ's inheritance is positional:
        /// an opcode belongs to the most recent header, and a region inherits
        /// from every level above it.
        private enum Level { case global, master, group, region, control }
        private var level: Level = .global

        private var skippingHeader: String?

        private var regions: [SFZRegion] = []
        private var unsupportedCounts: [String: Int] = [:]
        private var switchLow: Int?
        private var switchHigh: Int?
        private var switchDefault: Int?

        mutating func run(_ text: String) {
            for token in SFZTokenizer.tokens(in: text) {
                switch token {
                case .header(let name):
                    apply(header: name)
                case .opcode(let name, let value):
                    apply(opcode: name, value: value)
                case .directive(let name):
                    unsupportedCounts[name, default: 0] += 1
                }
            }
            closeRegion()
        }

        private mutating func apply(header name: String) {
            closeRegion()

            if SFZDocument.unsupportedHeaderReasons[name] != nil {
                unsupportedCounts[name, default: 0] += 1
                skippingHeader = name
                return
            }
            skippingHeader = nil

            switch name {
            case "<control>":
                // A second `<control>` replaces the first: that is how VSCO 2's
                // keyswitched files give each articulation its own folder.
                defaultPath = ""
                level = .control
            case "<global>":
                global = [:]; master = [:]; group = [:]
                level = .global
            case "<master>":
                master = [:]; group = [:]
                level = .master
            case "<group>":
                group = [:]
                level = .group
            case "<region>":
                region = [:]
                level = .region
            default:
                // An unknown header is not a reason to stop reading a file that
                // is otherwise fine; note it and keep going.
                unsupportedCounts[name, default: 0] += 1
            }
        }

        private mutating func apply(opcode name: String, value: String) {
            if skippingHeader != nil { return }

            if name == "default_path" {
                defaultPath = SFZTokenizer.normalizingSeparators(value)
                if !defaultPath.isEmpty, !defaultPath.hasSuffix("/") { defaultPath += "/" }
                return
            }

            // Keyswitch ranges are instrument-wide: a file declares the same
            // range on every group, and what matters downstream is the union.
            switch name {
            case "sw_lokey":
                if let key = SFZValue.key(value) { switchLow = min(switchLow ?? key, key) }
            case "sw_hikey":
                if let key = SFZValue.key(value) { switchHigh = max(switchHigh ?? key, key) }
            case "sw_default":
                if let key = SFZValue.key(value), switchDefault == nil { switchDefault = key }
            default:
                break
            }

            switch level {
            case .region: region[name] = value
            case .group: group[name] = value
            case .master: master[name] = value
            case .global: global[name] = value
            case .control:
                // `<control>` carries `default_path` and the macro directives.
                // Anything else there is not an instrument setting.
                unsupportedCounts[name, default: 0] += 1
            }
        }

        private mutating func closeRegion() {
            guard level == .region else { return }
            level = .group

            var resolved = global
            for (key, value) in master { resolved[key] = value }
            for (key, value) in group { resolved[key] = value }
            for (key, value) in region { resolved[key] = value }

            guard let rawSample = resolved["sample"], !rawSample.isEmpty else {
                // A region with no sample plays nothing; SFZ allows it as a
                // way of carrying opcodes, and it is not an error.
                return
            }

            let path = defaultPath + SFZTokenizer.normalizingSeparators(rawSample)
            var built = SFZRegion(samplePath: path)

            for (name, value) in resolved {
                if name == "sample" { continue }
                if !apply(name: name, value: value, to: &built) {
                    unsupportedCounts[name, default: 0] += 1
                }
            }

            // `sw_last` is the region's own articulation; a file that only
            // declares `sw_default` puts every region on that one.
            if built.switchKey == nil, let fallback = switchDefault,
               resolved["sw_lokey"] != nil || resolved["sw_hikey"] != nil {
                built.switchKey = fallback
            }

            regions.append(built)
        }

        /// Apply one resolved opcode. Returns false when it is not part of the
        /// subset, which is what puts it in the report.
        private func apply(name: String, value: String, to region: inout SFZRegion) -> Bool {
            switch name {
            case "lokey": region.loKey = SFZValue.key(value) ?? region.loKey
            case "hikey": region.hiKey = SFZValue.key(value) ?? region.hiKey
            case "key":
                if let key = SFZValue.key(value) {
                    region.loKey = key
                    region.hiKey = key
                    region.pitchKeycenter = key
                }
            case "lovel": region.loVelocity = SFZValue.integer(value) ?? region.loVelocity
            case "hivel": region.hiVelocity = SFZValue.integer(value) ?? region.hiVelocity
            case "pitch_keycenter":
                region.pitchKeycenter = SFZValue.key(value) ?? region.pitchKeycenter
            case "tune", "tuning":
                region.tuneSemitones += (SFZValue.number(value) ?? 0) / 100
            case "transpose":
                region.tuneSemitones += SFZValue.number(value) ?? 0
            case "pitch_keytrack":
                region.pitchKeytrack = (SFZValue.number(value) ?? 100) / 100
            case "volume": region.volumeDecibels = SFZValue.number(value) ?? 0
            case "amp_veltrack":
                region.amplitudeVelocityTracking = (SFZValue.number(value) ?? 100) / 100
            case "ampeg_attack": region.attackSeconds = max(0, SFZValue.number(value) ?? 0)
            case "ampeg_decay": region.decaySeconds = max(0, SFZValue.number(value) ?? 0)
            case "ampeg_sustain":
                region.sustainLevel = min(max((SFZValue.number(value) ?? 100) / 100, 0), 1)
            case "ampeg_release": region.releaseSeconds = max(0, SFZValue.number(value) ?? 0)
            case "trigger":
                region.trigger = SFZRegion.Trigger(rawValue: value.lowercased()) ?? .attack
            case "rt_decay":
                region.releaseTriggerDecayDecibelsPerSecond = max(0, SFZValue.number(value) ?? 0)
            case "loop_mode", "loopmode":
                region.loopMode = SFZValue.loopMode(value)
            case "loop_start", "loopstart":
                region.loopStart = SFZValue.frame(value)
            case "loop_end", "loopend":
                region.loopEnd = SFZValue.frame(value)
            case "offset": region.sampleOffset = max(0, SFZValue.frame(value) ?? 0)
            case "end": region.sampleEnd = SFZValue.frame(value)
            case "seq_length": region.sequenceLength = max(1, SFZValue.integer(value) ?? 1)
            case "seq_position": region.sequencePosition = max(1, SFZValue.integer(value) ?? 1)
            case "lorand": region.randomLow = SFZValue.number(value) ?? 0
            case "hirand": region.randomHigh = SFZValue.number(value) ?? 1
            case "sw_last": region.switchKey = SFZValue.key(value)
            case "sw_lokey", "sw_hikey", "sw_default":
                // Instrument-wide; already folded in above and not a per-region
                // setting, so this is neither applied here nor unsupported.
                break
            default:
                return false
            }
            return true
        }

        func finish() -> SFZDocument {
            let unsupported = unsupportedCounts
                .map { name, count in
                    SFZUnsupportedFeature(
                        name: name,
                        occurrences: count,
                        reason: SFZDocument.unsupportedReasons[name]
                            ?? SFZDocument.unsupportedHeaderReasons[name]
                            ?? "not part of the SFZ subset this player implements."
                    )
                }
                .sorted { $0.name < $1.name }

            var range: ClosedRange<Int>?
            if let low = switchLow, let high = switchHigh, low <= high { range = low...high }

            return SFZDocument(
                regions: regions,
                unsupported: unsupported,
                switchKeyRange: range,
                defaultSwitchKey: switchDefault
            )
        }
    }
}

// MARK: - Tokenizer

/// Splits SFZ text into headers, opcodes and directives.
///
/// Separated from the parser because the one genuinely subtle rule in the SFZ
/// format lives here — where an opcode's value ends — and it is worth being
/// able to test that rule on its own.
enum SFZTokenizer {
    enum Token: Equatable {
        case header(String)
        case opcode(name: String, value: String)
        /// `#include`, `#define`: reported, never acted on.
        case directive(String)
    }

    static func tokens(in text: String) -> [Token] {
        let stripped = strippingComments(from: text)
        let characters = Array(stripped.unicodeScalars)

        // Where each header and each `name=` starts. A value runs from its `=`
        // to whichever of these comes next, which is what lets a value contain
        // spaces without swallowing the opcode that follows it.
        var marks: [(start: Int, kind: Mark)] = []
        var index = 0
        while index < characters.count {
            let scalar = characters[index]
            if scalar == "<" {
                if let close = closingAngle(characters, from: index) {
                    marks.append((index, .header(String(String.UnicodeScalarView(
                        characters[index...close])).lowercased())))
                    index = close + 1
                    continue
                }
            } else if scalar == "#", isAtLineStart(characters, index) {
                // `#` only begins a directive at the start of a line. Anywhere
                // else it is a sharp: `hikey=d#2` and `sw_last=c#2` are all over
                // VSCO 2, and reading their `#` as a directive truncates the
                // note name to `d` and silently loses the mapping.
                var end = index + 1
                while end < characters.count, isWord(characters[end]) { end += 1 }
                marks.append((index, .directive(String(String.UnicodeScalarView(
                    characters[index..<end])).lowercased())))
                index = end
                continue
            } else if isWordStart(scalar) {
                var end = index
                while end < characters.count, isWord(characters[end]) { end += 1 }
                if end < characters.count, characters[end] == "=" {
                    let name = String(String.UnicodeScalarView(characters[index..<end]))
                    marks.append((index, .name(name.lowercased(), valueStart: end + 1)))
                    index = end + 1
                    continue
                }
                index = end
                continue
            }
            index += 1
        }

        var tokens: [Token] = []
        tokens.reserveCapacity(marks.count)
        for (position, mark) in marks.enumerated() {
            switch mark.kind {
            case .header(let name):
                tokens.append(.header(name))
            case .directive(let name):
                tokens.append(.directive(name))
            case .name(let name, let valueStart):
                let end = position + 1 < marks.count ? marks[position + 1].start : characters.count
                let value = String(String.UnicodeScalarView(
                    characters[valueStart..<max(valueStart, end)]
                )).trimmingCharacters(in: .whitespacesAndNewlines)
                tokens.append(.opcode(name: name, value: value))
            }
        }
        return tokens
    }

    private enum Mark {
        case header(String)
        case directive(String)
        case name(String, valueStart: Int)
    }

    private static func closingAngle(_ characters: [Unicode.Scalar], from index: Int) -> Int? {
        var cursor = index + 1
        while cursor < characters.count, cursor - index < 32 {
            if characters[cursor] == ">" { return cursor }
            if !isWord(characters[cursor]) { return nil }
            cursor += 1
        }
        return nil
    }

    /// True when only whitespace stands between `index` and the previous
    /// newline.
    private static func isAtLineStart(_ characters: [Unicode.Scalar], _ index: Int) -> Bool {
        var cursor = index - 1
        while cursor >= 0 {
            let scalar = characters[cursor]
            if scalar == "\n" || scalar == "\r" { return true }
            if scalar != " " && scalar != "\t" { return false }
            cursor -= 1
        }
        return true
    }

    private static func isWordStart(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || scalar == "_"
    }

    private static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        isWordStart(scalar) || (scalar >= "0" && scalar <= "9")
    }

    /// Remove `//` line comments and `/* */` blocks.
    static func strippingComments(from text: String) -> String {
        var output = String.UnicodeScalarView()
        var scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil
            if scalar == "/", next == "/" {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
                continue
            }
            if scalar == "/", next == "*" {
                index += 2
                while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") {
                    index += 1
                }
                index += 2
                continue
            }
            output.append(scalar)
            index += 1
        }
        scalars = []
        return String(output)
    }

    /// Windows separators become POSIX ones, and a leading `./` is dropped.
    ///
    /// Every installed library writes at least some paths with backslashes, so
    /// this is not a compatibility nicety: without it, none of the three loads
    /// on macOS.
    static func normalizingSeparators(_ path: String) -> String {
        var result = path.replacingOccurrences(of: "\\", with: "/")
        while result.hasPrefix("./") { result.removeFirst(2) }
        return result
    }
}

// MARK: - Values

/// SFZ's value syntaxes: numbers, frame counts, note names and loop modes.
enum SFZValue {
    static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces))
    }

    static func integer(_ text: String) -> Int? {
        if let value = Int(text.trimmingCharacters(in: .whitespaces)) { return value }
        guard let value = number(text) else { return nil }
        return Int(value.rounded())
    }

    static func frame(_ text: String) -> Int64? {
        guard let value = integer(text) else { return nil }
        return Int64(value)
    }

    static func loopMode(_ text: String) -> SFZRegion.LoopMode? {
        switch text.lowercased() {
        case "no_loop": return .noLoop
        case "one_shot": return .oneShot
        case "loop_continuous": return .loopContinuous
        case "loop_sustain": return .loopSustain
        default: return nil
        }
    }

    /// A key: either a MIDI number, or a note name such as `c4`, `d#2`, `a-1`.
    ///
    /// `c4` is 60, which is the convention SFZ and every library in the curated
    /// set use. VSCO 2's keyswitches are written `c2`…`d#2` and land at 36…39,
    /// well below the flute's playable range — which is the check that this
    /// octave numbering is the right one.
    static func key(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let value = Int(trimmed) { return value }

        var scalars = Array(trimmed.unicodeScalars)
        guard !scalars.isEmpty else { return nil }

        let semitones: [Unicode.Scalar: Int] = [
            "c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11
        ]
        guard let base = semitones[scalars.removeFirst()] else { return nil }

        var accidental = 0
        while let first = scalars.first, first == "#" || first == "b" {
            accidental += first == "#" ? 1 : -1
            scalars.removeFirst()
        }

        let octaveText = String(String.UnicodeScalarView(scalars))
        guard let octave = Int(octaveText) else { return nil }
        return (octave + 1) * 12 + base + accidental
    }
}
