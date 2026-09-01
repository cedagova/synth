import Foundation

/// Why a stored piece could not be compiled.
///
/// Every case names the piece and what was wrong with it, because the only
/// caller that can act on this is the UI telling the owner why a piece in
/// their library will not play.
public enum ScoreCompilationError: Error, Equatable, LocalizedError {
    /// The stored bytes are not well-formed XML any more.
    case notWellFormedXML(reason: String, line: Int, column: Int)

    /// The document parses, but its root is not a MusicXML score.
    case notAMusicXMLScore(rootElement: String)

    /// The score declares no part with any music in it.
    case noParts

    /// The stored content file could not be read.
    case contentUnreadable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notWellFormedXML(let reason, let line, let column):
            return "This piece’s stored score is damaged: \(reason) (line \(line), column \(column))."
        case .notAMusicXMLScore(let rootElement):
            return "This piece’s stored score is not MusicXML; its document starts with “\(rootElement)”."
        case .noParts:
            return "This piece’s score contains no parts, so there is nothing to play."
        case .contentUnreadable(let reason):
            return "This piece’s stored score could not be read: \(reason)."
        }
    }
}

/// Compiles a stored piece's verbatim MusicXML into a `CompiledScore`.
///
/// **Purity is the contract.** `compile` reads no clock, draws nothing by
/// chance, consults no environment, and holds no state between calls. Its
/// result is a function of the bytes and the piece identifier alone.
/// `ScoreCompilerPurityTests` enforces that by scanning these sources for the
/// APIs that would break it, which is why this file avoids naming them even
/// in prose. Two consequences the rest of the app depends on:
///
/// - line identifiers are the same on every launch, so a preset saved in
///   increment 004 still points at the right line years later; and
/// - the compiled model is byte-identical across runs, which is what makes
///   the export-equals-playback promise (REQ-026) checkable rather than
///   hopeful.
///
/// Compilation covers the structural tier (AD4/D4) and the *capture* of the
/// expressive tier. Structure — pitches, rhythms, key and time, tempo and its
/// changes, repeats, endings, `D.C.`/`D.S.`/coda/`Fine`, fermatas — is turned
/// into the playback timeline here. Expressive notation — dynamics, hairpins,
/// articulations, slurs, pedal, grace notes and ornaments — is read into the
/// model for `PerformanceRealizer` to sound; only what neither stage can turn
/// into audible behaviour is written into the report.
///
/// The report is honest in both directions: a marking the realizer honours is
/// deliberately absent from it, and a marking neither stage understands is
/// always present. Capture and reporting are decided in the same place so the
/// two can never drift apart.
public struct ScoreCompiler: Sendable {
    /// Finest tick grid the compiler will use. Reached only by a score whose
    /// `divisions` values have a wildly composite least common multiple; the
    /// fallback rounds and files a report entry.
    public static let maximumTicksPerQuarter = 15_360

    /// Largest `<divisions>` value taken at face value. Notation software
    /// writes values in the tens to low thousands; anything past this is a
    /// typo or a hostile file, and honouring it would only make the tick grid
    /// unusable.
    static let maximumDivisions = 100_000

    /// Largest `<duration>` taken at face value, in that part's divisions.
    /// Even at a coarse grid this is thousands of measures for one note.
    ///
    /// The real reason for a ceiling is arithmetic: durations are multiplied
    /// by the tick grid, and an unbounded value read out of a file would
    /// overflow that multiplication and trap the process.
    static let maximumNoteDuration = 1_000_000

    public init() {}

    /// Compiles `musicXML` for the piece identified by `pieceID`.
    public func compile(pieceID: String, musicXML: Data) throws -> CompiledScore {
        let root: MusicXMLElement
        do {
            root = try MusicXMLDocument.parse(musicXML)
        } catch MusicXMLParseError.notWellFormed(let reason, let line, let column) {
            throw ScoreCompilationError.notWellFormedXML(reason: reason, line: line, column: column)
        } catch MusicXMLParseError.noRootElement {
            throw ScoreCompilationError.notWellFormedXML(
                reason: "the document contains no XML elements",
                line: 0,
                column: 0
            )
        }

        let partwise: MusicXMLElement
        switch root.name {
        case "score-partwise":
            partwise = root
        case "score-timewise":
            // The two encodings hold identical information with the part and
            // measure nesting swapped. Transposing once here means the rest of
            // the compiler only ever sees one shape.
            partwise = Self.partwise(fromTimewise: root)
        default:
            throw ScoreCompilationError.notAMusicXMLScore(rootElement: root.name)
        }

        var compilation = Compilation(
            pieceID: pieceID,
            contentSHA256: MusicXMLImporter.sha256Hex(musicXML),
            root: partwise
        )
        return try compilation.run()
    }

    /// Compiles the piece's stored content out of `contentStore`.
    public func compile(piece: PieceRecord, contentStore: PieceContentStoring) throws -> CompiledScore {
        let data: Data
        do {
            data = try contentStore.read(named: piece.contentFileName)
        } catch {
            throw ScoreCompilationError.contentUnreadable(
                reason: (error as NSError).localizedDescription
            )
        }
        return try compile(pieceID: piece.id, musicXML: data)
    }

    /// Rebuilds a `score-timewise` document as `score-partwise`.
    static func partwise(fromTimewise root: MusicXMLElement) -> MusicXMLElement {
        var header = root.children.filter { $0.name != "measure" }
        var measuresByPart: [String: [MusicXMLElement]] = [:]
        var partOrder: [String] = []

        for measure in root.childrenNamed("measure") {
            for part in measure.childrenNamed("part") {
                let id = part.attribute("id") ?? ""
                if measuresByPart[id] == nil {
                    measuresByPart[id] = []
                    partOrder.append(id)
                }
                measuresByPart[id]?.append(
                    MusicXMLElement(
                        name: "measure",
                        attributes: measure.attributes,
                        text: "",
                        children: part.children
                    )
                )
            }
        }

        for id in partOrder {
            header.append(
                MusicXMLElement(
                    name: "part",
                    attributes: ["id": id],
                    text: "",
                    children: measuresByPart[id] ?? []
                )
            )
        }
        return MusicXMLElement(
            name: "score-partwise",
            attributes: root.attributes,
            text: "",
            children: header
        )
    }
}

/// Reads a printed metronome mark.
///
/// `<metronome><beat-unit>dotted quarter</beat-unit><per-minute>80</…>` says
/// 80 dotted quarters a minute; the tempo map counts plain quarters, so the
/// beat unit has to be folded in. A `<sound tempo>` on the same direction is
/// already in quarter notes and always wins over this.
enum MusicXMLMetronome {
    static func microsecondsPerQuarter(_ metronome: MusicXMLElement) -> Int? {
        guard let perMinute = metronome.childText("per-minute").flatMap({ Double($0) }),
              perMinute > 0
        else { return nil }

        let unit = metronome.childText("beat-unit") ?? "quarter"
        guard var quarters = beatUnitInQuarters[unit] else { return nil }

        // A dot adds half of what precedes it; a second dot adds half of that.
        var addition = quarters / 2
        for _ in 0..<metronome.childrenNamed("beat-unit-dot").count {
            quarters += addition
            addition /= 2
        }
        return TempoMap.microsecondsPerQuarter(beatsPerMinute: perMinute * quarters)
    }

    static let beatUnitInQuarters: [String: Double] = [
        "breve": 8, "whole": 4, "half": 2, "quarter": 1,
        "eighth": 0.5, "16th": 0.25, "32nd": 0.125, "64th": 0.0625
    ]
}

// MARK: - One compilation

/// The working state of a single `compile` call.
///
/// A struct created and thrown away per call, so nothing can leak between
/// compilations and the purity claim stays structural rather than a promise
/// in a comment.
private struct Compilation {
    let pieceID: String
    let contentSHA256: String
    let root: MusicXMLElement

    var report = NotationReportCollector()
    var ticksPerQuarter = 1

    /// Notes per line key, in source order.
    var notesByLine: [LineKey: [ScoreNote]] = [:]

    /// Line keys in the order they were first met.
    var lineOrder: [LineKey] = []

    /// Structure per source measure, unioned across parts.
    var structures: [MeasureStructure] = []
    var measureNumbers: [String] = []
    var measureIsPickup: [Bool] = []
    var measureContentTicks: [Int] = []
    var measureTimeSignature: [TimeSignature?] = []
    var measureKeyFifths: [Int?] = []

    /// Tempo changes keyed by (measure, tick) so two parts carrying the same
    /// direction produce one change.
    var tempoEvents: [TempoKey: Int] = [:]

    /// Fermata spans, per source measure.
    var fermataSpans: [FermataSpan] = []

    /// Dynamics, hairpins and pedal markings, in the order they were met.
    /// Sorted into a canonical order before they reach the model.
    var expressionEvents: [ScoreExpressionEvent] = []

    /// Grace notes read but not yet attached to the principal note they
    /// precede, per line.
    var pendingGraceNotes: [LineKey: PendingGrace] = [:]

    var partNames: [String: String] = [:]

    /// Part identifiers already claimed, so no two parts can mint the same
    /// line identity.
    var usedPartIDs: Set<String> = []

    struct LineKey: Hashable {
        let partIndex: Int
        let partID: String
        let staff: Int
        let voice: String
    }

    struct TempoKey: Hashable {
        let measureIndex: Int
        let tick: Int
    }

    struct FermataSpan: Equatable {
        let measureIndex: Int
        let startTicks: Int
        let durationTicks: Int
    }

    /// Grace notes waiting for the note they ornament.
    struct PendingGrace {
        var notes: [ScoreGraceNote]
        var location: ScoreLocation
    }

    mutating func run() throws -> CompiledScore {
        readPartList()
        ticksPerQuarter = resolveTicksPerQuarter()

        let parts = root.childrenNamed("part")
        guard !parts.isEmpty else { throw ScoreCompilationError.noParts }

        let measureCount = parts.map { $0.childrenNamed("measure").count }.max() ?? 0
        guard measureCount > 0 else { throw ScoreCompilationError.noParts }

        structures = Array(repeating: MeasureStructure(), count: measureCount)
        measureNumbers = Array(repeating: "", count: measureCount)
        measureIsPickup = Array(repeating: false, count: measureCount)
        measureContentTicks = Array(repeating: 0, count: measureCount)
        measureTimeSignature = Array(repeating: nil, count: measureCount)
        measureKeyFifths = Array(repeating: nil, count: measureCount)

        for (partIndex, part) in parts.enumerated() {
            readPart(part, partIndex: partIndex)
        }

        let sourceMeasures = buildSourceMeasures()
        let expander = ScoreStructureExpander(
            structures: structures,
            measureNumbers: measureNumbers
        )
        let expanded = expander.expand(report: &report)
        let playbackMeasures = buildPlaybackMeasures(expanded, sourceMeasures: sourceMeasures)
        let tempoMap = buildTempoMap(playbackMeasures, sourceMeasures: sourceMeasures)

        let lines = buildLines()
        reportVoicesSplitAcrossStaves(lines)

        return CompiledScore(
            pieceID: pieceID,
            contentSHA256: contentSHA256,
            ticksPerQuarter: ticksPerQuarter,
            workTitle: root.child("work")?.childText("work-title") ?? root.childText("movement-title"),
            lines: lines,
            sourceMeasures: sourceMeasures,
            playbackMeasures: playbackMeasures,
            tempoMap: tempoMap,
            expressionEvents: expressionEvents.sorted(),
            report: report.finish()
        )
    }

    // MARK: Part list

    private mutating func readPartList() {
        guard let list = root.child("part-list") else { return }
        for scorePart in list.childrenNamed("score-part") {
            guard let id = scorePart.attribute("id") else { continue }
            if let name = scorePart.childText("part-name") {
                partNames[id] = name
            } else if let abbreviation = scorePart.childText("part-abbreviation") {
                partNames[id] = abbreviation
            }
        }
    }

    /// A tick grid every `divisions` value in the document divides exactly.
    ///
    /// MusicXML lets each part — and each measure — redefine `divisions`, so a
    /// single common grid is the only way durations from different parts can
    /// be compared at all. The least common multiple is that grid.
    private mutating func resolveTicksPerQuarter() -> Int {
        var values: Set<Int> = []
        root.forEachDescendant { element in
            guard element.name == "divisions", let value = Int(element.text) else { return }
            if value > 0, value <= ScoreCompiler.maximumDivisions { values.insert(value) }
        }
        guard !values.isEmpty else { return 1 }

        var result = 1
        for value in values.sorted() {
            let candidate = Self.leastCommonMultiple(result, value)
            if candidate > ScoreCompiler.maximumTicksPerQuarter || candidate <= 0 {
                report.record(
                    .structuralFallback,
                    kind: "extreme division resolution",
                    detail: "the score's divisions values need a finer grid than "
                        + "\(ScoreCompiler.maximumTicksPerQuarter) ticks per quarter; "
                        + "durations are rounded to that grid"
                )
                return ScoreCompiler.maximumTicksPerQuarter
            }
            result = candidate
        }
        return result
    }

    /// Least common multiple, or 0 when the answer would not fit — the caller
    /// treats that the same way it treats "too fine a grid".
    static func leastCommonMultiple(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs > 0, rhs > 0 else { return max(lhs, rhs, 1) }
        let (product, overflowed) = (lhs / greatestCommonDivisor(lhs, rhs))
            .multipliedReportingOverflow(by: rhs)
        return overflowed ? 0 : product
    }

    static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }

    // MARK: Part reading

    private mutating func readPart(_ part: MusicXMLElement, partIndex: Int) {
        let partID = effectivePartID(of: part, partIndex: partIndex)
        var state = PartState(divisions: 1)

        for (measureIndex, measure) in part.childrenNamed("measure").enumerated() {
            guard measureIndex < structures.count else { break }
            readMeasure(
                measure,
                measureIndex: measureIndex,
                partIndex: partIndex,
                partID: partID,
                state: &state
            )
        }
        flushPendingGraceNotes()
    }

    /// The identifier this part's lines are derived from, guaranteed unique
    /// within the score.
    ///
    /// `ScoreLineID` is the key a preset is stored against, and it is built
    /// from `(partID, staff, voice)`. A file with two `<part id="P2">`
    /// elements — or an id-less part whose positional fallback happens to
    /// collide with a real id — would otherwise mint one identifier for two
    /// different lines, and one line's sound would silently follow the other.
    /// Uniqueness here is what stops that.
    private mutating func effectivePartID(of part: MusicXMLElement, partIndex: Int) -> String {
        let declared = part.attribute("id") ?? "P\(partIndex + 1)"
        guard usedPartIDs.contains(declared) else {
            usedPartIDs.insert(declared)
            return declared
        }

        let disambiguated = "\(declared)#\(partIndex + 1)"
        usedPartIDs.insert(disambiguated)
        partNames[disambiguated] = partNames[declared]
        report.record(
            .structuralFallback,
            kind: "duplicate part identifier",
            at: ScoreLocation(partID: declared, partName: partNames[declared]),
            detail: "two parts share the identifier “\(declared)”; this one is treated as "
                + "“\(disambiguated)” so their lines stay distinct"
        )
        return disambiguated
    }

    /// Everything that carries forward from one measure to the next inside one
    /// part.
    private struct PartState {
        var divisions: Int
        var timeSignature: TimeSignature?
        var keyFifths: Int?
        /// Sounding pitch minus written pitch, in semitones.
        var transposeSemitones = 0
    }

    private mutating func readMeasure(
        _ measure: MusicXMLElement,
        measureIndex: Int,
        partIndex: Int,
        partID: String,
        state: inout PartState
    ) {
        let number = measure.attribute("number") ?? String(measureIndex + 1)
        if measureNumbers[measureIndex].isEmpty { measureNumbers[measureIndex] = number }
        if measure.attributeIsYes("implicit") { measureIsPickup[measureIndex] = true }

        let location = ScoreLocation(
            partID: partID,
            partName: partNames[partID],
            sourceMeasureIndex: measureIndex,
            measureNumber: number
        )

        var cursor = 0
        var furthest = 0
        var lastOnset = 0

        for element in measure.children {
            switch element.name {
            case "attributes":
                readAttributes(element, state: &state, at: location)

            case "note":
                readNote(
                    element,
                    measureIndex: measureIndex,
                    partIndex: partIndex,
                    partID: partID,
                    state: state,
                    cursor: &cursor,
                    lastOnset: &lastOnset,
                    at: location
                )
                furthest = max(furthest, cursor)

            case "backup":
                cursor = max(0, cursor - ticks(element.childInt("duration") ?? 0, state: state, at: location))

            case "forward":
                cursor += ticks(element.childInt("duration") ?? 0, state: state, at: location)
                furthest = max(furthest, cursor)

            case "direction":
                readDirection(
                    element,
                    measureIndex: measureIndex,
                    partID: partID,
                    cursor: cursor,
                    state: state,
                    at: location
                )

            case "sound":
                readSound(element, measureIndex: measureIndex, cursor: cursor)

            case "barline":
                readBarline(element, measureIndex: measureIndex)

            case "harmony", "figured-bass":
                report.record(
                    .notHonored,
                    kind: element.name == "harmony" ? "chord symbol" : "figured bass",
                    at: location,
                    detail: "written above the staff and not sounded"
                )

            case _ where Self.silentMeasureChildren.contains(element.name):
                continue

            default:
                report.record(
                    .notHonored,
                    kind: "unrecognised element: \(element.name)",
                    at: location
                )
            }
        }

        // One last ceiling on what a measure can be. Expansion may repeat a
        // measure thousands of times, and the playback timeline accumulates
        // those lengths, so an unbounded measure would overflow the timeline
        // rather than merely be long.
        let ceiling = ticksPerQuarter * 4 * 1024
        if furthest > ceiling {
            report.record(
                .structuralFallback,
                kind: "impossible measure length",
                at: location,
                detail: "this measure is longer than a thousand whole notes; it is clipped"
            )
            furthest = ceiling
        }
        measureContentTicks[measureIndex] = max(measureContentTicks[measureIndex], furthest)
        if measureTimeSignature[measureIndex] == nil { measureTimeSignature[measureIndex] = state.timeSignature }
        if measureKeyFifths[measureIndex] == nil { measureKeyFifths[measureIndex] = state.keyFifths }
    }

    /// Layout, formatting and bookkeeping: nothing here can sound, so nothing
    /// here belongs in the report.
    static let silentMeasureChildren: Set<String> = [
        "print", "bookmark", "link", "grouping", "listening", "footnote", "level"
    ]

    private mutating func readAttributes(
        _ attributes: MusicXMLElement,
        state: inout PartState,
        at location: ScoreLocation
    ) {
        for element in attributes.children {
            switch element.name {
            case "divisions":
                if let value = Int(element.text),
                   value > 0,
                   value <= ScoreCompiler.maximumDivisions {
                    state.divisions = value
                }

            case "key":
                if let fifths = element.childInt("fifths") { state.keyFifths = fifths }

            case "time":
                // Both bounded: a notated measure length is multiplied by the
                // tick grid, so an unbounded numerator read out of a file
                // would overflow rather than merely look wrong.
                if let beats = element.childInt("beats"),
                   let beatType = element.childInt("beat-type"),
                   (1...1024).contains(beats),
                   (1...1024).contains(beatType) {
                    state.timeSignature = TimeSignature(beats: beats, beatType: beatType)
                } else if element.attribute("symbol") == "common" {
                    state.timeSignature = TimeSignature(beats: 4, beatType: 4)
                } else if element.attribute("symbol") == "cut" {
                    state.timeSignature = TimeSignature(beats: 2, beatType: 2)
                }

            case "transpose":
                // Clamped to ten octaves either way: past that it is not a
                // transposing instrument, and the arithmetic downstream has to
                // stay inside `Int`.
                let chromatic = min(120, max(-120, element.childInt("chromatic") ?? 0))
                let octaveChange = min(10, max(-10, element.childInt("octave-change") ?? 0))
                state.transposeSemitones = chromatic + 12 * octaveChange

            case "measure-style":
                let style = element.children.first?.name ?? "measure-style"
                report.record(
                    .notHonored,
                    kind: "measure style: \(style)",
                    at: location,
                    detail: "the shorthand is not expanded; the measures are played as written"
                )

            case _ where Self.silentAttributeChildren.contains(element.name):
                continue

            default:
                report.record(.notHonored, kind: "unrecognised element: \(element.name)", at: location)
            }
        }
    }

    /// Engraving detail inside `<attributes>`; none of it changes what sounds.
    static let silentAttributeChildren: Set<String> = [
        "clef", "staves", "staff-details", "part-symbol", "instruments",
        "directive", "for-part", "footnote", "level"
    ]

    // MARK: Notes

    private mutating func readNote(
        _ note: MusicXMLElement,
        measureIndex: Int,
        partIndex: Int,
        partID: String,
        state: PartState,
        cursor: inout Int,
        lastOnset: inout Int,
        at location: ScoreLocation
    ) {
        let staffOfNote = note.childInt("staff") ?? 1
        let voiceOfNote = note.childText("voice") ?? "1"
        let lineKey = LineKey(
            partIndex: partIndex,
            partID: partID,
            staff: staffOfNote,
            voice: voiceOfNote
        )

        if let grace = note.child("grace") {
            readGraceNote(note, grace: grace, key: lineKey, state: state, at: location)
            return
        }
        if note.child("cue") != nil {
            report.record(
                .notHonored,
                kind: "cue note",
                at: location,
                detail: "cue staves are printed for orientation and are not played"
            )
            // Unlike a grace note, a cue note carries a duration and still
            // advances the musical position in its voice — only its sound is
            // omitted. Skipping the advance would shift every later note in a
            // voice that mixes cue and normal notes.
            let isChord = note.child("chord") != nil
            let duration = ticks(note.childInt("duration") ?? 0, state: state, at: location)
            let onset = isChord ? lastOnset : cursor
            lastOnset = onset
            if !isChord { cursor = onset + duration }
            return
        }

        let isChord = note.child("chord") != nil
        let duration = ticks(note.childInt("duration") ?? 0, state: state, at: location)
        let key = lineKey

        // A chord member sounds with the note before it. Only the first note
        // of the chord moved the cursor, so the others must not move it again.
        let onset = isChord ? lastOnset : cursor

        var pitch: ScorePitch?
        if note.child("rest") != nil {
            pitch = nil
        } else if let element = note.child("pitch") {
            let reading = Self.pitch(from: element, transposeSemitones: state.transposeSemitones)
            pitch = reading.pitch
            if reading.pitch == nil {
                report.record(
                    .notHonored,
                    kind: "unreadable pitch",
                    at: location,
                    detail: "the note is played as a rest"
                )
            }
            if reading.isMicrotonal {
                report.record(
                    .notHonored,
                    kind: "microtonal alteration",
                    at: location,
                    detail: "rounded to the nearest semitone"
                )
            }
        } else if note.child("unpitched") != nil {
            report.record(
                .notHonored,
                kind: "unpitched (percussion) note",
                at: location,
                detail: "percussion staves need a percussion map, which this build has no sound for"
            )
            pitch = nil
        } else {
            pitch = nil
        }

        var notations = NoteNotations()
        for element in note.childrenNamed("notations") {
            readNotations(element, into: &notations, at: location)
        }
        for child in note.children where !Self.knownNoteChildren.contains(child.name) {
            report.record(.notHonored, kind: "unrecognised element: \(child.name)", at: location)
        }
        let fermata = notations.fermata

        // Grace notes belong to the principal note they precede. A chord's
        // grace notes are printed once, before its first note, so only that
        // note takes them.
        var graceNotes: [ScoreGraceNote] = []
        if !isChord, let pending = pendingGraceNotes.removeValue(forKey: key) {
            graceNotes = pending.notes
        }

        notesByLine[key, default: []].append(
            ScoreNote(
                sourceMeasureIndex: measureIndex,
                startTicks: onset,
                durationTicks: duration,
                pitch: pitch,
                isChordMember: isChord,
                tiesForward: note.childrenNamed("tie").contains { $0.attribute("type") == "start" },
                tiesBackward: note.childrenNamed("tie").contains { $0.attribute("type") == "stop" },
                hasFermata: fermata,
                articulations: notations.articulations.sorted(),
                ornaments: notations.ornaments,
                graceNotes: graceNotes,
                slurStartCount: notations.slurStartCount,
                slurStopCount: notations.slurStopCount,
                dynamics: notations.dynamics.sorted()
            )
        )
        if notesByLine[key]?.count == 1 { lineOrder.append(key) }

        if fermata, duration > 0 {
            fermataSpans.append(
                FermataSpan(measureIndex: measureIndex, startTicks: onset, durationTicks: duration)
            )
        }

        lastOnset = onset
        if !isChord { cursor = onset + duration }
    }

    /// Note children whose effect is either honoured elsewhere or purely
    /// visual. Anything not listed here lands in the report.
    static let knownNoteChildren: Set<String> = [
        "grace", "cue", "chord", "pitch", "unpitched", "rest", "duration", "tie",
        "voice", "type", "dot", "accidental", "time-modification", "stem",
        "notehead", "notehead-text", "staff", "beam", "notations", "lyric",
        "play", "listen", "instrument", "footnote", "level"
    ]

    /// Everything one note's `<notations>` elements say about how it sounds.
    struct NoteNotations {
        var fermata = false
        var articulations: [ScoreArticulation] = []
        var ornaments: [ScoreOrnament] = []
        var slurStartCount = 0
        var slurStopCount = 0
        var dynamics: [ScoreDynamic] = []
    }

    /// Reads `<notations>` into `result`, reporting only what the realizer
    /// cannot sound.
    private mutating func readNotations(
        _ notations: MusicXMLElement,
        into result: inout NoteNotations,
        at location: ScoreLocation
    ) {
        for element in notations.children {
            switch element.name {
            case "fermata":
                result.fermata = true

            case "tied", "tuplet", "footnote", "level", "accidental-mark":
                continue // rendering of something already honoured

            case "slur":
                switch element.attribute("type") {
                case "start": result.slurStartCount += 1
                case "stop": result.slurStopCount += 1
                case "continue", .none: continue
                case .some(let type):
                    report.record(.notHonored, kind: "slur type: \(type)", at: location)
                }

            case "ornaments":
                readOrnaments(element, into: &result, at: location)

            case "articulations":
                if element.children.isEmpty {
                    report.record(.notHonored, kind: "articulation", at: location)
                }
                for child in element.children {
                    if let articulation = ScoreArticulation.byElementName[child.name] {
                        if !result.articulations.contains(articulation) {
                            result.articulations.append(articulation)
                        }
                    } else {
                        report.record(.notHonored, kind: "articulation: \(child.name)", at: location)
                    }
                }

            case "dynamics":
                if element.children.isEmpty {
                    report.record(.notHonored, kind: "dynamic", at: location)
                }
                for child in element.children {
                    if let dynamic = ScoreDynamic.byElementName[child.name] {
                        if !result.dynamics.contains(dynamic) { result.dynamics.append(dynamic) }
                    } else {
                        report.record(.notHonored, kind: "dynamic: \(child.name)", at: location)
                    }
                }

            case "technical":
                if element.children.isEmpty {
                    report.record(.notHonored, kind: "technique", at: location)
                }
                for child in element.children where child.name != "accidental-mark" {
                    report.record(.notHonored, kind: "technique: \(child.name)", at: location)
                }

            default:
                report.record(.notHonored, kind: "notation: \(element.name)", at: location)
            }
        }
    }

    /// Reads `<ornaments>`, pairing each ornament with the accidental marks
    /// printed against it.
    ///
    /// In MusicXML the accidental marks *follow* the ornament they alter, and
    /// their `placement` says which auxiliary note they belong to. Scanning
    /// forward from each ornament is therefore the only reading that gets a
    /// trill with a printed sharp over it right.
    private mutating func readOrnaments(
        _ ornaments: MusicXMLElement,
        into result: inout NoteNotations,
        at location: ScoreLocation
    ) {
        let children = ornaments.children
        if children.isEmpty {
            report.record(.notHonored, kind: "ornament", at: location)
            return
        }

        // A wavy line draws the trill a `<trill-mark>` already states. Alone
        // it is an unlabelled squiggle, and guessing at one would invent an
        // ornament the engraver did not write.
        let hasTrillMark = children.contains {
            ScoreOrnamentKind.byElementName[$0.name] == .trill
        }

        for (index, child) in children.enumerated() {
            if child.name == "accidental-mark" { continue }
            if child.name == "wavy-line" {
                if !hasTrillMark {
                    report.record(.notHonored, kind: "ornament: wavy-line", at: location)
                }
                continue
            }
            guard let kind = ScoreOrnamentKind.byElementName[child.name] else {
                report.record(.notHonored, kind: "ornament: \(child.name)", at: location)
                continue
            }

            var upper: Int?
            var lower: Int?
            var scan = index + 1
            while scan < children.count, children[scan].name == "accidental-mark" {
                let mark = children[scan]
                if let alter = Self.accidentalAlteration(mark.text) {
                    if mark.attribute("placement") == "below" { lower = alter } else { upper = alter }
                } else {
                    report.record(
                        .notHonored,
                        kind: "ornament accidental: \(mark.text)",
                        at: location,
                        detail: "the auxiliary note takes the key signature instead"
                    )
                }
                scan += 1
            }

            result.ornaments.append(
                ScoreOrnament(kind: kind, upperAlter: upper, lowerAlter: lower)
            )
        }
    }

    /// `<accidental-mark>` text to a semitone alteration.
    static func accidentalAlteration(_ text: String) -> Int? {
        switch text {
        case "natural": return 0
        case "sharp": return 1
        case "flat": return -1
        case "double-sharp", "sharp-sharp": return 2
        case "flat-flat", "double-flat": return -2
        default: return nil
        }
    }

    /// Reads one `<note>` carrying `<grace>` and holds it for the principal
    /// note it precedes.
    private mutating func readGraceNote(
        _ note: MusicXMLElement,
        grace: MusicXMLElement,
        key: LineKey,
        state: PartState,
        at location: ScoreLocation
    ) {
        guard let element = note.child("pitch") else {
            // A grace rest is not a thing a player can sound; a grace note
            // with no pitch at all is a damaged file.
            report.record(
                .notHonored,
                kind: "grace note without a pitch",
                at: location,
                detail: "there is nothing for it to sound"
            )
            return
        }
        let reading = Self.pitch(from: element, transposeSemitones: state.transposeSemitones)
        guard let pitch = reading.pitch else {
            report.record(
                .notHonored,
                kind: "grace note without a pitch",
                at: location,
                detail: "there is nothing for it to sound"
            )
            return
        }
        if reading.isMicrotonal {
            report.record(
                .notHonored,
                kind: "microtonal alteration",
                at: location,
                detail: "rounded to the nearest semitone"
            )
        }

        var notations = NoteNotations()
        for element in note.childrenNamed("notations") {
            readNotations(element, into: &notations, at: location)
        }

        let graceNote = ScoreGraceNote(
            pitch: pitch,
            isAcciaccatura: grace.attributeIsYes("slash"),
            notatedTicks: Self.notatedTicks(
                ofType: note.childText("type"),
                dots: note.childrenNamed("dot").count,
                ticksPerQuarter: ticksPerQuarter
            ),
            stealTimeFollowingPercent: Self.percentage(grace.attribute("steal-time-following")),
            stealTimePreviousPercent: Self.percentage(grace.attribute("steal-time-previous")),
            isChordMember: note.child("chord") != nil
        )

        pendingGraceNotes[key, default: PendingGrace(notes: [], location: location)]
            .notes.append(graceNote)
    }

    /// A whole-number percentage in 0…100, or nil.
    static func percentage(_ text: String?) -> Int? {
        guard let value = text.flatMap({ Double($0) }), value.isFinite, value >= 0, value <= 100
        else { return nil }
        return Int(value.rounded())
    }

    /// Ticks for a printed `<type>` with `dots` augmentation dots.
    static func notatedTicks(ofType type: String?, dots: Int, ticksPerQuarter: Int) -> Int {
        guard let type, let ratio = noteTypeInQuarters[type] else { return 0 }
        var value = ticksPerQuarter * ratio.numerator / ratio.denominator
        var addition = value / 2
        for _ in 0..<min(dots, 4) {
            value += addition
            addition /= 2
        }
        return max(0, value)
    }

    /// Printed note values as an exact fraction of a quarter note. Integral so
    /// nothing on this path rounds twice.
    static let noteTypeInQuarters: [String: (numerator: Int, denominator: Int)] = [
        "breve": (8, 1), "whole": (4, 1), "half": (2, 1), "quarter": (1, 1),
        "eighth": (1, 2), "16th": (1, 4), "32nd": (1, 8), "64th": (1, 16),
        "128th": (1, 32), "256th": (1, 64)
    ]

    /// Reports grace notes at the end of a part that never found a principal
    /// note to ornament.
    private mutating func flushPendingGraceNotes() {
        for (_, pending) in pendingGraceNotes.sorted(by: { left, right in
            (left.key.partIndex, left.key.staff, left.key.voice)
                < (right.key.partIndex, right.key.staff, right.key.voice)
        }) {
            for _ in pending.notes {
                report.record(
                    .notHonored,
                    kind: "grace note with no note to ornament",
                    at: pending.location,
                    detail: "no note follows it in this voice"
                )
            }
        }
        pendingGraceNotes.removeAll()
    }

    /// Builds a sounding pitch, applying the part's transposition, and says
    /// whether the written alteration was a microtone that had to be rounded.
    static func pitch(
        from element: MusicXMLElement,
        transposeSemitones: Int
    ) -> (pitch: ScorePitch?, isMicrotonal: Bool) {
        // Every bound here exists because the values come out of a file: an
        // octave or an alteration outside these ranges is not a pitch, and
        // converting it would overflow rather than sound wrong.
        guard let step = element.childText("step"),
              let octave = element.childInt("octave"),
              (-1...11).contains(octave)
        else { return (nil, false) }

        let rawAlter = element.childText("alter")
            .flatMap { Double($0) }
            .flatMap { $0.isFinite && abs($0) <= 24 ? $0 : nil }
        let alter = rawAlter.map { Int($0.rounded()) } ?? 0
        let isMicrotonal = rawAlter.map { $0 != $0.rounded() } ?? false

        let written = ScorePitch(step: step.uppercased(), alter: alter, octave: octave)
        guard transposeSemitones != 0, let midi = written.midiNoteNumber else {
            return (written, isMicrotonal)
        }
        return (sounding(midiNoteNumber: midi + transposeSemitones), isMicrotonal)
    }

    /// Respells a MIDI note as step/alter/octave.
    ///
    /// Sharps by convention. A transposing part's sounding pitch is what the
    /// engine plays, so the pitch has to be right; the *spelling* only shows
    /// up in diagnostics, and picking one fixed table keeps the model
    /// reproducible.
    static func sounding(midiNoteNumber: Int) -> ScorePitch {
        let table: [(step: String, alter: Int)] = [
            ("C", 0), ("C", 1), ("D", 0), ("D", 1), ("E", 0), ("F", 0),
            ("F", 1), ("G", 0), ("G", 1), ("A", 0), ("A", 1), ("B", 0)
        ]
        let clamped = max(0, min(127, midiNoteNumber))
        let entry = table[clamped % 12]
        return ScorePitch(step: entry.step, alter: entry.alter, octave: clamped / 12 - 1)
    }

    // MARK: Directions, sound, barlines

    private mutating func readDirection(
        _ direction: MusicXMLElement,
        measureIndex: Int,
        partID: String,
        cursor: Int,
        state: PartState,
        at location: ScoreLocation
    ) {
        var words: [String] = []

        // `<offset>` moves a direction away from where it is anchored, in the
        // part's own divisions. Ignoring it would put a hairpin's end on the
        // wrong beat in every file an engraver nudged by hand.
        let offset = direction.childInt("offset").map {
            $0 >= 0
                ? ticks($0, state: state, at: location)
                : -ticks(-$0, state: state, at: location)
        } ?? 0
        let tick = max(0, cursor + offset)
        let staff = direction.childInt("staff") ?? ScoreExpressionEvent.allStaves

        func record(
            _ kind: ScoreExpressionKind,
            dynamic: ScoreDynamic? = nil,
            wedge: ScoreWedgeType? = nil
        ) {
            expressionEvents.append(
                ScoreExpressionEvent(
                    sourceMeasureIndex: measureIndex,
                    startTicks: tick,
                    partID: partID,
                    staff: staff,
                    kind: kind,
                    dynamic: dynamic,
                    wedge: wedge
                )
            )
        }

        for type in direction.childrenNamed("direction-type") {
            for element in type.children {
                switch element.name {
                case "segno":
                    structures[measureIndex].hasSegno = true
                case "coda":
                    structures[measureIndex].hasCoda = true
                case "words":
                    words.append(element.text)
                case "metronome":
                    // A `<sound tempo>` on the same direction is read after
                    // this and wins; a printed marking with no `<sound>` is
                    // all we have, so it must still set the tempo.
                    let key = TempoKey(measureIndex: measureIndex, tick: cursor)
                    if tempoEvents[key] == nil,
                       let mpq = MusicXMLMetronome.microsecondsPerQuarter(element) {
                        tempoEvents[key] = mpq
                    }

                case "dynamics":
                    if element.children.isEmpty {
                        report.record(.notHonored, kind: "dynamic", at: location)
                    }
                    for child in element.children {
                        if let dynamic = ScoreDynamic.byElementName[child.name] {
                            record(.dynamic, dynamic: dynamic)
                        } else {
                            report.record(.notHonored, kind: "dynamic: \(child.name)", at: location)
                        }
                    }

                case "wedge":
                    switch element.attribute("type") {
                    case "crescendo": record(.wedgeStart, wedge: .crescendo)
                    case "diminuendo": record(.wedgeStart, wedge: .diminuendo)
                    case "stop": record(.wedgeStop)
                    case "continue", .none: continue
                    case .some(let type):
                        report.record(.notHonored, kind: "hairpin (\(type))", at: location)
                    }

                case "pedal":
                    // `sostenuto` holds only the notes already down, which
                    // needs a second pedal state the engine does not have.
                    switch element.attribute("type") {
                    case "start": record(.pedalDown)
                    case "stop", "discontinue": record(.pedalUp)
                    case "change": record(.pedalChange)
                    case "continue", "resume", .none: continue
                    case .some(let type):
                        report.record(.notHonored, kind: "pedal (\(type))", at: location)
                    }

                case "octave-shift":
                    report.record(
                        .notHonored,
                        kind: "octave shift",
                        at: location,
                        detail: "the notes are played at their written octave"
                    )

                case "rehearsal", "dashes", "bracket", "eyeglasses", "image", "other-direction":
                    continue // visual only

                default:
                    report.record(.notHonored, kind: "direction: \(element.name)", at: location)
                }
            }
        }

        if let sound = direction.child("sound") {
            readSound(sound, measureIndex: measureIndex, cursor: cursor)
        }
        readJumpWords(words, measureIndex: measureIndex)
    }

    /// `<sound>` is MusicXML's explicit playback channel: when an engraver
    /// writes one, it is authoritative about tempo and jumps, and the printed
    /// words are only their appearance.
    private mutating func readSound(
        _ sound: MusicXMLElement,
        measureIndex: Int,
        cursor: Int
    ) {
        if let tempo = sound.attribute("tempo").flatMap({ Double($0) }),
           let mpq = TempoMap.microsecondsPerQuarter(beatsPerMinute: tempo) {
            tempoEvents[TempoKey(measureIndex: measureIndex, tick: cursor)] = mpq
        }
        if sound.attributeIsYes("dacapo") { structures[measureIndex].daCapo = true }
        if sound.attribute("dalsegno") != nil { structures[measureIndex].dalSegno = true }
        if sound.attribute("tocoda") != nil { structures[measureIndex].toCoda = true }
        if sound.attribute("segno") != nil { structures[measureIndex].hasSegno = true }
        if sound.attribute("coda") != nil { structures[measureIndex].hasCoda = true }
        if sound.attributeIsYes("fine") { structures[measureIndex].fine = true }
        if sound.attributeIsYes("forward-repeat") { structures[measureIndex].startsRepeat = true }
    }

    /// Recognises jump directions written only as text.
    ///
    /// Plenty of engravers type “D.C. al Fine” as words and never add a
    /// `<sound>` element. Ignoring that would silently flatten the form of a
    /// perfectly ordinary score, so the printed wording is read too.
    ///
    /// The subtlety worth spelling out: in “D.C. al Fine”, the words *Fine*
    /// and *Coda* name where the jump ends, not a mark at this measure. The
    /// `Fine` and `To Coda` marks are printed elsewhere in the score. So a
    /// direction that declares a jump declares only that — reading its tail as
    /// a `Fine` here would stop the piece on the wrong bar.
    private mutating func readJumpWords(_ words: [String], measureIndex: Int) {
        guard !words.isEmpty else { return }
        let text = words
            .joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if text.contains("dal segno") || text.hasPrefix("ds ") || text == "ds" {
            structures[measureIndex].dalSegno = true
            return
        }
        if text.contains("da capo") || text.hasPrefix("dc ") || text == "dc" {
            structures[measureIndex].daCapo = true
            return
        }

        if text.contains("to coda") || text.contains("al coda") {
            structures[measureIndex].toCoda = true
        }
        if text.contains("fine") { structures[measureIndex].fine = true }
        if text == "segno" { structures[measureIndex].hasSegno = true }
        if text == "coda" { structures[measureIndex].hasCoda = true }
    }

    private mutating func readBarline(_ barline: MusicXMLElement, measureIndex: Int) {
        if let repeatElement = barline.child("repeat") {
            switch repeatElement.attribute("direction") {
            case "forward":
                structures[measureIndex].startsRepeat = true
            case "backward":
                structures[measureIndex].endsRepeat = true
                if let times = repeatElement.attribute("times").flatMap({ Int($0) }), times >= 2 {
                    structures[measureIndex].repeatTimes = max(
                        structures[measureIndex].repeatTimes,
                        times
                    )
                }
            default:
                break
            }
        }

        guard let ending = barline.child("ending") else { return }
        switch ending.attribute("type") {
        case "start":
            let numbers = Self.endingNumbers(ending)
            structures[measureIndex].endingNumbers = Array(
                Set(structures[measureIndex].endingNumbers).union(numbers)
            ).sorted()
        case "stop", "discontinue":
            structures[measureIndex].endsEnding = true
        default:
            break
        }
    }

    /// `<ending number="1, 2">` — a comma-separated list of pass numbers.
    static func endingNumbers(_ ending: MusicXMLElement) -> [Int] {
        let raw = ending.attribute("number") ?? ""
        let parsed = raw
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
        // An unnumbered ending is a first ending in practice; treating it as
        // "never played" would silently delete music.
        return parsed.isEmpty ? [1] : parsed.sorted()
    }

    // MARK: Duration conversion

    /// Converts a MusicXML duration into ticks on the common grid.
    private mutating func ticks(_ duration: Int, state: PartState, at location: ScoreLocation) -> Int {
        guard duration > 0, state.divisions > 0 else { return 0 }

        var duration = duration
        if duration > ScoreCompiler.maximumNoteDuration {
            report.record(
                .structuralFallback,
                kind: "impossible duration",
                at: location,
                detail: "a duration of \(duration) is not music; it is clipped to "
                    + "\(ScoreCompiler.maximumNoteDuration)"
            )
            duration = ScoreCompiler.maximumNoteDuration
        }

        let numerator = duration * ticksPerQuarter
        if numerator % state.divisions != 0 {
            report.record(
                .structuralFallback,
                kind: "duration off the tick grid",
                at: location,
                detail: "rounded to the nearest tick"
            )
        }
        return (numerator + state.divisions / 2) / state.divisions
    }

    // MARK: Assembly

    private func buildSourceMeasures() -> [SourceMeasure] {
        (0..<structures.count).map { index in
            let signature = measureTimeSignature[index]
            let notated = signature.map { $0.beats * ticksPerQuarter * 4 / max(1, $0.beatType) } ?? 0
            let content = measureContentTicks[index]

            // Content is the truth. `content` is the furthest any part
            // reached, so one part that stops writing rests early cannot
            // shorten the bar for everyone else — but when every part stops at
            // the same early point the measure really is short: an engraving
            // that splits one bar across a system break writes it as two
            // underfull measures, and padding those to the notated length
            // inserts silence nobody wrote. An empty measure keeps its notated
            // length, and an over-full one is never clipped.
            let duration = content > 0 ? content : notated
            return SourceMeasure(
                index: index,
                number: measureNumbers[index].isEmpty ? String(index + 1) : measureNumbers[index],
                isPickup: measureIsPickup[index],
                durationTicks: max(0, duration),
                timeSignature: signature,
                keyFifths: measureKeyFifths[index]
            )
        }
    }

    private func buildPlaybackMeasures(
        _ expanded: [ExpandedMeasure],
        sourceMeasures: [SourceMeasure]
    ) -> [PlaybackMeasure] {
        var out: [PlaybackMeasure] = []
        out.reserveCapacity(expanded.count)
        var start = 0
        for (index, measure) in expanded.enumerated() {
            let duration = sourceMeasures[measure.sourceMeasureIndex].durationTicks
            out.append(
                PlaybackMeasure(
                    index: index,
                    sourceMeasureIndex: measure.sourceMeasureIndex,
                    pass: measure.pass,
                    startTicks: start,
                    durationTicks: duration
                )
            )
            start += duration
        }
        return out
    }

    private func buildTempoMap(
        _ playbackMeasures: [PlaybackMeasure],
        sourceMeasures: [SourceMeasure]
    ) -> TempoMap {
        var changes: [TempoMapBuilder.Change] = []
        var holds: [TempoMapBuilder.Hold] = []

        // Tempo marks and fermatas live on source measures, so a repeated
        // section brings them back every time it is played — which is what a
        // player does.
        let tempoBySource = Dictionary(
            grouping: tempoEvents.map { (key: $0.key, mpq: $0.value) },
            by: { $0.key.measureIndex }
        )
        let fermataBySource = Dictionary(grouping: fermataSpans, by: \.measureIndex)

        for measure in playbackMeasures {
            for event in tempoBySource[measure.sourceMeasureIndex] ?? [] {
                changes.append(
                    TempoMapBuilder.Change(
                        startTicks: measure.startTicks + min(event.key.tick, measure.durationTicks),
                        microsecondsPerQuarter: event.mpq
                    )
                )
            }
            for span in fermataBySource[measure.sourceMeasureIndex] ?? [] {
                let start = measure.startTicks + min(span.startTicks, measure.durationTicks)
                holds.append(
                    TempoMapBuilder.Hold(
                        startTicks: start,
                        endTicks: min(start + span.durationTicks, measure.endTicks)
                    )
                )
            }
        }

        // Two parts can carry the same tempo mark; one moment, one tempo.
        changes.sort { ($0.startTicks, $0.microsecondsPerQuarter) < ($1.startTicks, $1.microsecondsPerQuarter) }

        return TempoMapBuilder(
            ticksPerQuarter: ticksPerQuarter,
            totalTicks: playbackMeasures.last?.endTicks ?? 0
        ).build(changes: changes, holds: holds)
    }

    private func buildLines() -> [ScoreLine] {
        let keys = lineOrder.sorted { left, right in
            if left.partIndex != right.partIndex { return left.partIndex < right.partIndex }
            if left.staff != right.staff { return left.staff < right.staff }
            return Self.voiceOrder(left.voice, right.voice)
        }

        let staffCountByPart = Dictionary(grouping: keys, by: \.partID)
            .mapValues { Set($0.map(\.staff)).count }
        let lineCountByPart = Dictionary(grouping: keys, by: \.partID).mapValues(\.count)

        return keys.compactMap { key -> ScoreLine? in
            let notes = (notesByLine[key] ?? []).sorted { left, right in
                if left.sourceMeasureIndex != right.sourceMeasureIndex {
                    return left.sourceMeasureIndex < right.sourceMeasureIndex
                }
                return left.startTicks < right.startTicks
            }
            // A voice that never sounds a pitch is an artefact of the
            // engraving (a spacer rest), not a line the owner can assign a
            // sound to.
            guard notes.contains(where: { $0.pitch != nil }) else { return nil }

            return ScoreLine(
                id: ScoreLineID(partID: key.partID, staff: key.staff, voice: key.voice),
                partID: key.partID,
                partName: partNames[key.partID],
                staff: key.staff,
                voice: key.voice,
                name: ScoreCompiler.defaultLineName(
                    base: partNames[key.partID] ?? "Part \(key.partID)",
                    staff: key.staff,
                    voice: key.voice,
                    staffCount: staffCountByPart[key.partID] ?? 1,
                    lineCount: lineCountByPart[key.partID] ?? 1
                ),
                notes: notes
            )
        }
    }

    /// Records the one place the compiler quietly changes what the score
    /// means: a voice that crosses between staves.
    ///
    /// A line is `(part, staff, voice)`, so a pianist's right hand that dips
    /// into the bass staff for two bars arrives as two lines the owner will be
    /// asked to assign separately. Splitting is the safer reading — merging
    /// would guess that two staves' voice 1 are one player — but it is a
    /// decision, and a decision the owner cannot see is exactly what REQ-014
    /// exists to prevent.
    private mutating func reportVoicesSplitAcrossStaves(_ lines: [ScoreLine]) {
        var stavesByVoice: [String: Set<Int>] = [:]
        for line in lines {
            stavesByVoice["\(line.partID)\u{1F}\(line.voice)", default: []].insert(line.staff)
        }

        for line in lines where (stavesByVoice["\(line.partID)\u{1F}\(line.voice)"]?.count ?? 0) > 1 {
            report.record(
                .structuralFallback,
                kind: "voice split across staves",
                at: ScoreLocation(partID: line.partID, partName: line.partName),
                detail: "voice \(line.voice) appears on more than one staff and becomes one line "
                    + "per staff, so each can be assigned its own sound"
            )
        }
    }

    /// Numeric voices sort numerically (`2` before `10`); anything else falls
    /// back to text so the order is still total and still stable.
    static func voiceOrder(_ lhs: String, _ rhs: String) -> Bool {
        if let left = Int(lhs), let right = Int(rhs) { return left < right }
        return lhs < rhs
    }

}

extension ScoreCompiler {
    /// The default name for a line: the part alone when the part is one line,
    /// and only as much staff/voice detail as is needed to tell its lines
    /// apart.
    ///
    /// A default, not a label: the owner renames lines in increment 004, and
    /// the rename is stored against the line's identifier, not its name.
    static func defaultLineName(
        base: String,
        staff: Int,
        voice: String,
        staffCount: Int,
        lineCount: Int
    ) -> String {
        guard lineCount > 1 else { return base }
        if staffCount > 1 {
            return "\(base), staff \(staff), voice \(voice)"
        }
        return "\(base), voice \(voice)"
    }
}
