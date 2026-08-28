import Foundation

// MARK: - Line identity

/// A stable identifier for one independent line of a piece.
///
/// **This value is a contract.** Presets (increment 004) store per-line
/// assignment, volume, pan, mute and solo against it, and export (increment
/// 006) reproduces a mix from it. It must therefore be identical every time
/// the same stored file is compiled, on every launch and every build.
///
/// It is derived only from what MusicXML says is *the identity of the line* —
/// the part's `id`, the staff, and the voice — and never from anything
/// positional. Adding measures, reordering parts, correcting metadata, or
/// changing this compiler's internals cannot renumber a line, because none of
/// those things appear in the derivation.
///
/// The readable prefix exists so a preset row is inspectable by eye; the hash
/// suffix exists so two different raw triples can never collapse onto one
/// identifier after the prefix is sanitised.
public struct ScoreLineID: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Derives the identifier for `(partID, staff, voice)`.
    public init(partID: String, staff: Int, voice: String) {
        let canonical = "part=\(partID)\u{1F}staff=\(staff)\u{1F}voice=\(voice)"
        let readable = "\(Self.sanitize(partID))-s\(staff)-v\(Self.sanitize(voice))"
        self.rawValue = "\(readable)-\(Self.shortDigest(canonical))"
    }

    public var description: String { rawValue }

    public static func < (lhs: ScoreLineID, rhs: ScoreLineID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// ASCII letters, digits, and `_`; everything else folds to `_`. An empty
    /// or fully-folded value becomes `x` so the readable prefix is never blank.
    private static func sanitize(_ value: String) -> String {
        let folded = String(value.unicodeScalars.map { scalar -> Character in
            let isAllowed = (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "_"
            return isAllowed ? Character(scalar) : "_"
        })
        let trimmed = folded.prefix(24)
        return trimmed.allSatisfy { $0 == "_" } ? "x" : String(trimmed)
    }

    /// First 8 hex characters of the SHA-256 of the exact raw triple.
    private static func shortDigest(_ value: String) -> String {
        String(SHA256Digest.hexString(Data(value.utf8)).prefix(8))
    }
}

// MARK: - Pitch

/// A sounding pitch, as the score notates it.
public struct ScorePitch: Equatable, Sendable, Codable {
    /// `C` through `B`.
    public let step: String

    /// Semitone alteration: -1 flat, +1 sharp, 0 natural. Microtones round
    /// toward zero into this field and are reported.
    public let alter: Int

    /// MusicXML octave, where octave 4 holds middle C.
    public let octave: Int

    public init(step: String, alter: Int, octave: Int) {
        self.step = step
        self.alter = alter
        self.octave = octave
    }

    private static let semitones: [String: Int] = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11
    ]

    /// Standard MIDI note number (middle C = 60), or nil for an unrecognised
    /// step letter or a value outside the notatable range.
    public var midiNoteNumber: Int? {
        guard let base = Self.semitones[step.uppercased()],
              (-2...12).contains(octave),
              abs(alter) <= 24
        else { return nil }
        return (octave + 1) * 12 + base + alter
    }
}

// MARK: - Notes and lines

/// One notated event on a line: a sounding note, or a rest.
///
/// Positions are expressed against the note's **source** measure, not the
/// playback timeline. A measure that repeats is played several times from one
/// set of notes, so binding notes to source positions is what keeps the model
/// small and the expansion honest.
public struct ScoreNote: Equatable, Sendable, Codable {
    /// Index into `CompiledScore.sourceMeasures`.
    public let sourceMeasureIndex: Int

    /// Onset in ticks from the start of that measure.
    public let startTicks: Int

    /// Sounding length in ticks.
    public let durationTicks: Int

    /// nil for a rest.
    public let pitch: ScorePitch?

    /// True when this note sounds together with the preceding note on the
    /// same line rather than after it.
    public let isChordMember: Bool

    /// `<tie type="start">`: this note continues into the next one.
    public let tiesForward: Bool

    /// `<tie type="stop">`: this note is the continuation of the previous one.
    public let tiesBackward: Bool

    /// A fermata is attached here, so the tempo map holds over its span.
    public let hasFermata: Bool

    /// Articulations printed on this note, in canonical order.
    public let articulations: [ScoreArticulation]

    /// Ornaments printed on this note, in canonical order. More than one is
    /// unusual but legal; the realizer sounds the first and reports the rest.
    public let ornaments: [ScoreOrnament]

    /// Grace notes printed before this note, in the order they are played.
    public let graceNotes: [ScoreGraceNote]

    /// How many slurs open on this note. Nested slurs are counted rather than
    /// flattened so a phrase inside a phrase does not close early.
    public let slurStartCount: Int

    /// How many slurs close on this note.
    public let slurStopCount: Int

    /// Dynamics printed inside this note's `<notations>`, in canonical order.
    /// A dynamic printed as a `<direction>` instead lives in
    /// `CompiledScore.expressionEvents`, because it governs a whole staff.
    public let dynamics: [ScoreDynamic]

    public var isRest: Bool { pitch == nil }

    /// Onset plus duration, still within the source measure.
    public var endTicks: Int { startTicks + durationTicks }

    /// True when this note carries anything the realizer has to shape.
    public var hasExpression: Bool {
        !articulations.isEmpty || !ornaments.isEmpty || !graceNotes.isEmpty
            || slurStartCount > 0 || slurStopCount > 0 || !dynamics.isEmpty
    }

    public init(
        sourceMeasureIndex: Int,
        startTicks: Int,
        durationTicks: Int,
        pitch: ScorePitch?,
        isChordMember: Bool = false,
        tiesForward: Bool = false,
        tiesBackward: Bool = false,
        hasFermata: Bool = false,
        articulations: [ScoreArticulation] = [],
        ornaments: [ScoreOrnament] = [],
        graceNotes: [ScoreGraceNote] = [],
        slurStartCount: Int = 0,
        slurStopCount: Int = 0,
        dynamics: [ScoreDynamic] = []
    ) {
        self.sourceMeasureIndex = sourceMeasureIndex
        self.startTicks = startTicks
        self.durationTicks = durationTicks
        self.pitch = pitch
        self.isChordMember = isChordMember
        self.tiesForward = tiesForward
        self.tiesBackward = tiesBackward
        self.hasFermata = hasFermata
        self.articulations = articulations
        self.ornaments = ornaments
        self.graceNotes = graceNotes
        self.slurStartCount = slurStartCount
        self.slurStopCount = slurStopCount
        self.dynamics = dynamics
    }
}

/// One independent line of the piece — what REQ-005 calls a line and what a
/// preset assigns a sound to.
///
/// A line is `(part, staff, voice)`. In a keyboard fugue that yields one line
/// per fugal voice; in a string quartet, one per instrument.
public struct ScoreLine: Equatable, Sendable, Codable {
    public let id: ScoreLineID

    /// `score-part/@id` this line belongs to.
    public let partID: String

    /// `part-name`, when the score gives one.
    public let partName: String?

    /// MusicXML staff number within the part (1 for a single-staff part).
    public let staff: Int

    /// MusicXML voice token, kept as written because it is part of identity.
    public let voice: String

    /// Human-readable default name, e.g. `Violin I` or `Piano, staff 2,
    /// voice 5`. The owner may rename a line later (increment 004); this is
    /// only the default.
    public let name: String

    /// Notes and rests in source order: measure index, then onset, then
    /// declaration order.
    public let notes: [ScoreNote]

    public init(
        id: ScoreLineID,
        partID: String,
        partName: String?,
        staff: Int,
        voice: String,
        name: String,
        notes: [ScoreNote]
    ) {
        self.id = id
        self.partID = partID
        self.partName = partName
        self.staff = staff
        self.voice = voice
        self.name = name
        self.notes = notes
    }
}

// MARK: - Measures

/// A time signature in force.
public struct TimeSignature: Equatable, Sendable, Codable {
    public let beats: Int
    public let beatType: Int

    public init(beats: Int, beatType: Int) {
        self.beats = beats
        self.beatType = beatType
    }

    /// Length of one notated beat in ticks.
    public func beatTicks(ticksPerQuarter: Int) -> Int {
        max(1, ticksPerQuarter * 4 / max(1, beatType))
    }
}

/// One measure as the score notates it, before repeats are expanded.
public struct SourceMeasure: Equatable, Sendable, Codable {
    /// 0-based document order. This, not `number`, is the model's key: real
    /// scores reuse and skip printed numbers.
    public let index: Int

    /// The printed number, verbatim (`1`, `12a`, `0` for a pickup).
    public let number: String

    /// `<measure implicit="yes">`: a pickup or other unnumbered measure.
    public let isPickup: Bool

    /// Length in ticks, taken from the longest content any part writes in it,
    /// so pickups and irregular measures stay correct.
    public let durationTicks: Int

    /// Time signature in force here.
    public let timeSignature: TimeSignature?

    /// Key signature in force here, in fifths (-7…7).
    public let keyFifths: Int?

    public init(
        index: Int,
        number: String,
        isPickup: Bool,
        durationTicks: Int,
        timeSignature: TimeSignature?,
        keyFifths: Int?
    ) {
        self.index = index
        self.number = number
        self.isPickup = isPickup
        self.durationTicks = durationTicks
        self.timeSignature = timeSignature
        self.keyFifths = keyFifths
    }
}

/// One measure as it is actually played, after repeats, endings and jumps.
///
/// The playback sequence is the piece's real timeline: transport position,
/// looping and export all read it. `sourceMeasureIndex` points back at the
/// notes to sound, and `pass` says which time through this is.
public struct PlaybackMeasure: Equatable, Sendable, Codable {
    /// Position in playback order, 0-based.
    public let index: Int

    /// Index into `CompiledScore.sourceMeasures`.
    public let sourceMeasureIndex: Int

    /// 1 the first time this source measure is played, 2 the second, and so on.
    public let pass: Int

    /// Absolute onset in ticks from the start of playback.
    public let startTicks: Int

    /// Length in ticks (equal to the source measure's).
    public let durationTicks: Int

    public var endTicks: Int { startTicks + durationTicks }

    public init(
        index: Int,
        sourceMeasureIndex: Int,
        pass: Int,
        startTicks: Int,
        durationTicks: Int
    ) {
        self.index = index
        self.sourceMeasureIndex = sourceMeasureIndex
        self.pass = pass
        self.startTicks = startTicks
        self.durationTicks = durationTicks
    }
}

// MARK: - Compiled score

/// A stored piece, compiled.
///
/// Everything here is a pure function of the verbatim MusicXML bytes and the
/// piece's identifier: no clock, nothing drawn by chance, no environment. Two
/// compilations of the same file produce the same value, and
/// `canonicalData()` proves it byte for byte.
public struct CompiledScore: Equatable, Sendable, Codable {
    /// Library identity of the piece this was compiled from.
    public let pieceID: String

    /// SHA-256 of the exact bytes compiled. Pins the model to its source, so
    /// a stale cached model can always be detected.
    public let contentSHA256: String

    /// Tick resolution: how many ticks make one quarter note. Chosen so every
    /// `divisions` value in the document divides it exactly.
    public let ticksPerQuarter: Int

    /// Title as the score declares it, when it declares one.
    public let workTitle: String?

    /// Independent lines, ordered by part appearance, then staff, then voice.
    public let lines: [ScoreLine]

    /// Measures as notated.
    public let sourceMeasures: [SourceMeasure]

    /// Measures as played, after structural expansion.
    public let playbackMeasures: [PlaybackMeasure]

    /// Tick-to-time mapping over the playback timeline.
    public let tempoMap: TempoMap

    /// Dynamics, hairpins and pedal markings, bound to the source measure they
    /// are printed in and sorted into a canonical order.
    public let expressionEvents: [ScoreExpressionEvent]

    /// Everything the compiler met and did not honour, plus every structural
    /// fallback it had to apply.
    public let report: NotationReport

    public init(
        pieceID: String,
        contentSHA256: String,
        ticksPerQuarter: Int,
        workTitle: String?,
        lines: [ScoreLine],
        sourceMeasures: [SourceMeasure],
        playbackMeasures: [PlaybackMeasure],
        tempoMap: TempoMap,
        expressionEvents: [ScoreExpressionEvent] = [],
        report: NotationReport
    ) {
        self.pieceID = pieceID
        self.contentSHA256 = contentSHA256
        self.ticksPerQuarter = ticksPerQuarter
        self.workTitle = workTitle
        self.lines = lines
        self.sourceMeasures = sourceMeasures
        self.playbackMeasures = playbackMeasures
        self.tempoMap = tempoMap
        self.expressionEvents = expressionEvents
        self.report = report
    }

    /// Total playback length in ticks.
    public var totalTicks: Int { playbackMeasures.last?.endTicks ?? 0 }

    /// Total playback length in microseconds.
    public var totalMicroseconds: Int64 { tempoMap.totalMicroseconds }

    /// The line with this identifier, or nil.
    public func line(withID id: ScoreLineID) -> ScoreLine? {
        lines.first { $0.id == id }
    }

    /// The canonical byte form of this model.
    ///
    /// Sorted keys and no floating-point anywhere in the model mean two
    /// compilations of one file produce identical bytes — which is how the
    /// determinism criterion is checked rather than asserted.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - Position

/// Where a moment in playback falls in the score, for transport display
/// (REQ-009).
public struct ScorePosition: Equatable, Sendable {
    /// Index into `playbackMeasures`.
    public let playbackMeasureIndex: Int

    /// Index into `sourceMeasures`.
    public let sourceMeasureIndex: Int

    /// The measure's printed number.
    public let measureNumber: String

    /// Which time through this measure is being played.
    public let pass: Int

    /// Ticks elapsed since the measure began.
    public let tickInMeasure: Int

    /// 1-based notated beat, fractional between beats. Display only — the
    /// model itself stays integral.
    public let beat: Double
}

extension CompiledScore {
    /// Where `ticks` from the start of playback lands, or nil past the end.
    public func position(atPlaybackTicks ticks: Int) -> ScorePosition? {
        guard ticks >= 0, let last = playbackMeasures.last, ticks < last.endTicks else { return nil }

        // Binary search: an orchestral score with heavy repeats can run to
        // thousands of playback measures and the transport asks per frame.
        var low = 0
        var high = playbackMeasures.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if playbackMeasures[middle].startTicks <= ticks {
                low = middle
            } else {
                high = middle - 1
            }
        }

        let measure = playbackMeasures[low]
        let source = sourceMeasures[measure.sourceMeasureIndex]
        let offset = ticks - measure.startTicks
        let beatTicks = source.timeSignature?.beatTicks(ticksPerQuarter: ticksPerQuarter)
            ?? ticksPerQuarter
        return ScorePosition(
            playbackMeasureIndex: measure.index,
            sourceMeasureIndex: measure.sourceMeasureIndex,
            measureNumber: source.number,
            pass: measure.pass,
            tickInMeasure: offset,
            beat: 1.0 + Double(offset) / Double(max(1, beatTicks))
        )
    }

    /// Where `microseconds` from the start of playback lands, or nil past the
    /// end.
    public func position(atMicroseconds microseconds: Int64) -> ScorePosition? {
        position(atPlaybackTicks: tempoMap.playbackTicks(atMicroseconds: microseconds))
    }

    /// When playback measure `index` begins, in microseconds.
    public func microseconds(atPlaybackMeasure index: Int) -> Int64? {
        guard playbackMeasures.indices.contains(index) else { return nil }
        return tempoMap.microseconds(atPlaybackTicks: playbackMeasures[index].startTicks)
    }
}

// MARK: - Digest

/// SHA-256 without pulling CryptoKit into every file that needs one hash.
enum SHA256Digest {
    static func hexString(_ data: Data) -> String {
        MusicXMLImporter.sha256Hex(data)
    }
}
