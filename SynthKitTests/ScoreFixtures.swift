import Foundation

/// A MusicXML writer for tests: build a score as values, render it to bytes.
///
/// Increment 001's fixtures are one-note stubs, which is all an *importer*
/// needs. Interpreting a score needs scores — with several parts, several
/// voices per part, repeats, jumps, tempo changes and notation this build does
/// not honour. Writing those as string literals per test would be unreadable
/// and, worse, unshared: PLY002, PLY003 and PLY004 all need the same reference
/// material.
///
/// So the shape of a score is data here, and `MusicXMLScoreFixtures` composes
/// that data into the increment's reference set. Later leaves extend these
/// types rather than growing a second fixture vocabulary.
///
/// Everything is a pure function of its arguments: the same call always
/// produces the same bytes, which is what lets the determinism tests mean
/// something.
enum ScoreXML {
    // MARK: Notes

    /// One `<note>`. `pitch` is spelled like `C4`, `F#5`, `Eb3`; nil is a rest.
    struct Note {
        var pitch: String?
        var duration: Int
        var type: String?
        var voice: String = "1"
        var staff: Int?
        var isChord = false
        var tieStart = false
        var tieStop = false
        var fermata = false

        /// Extra `<notations>` children, as raw XML, e.g. `<articulations>…`.
        var notations: [String] = []

        /// Extra `<note>` children, as raw XML.
        var extraChildren: [String] = []

        init(
            pitch: String?,
            duration: Int,
            type: String? = nil,
            voice: String = "1",
            staff: Int? = nil,
            isChord: Bool = false,
            tieStart: Bool = false,
            tieStop: Bool = false,
            fermata: Bool = false,
            notations: [String] = [],
            extraChildren: [String] = []
        ) {
            self.pitch = pitch
            self.duration = duration
            self.type = type
            self.voice = voice
            self.staff = staff
            self.isChord = isChord
            self.tieStart = tieStart
            self.tieStop = tieStop
            self.fermata = fermata
            self.notations = notations
            self.extraChildren = extraChildren
        }

        func xml() -> String {
            var body = ""
            if isChord { body += "<chord/>" }
            if let pitch, let parsed = ScoreXML.parsePitch(pitch) {
                body += "<pitch><step>\(parsed.step)</step>"
                if parsed.alter != 0 { body += "<alter>\(parsed.alter)</alter>" }
                body += "<octave>\(parsed.octave)</octave></pitch>"
            } else {
                body += "<rest/>"
            }
            body += "<duration>\(duration)</duration>"
            if tieStart { body += #"<tie type="start"/>"# }
            if tieStop { body += #"<tie type="stop"/>"# }
            body += "<voice>\(voice)</voice>"
            if let type { body += "<type>\(type)</type>" }
            if let staff { body += "<staff>\(staff)</staff>" }
            for child in extraChildren { body += child }

            var inner = notations
            if fermata { inner.append("<fermata/>") }
            if !inner.isEmpty { body += "<notations>\(inner.joined())</notations>" }
            return "<note>\(body)</note>"
        }
    }

    // MARK: Notation shorthands

    /// Raw XML for the expressive `<notations>` children PLY002 realizes.
    ///
    /// Written as small builders rather than literals in each test because the
    /// same handful of markings appears in every expressive fixture, and one
    /// mistyped element name would silently turn a golden test into a test of
    /// the report instead.
    enum Notation {
        /// `<ornaments><trill-mark/></ornaments>`, optionally with a printed
        /// accidental over the sign.
        static func ornament(
            _ name: String,
            accidental: String? = nil,
            placement: String = "above"
        ) -> String {
            var body = "<\(name)/>"
            if let accidental {
                body += #"<accidental-mark placement="\#(placement)">\#(accidental)</accidental-mark>"#
            }
            return "<ornaments>\(body)</ornaments>"
        }

        /// `<articulations><staccato/><accent/></articulations>`.
        static func articulations(_ names: [String]) -> String {
            "<articulations>\(names.map { "<\($0)/>" }.joined())</articulations>"
        }

        /// `<dynamics><sf/></dynamics>` attached to a note.
        static func dynamics(_ name: String) -> String {
            "<dynamics><\(name)/></dynamics>"
        }

        static func slurStart(_ number: Int = 1) -> String {
            #"<slur type="start" number="\#(number)"/>"#
        }

        static func slurStop(_ number: Int = 1) -> String {
            #"<slur type="stop" number="\#(number)"/>"#
        }
    }

    /// A `<note>` carrying `<grace>`.
    ///
    /// Grace notes have no `<duration>` in MusicXML — they take their time
    /// from the notes around them — so this writes none.
    static func graceNote(
        pitch: String,
        type: String = "eighth",
        slashed: Bool = false,
        voice: String = "1",
        staff: Int? = nil,
        isChord: Bool = false,
        stealTimeFollowing: Int? = nil,
        stealTimePrevious: Int? = nil
    ) -> Note {
        var attributes = ""
        if slashed { attributes += #" slash="yes""# }
        if let stealTimeFollowing {
            attributes += #" steal-time-following="\#(stealTimeFollowing)""#
        }
        if let stealTimePrevious {
            attributes += #" steal-time-previous="\#(stealTimePrevious)""#
        }
        return Note(
            pitch: pitch,
            duration: 0,
            type: type,
            voice: voice,
            staff: staff,
            isChord: isChord,
            extraChildren: ["<grace\(attributes)/>"]
        )
    }

    /// `C4`, `F#5`, `Eb3` → step, alter, octave.
    static func parsePitch(_ text: String) -> (step: String, alter: Int, octave: Int)? {
        var characters = Array(text)
        guard let first = characters.first, first.isLetter else { return nil }
        characters.removeFirst()

        var alter = 0
        while let next = characters.first, next == "#" || next == "b" {
            alter += next == "#" ? 1 : -1
            characters.removeFirst()
        }
        guard let octave = Int(String(characters)) else { return nil }
        return (String(first).uppercased(), alter, octave)
    }

    // MARK: Attributes

    struct Attributes {
        var divisions: Int?
        var fifths: Int?
        var time: (beats: Int, beatType: Int)?
        var staves: Int?
        var clefs: [(sign: String, line: Int)] = []
        var transposeChromatic: Int?
        var raw: [String] = []

        func xml() -> String {
            var body = ""
            if let divisions { body += "<divisions>\(divisions)</divisions>" }
            if let fifths { body += "<key><fifths>\(fifths)</fifths></key>" }
            if let time {
                body += "<time><beats>\(time.beats)</beats>"
                body += "<beat-type>\(time.beatType)</beat-type></time>"
            }
            if let staves { body += "<staves>\(staves)</staves>" }
            for (index, clef) in clefs.enumerated() {
                let number = clefs.count > 1 ? #" number="\#(index + 1)""# : ""
                body += "<clef\(number)><sign>\(clef.sign)</sign><line>\(clef.line)</line></clef>"
            }
            if let transposeChromatic {
                body += "<transpose><chromatic>\(transposeChromatic)</chromatic></transpose>"
            }
            body += raw.joined()
            return body.isEmpty ? "" : "<attributes>\(body)</attributes>"
        }
    }

    // MARK: Directions

    struct Direction {
        var words: String?
        var metronome: (beatUnit: String, perMinute: Int)?
        var segno = false
        var coda = false

        /// `<staff>`: the one staff of the part this direction governs.
        var staff: Int?

        /// `<offset>`, in the part's own divisions.
        var offset: Int?

        /// Attributes for a `<sound>` element, e.g. `["tempo": "96"]`.
        var sound: [String: String] = [:]

        /// Extra `<direction-type>` children, as raw XML.
        var raw: [String] = []

        func xml() -> String {
            var types: [String] = []
            if segno { types.append("<segno/>") }
            if coda { types.append("<coda/>") }
            if let words { types.append("<words>\(ScoreXML.escape(words))</words>") }
            if let metronome {
                types.append(
                    "<metronome><beat-unit>\(metronome.beatUnit)</beat-unit>"
                        + "<per-minute>\(metronome.perMinute)</per-minute></metronome>"
                )
            }
            types.append(contentsOf: raw)

            var body = types.map { "<direction-type>\($0)</direction-type>" }.joined()
            if let offset { body += "<offset>\(offset)</offset>" }
            if let staff { body += "<staff>\(staff)</staff>" }
            if !sound.isEmpty {
                let attributes = sound.keys.sorted()
                    .map { #"\#($0)="\#(ScoreXML.escape(sound[$0] ?? ""))""# }
                    .joined(separator: " ")
                body += "<sound \(attributes)/>"
            }
            return body.isEmpty ? "" : #"<direction placement="above">\#(body)</direction>"#
        }

        // MARK: Expressive shorthands

        /// `<dynamics><p/></dynamics>` and friends.
        static func dynamic(_ mark: String, staff: Int? = nil) -> Direction {
            Direction(staff: staff, raw: ["<dynamics><\(mark)/></dynamics>"])
        }

        /// `<wedge type="crescendo"/>` and friends.
        static func wedge(_ type: String, staff: Int? = nil, offset: Int? = nil) -> Direction {
            Direction(staff: staff, offset: offset, raw: [#"<wedge type="\#(type)"/>"#])
        }

        /// `<pedal type="start"/>` and friends.
        static func pedal(_ type: String, staff: Int? = nil) -> Direction {
            Direction(staff: staff, raw: [#"<pedal type="\#(type)" line="yes"/>"#])
        }
    }

    // MARK: Barlines

    struct Barline {
        var location: String
        var repeatDirection: String?
        var repeatTimes: Int?
        var endingNumbers: String?
        var endingType: String?

        static func forwardRepeat() -> Barline {
            Barline(location: "left", repeatDirection: "forward")
        }

        static func backwardRepeat(times: Int? = nil) -> Barline {
            Barline(location: "right", repeatDirection: "backward", repeatTimes: times)
        }

        static func endingStart(_ numbers: String) -> Barline {
            Barline(location: "left", endingNumbers: numbers, endingType: "start")
        }

        static func endingStop(_ numbers: String, withRepeat: Bool) -> Barline {
            Barline(
                location: "right",
                repeatDirection: withRepeat ? "backward" : nil,
                endingNumbers: numbers,
                endingType: withRepeat ? "stop" : "discontinue"
            )
        }

        func xml() -> String {
            var body = ""
            if let endingNumbers, let endingType {
                body += #"<ending number="\#(endingNumbers)" type="\#(endingType)"/>"#
            }
            if let repeatDirection {
                let times = repeatTimes.map { #" times="\#($0)""# } ?? ""
                body += #"<repeat direction="\#(repeatDirection)"\#(times)/>"#
            }
            return body.isEmpty ? "" : #"<barline location="\#(location)">\#(body)</barline>"#
        }
    }

    // MARK: Measures and parts

    enum Item {
        case note(Note)
        case backup(Int)
        case forward(Int)
        case attributes(Attributes)
        case direction(Direction)
        case barline(Barline)
        case raw(String)

        func xml() -> String {
            switch self {
            case .note(let note): return note.xml()
            case .backup(let duration): return "<backup><duration>\(duration)</duration></backup>"
            case .forward(let duration): return "<forward><duration>\(duration)</duration></forward>"
            case .attributes(let attributes): return attributes.xml()
            case .direction(let direction): return direction.xml()
            case .barline(let barline): return barline.xml()
            case .raw(let text): return text
            }
        }
    }

    struct Measure {
        var number: String
        var implicit = false
        var items: [Item] = []

        func xml() -> String {
            let implicitAttribute = implicit ? #" implicit="yes""# : ""
            let body = items.map { $0.xml() }.joined()
            return #"<measure number="\#(ScoreXML.escape(number))"\#(implicitAttribute)>\#(body)</measure>"#
        }
    }

    struct Part {
        var id: String
        var name: String
        var abbreviation: String?
        var measures: [Measure] = []
    }

    struct Score {
        var workTitle: String?
        var movementTitle: String?
        var composer: String?
        var parts: [Part] = []

        func data() -> Data {
            var chunks: [String] = [
                #"<?xml version="1.0" encoding="UTF-8"?>"#,
                #"<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">"#,
                #"<score-partwise version="4.0">"#
            ]
            if let workTitle {
                chunks.append("<work><work-title>\(ScoreXML.escape(workTitle))</work-title></work>")
            }
            if let movementTitle {
                chunks.append("<movement-title>\(ScoreXML.escape(movementTitle))</movement-title>")
            }
            if let composer {
                chunks.append(
                    "<identification>"
                        + #"<creator type="composer">\#(ScoreXML.escape(composer))</creator>"#
                        + "</identification>"
                )
            }

            chunks.append("<part-list>")
            for part in parts {
                var body = "<part-name>\(ScoreXML.escape(part.name))</part-name>"
                if let abbreviation = part.abbreviation {
                    body += "<part-abbreviation>\(ScoreXML.escape(abbreviation))</part-abbreviation>"
                }
                chunks.append(#"<score-part id="\#(ScoreXML.escape(part.id))">\#(body)</score-part>"#)
            }
            chunks.append("</part-list>")

            for part in parts {
                chunks.append(#"<part id="\#(ScoreXML.escape(part.id))">"#)
                for measure in part.measures { chunks.append(measure.xml()) }
                chunks.append("</part>")
            }
            chunks.append("</score-partwise>")
            return Data(chunks.joined(separator: "\n").utf8)
        }
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// The increment's reference scores.
///
/// Two groups:
///
/// - **the reference set** — a keyboard fugue, a string quartet and an
///   orchestral excerpt — crafted at realistic density so every leaf of
///   increment 002 is exercised against the same three pieces. The approved
///   plan calls for exactly this; the owner's own files stay the owner-side
///   verification flow, not an automated gate.
/// - **criterion fixtures** — small scores each aimed at one acceptance
///   criterion: expansion, tempo and fermatas, unhonoured notation, and
///   notation that contradicts itself.
///
/// `orchestralExcerpt` takes its part count, measure count and note density as
/// arguments: PLY003 (#15) reuses it as the dropout guardrail and needs to
/// turn the load up.
enum MusicXMLScoreFixtures {
    /// Divisions used by every fixture here: 4 ticks to the quarter, so
    /// sixteenth notes are whole numbers and the arithmetic in a failing test
    /// is readable.
    static let divisions = 4
    static let quarter = 4
    static let half = 8
    static let whole = 16
    static let eighth = 2

    // MARK: Reference set

    /// A four-voice keyboard fugue exposition: one part, two staves, four
    /// genuinely independent voices entering in turn.
    ///
    /// This is the REQ-005 line-identity fixture. The voices are the fugal
    /// voices, not staves, which is exactly the distinction a piano roll gets
    /// wrong and a preset must not.
    /// - Parameter measureCount: how far the exposition runs. Varying it is
    ///   how the line-identity tests prove that identifiers do not depend on
    ///   how much music follows them.
    static func keyboardFugueExposition(measureCount: Int = 10) -> Data {
        // Subject, answer at the fifth, and two later entries. Each voice
        // rests until its entry, then runs the subject and continues in
        // counterpoint, so the voices overlap the way a fugue's do.
        let subject = ["C5", "G4", "Ab4", "B4", "C5", "D5", "Eb5", "D5"]
        let answer = ["G5", "D5", "Eb5", "F#5", "G5", "A5", "Bb5", "A5"]
        let tenor = ["C4", "G3", "Ab3", "B3", "C4", "D4", "Eb4", "D4"]
        let bass = ["C3", "G2", "Ab2", "B2", "C3", "D3", "Eb3", "D3"]

        let voices: [(voice: String, staff: Int, entryMeasure: Int, notes: [String])] = [
            ("1", 1, 0, subject),
            ("2", 1, 2, answer),
            ("5", 2, 4, tenor),
            ("6", 2, 6, bass)
        ]

        var measures: [ScoreXML.Measure] = []
        for measureIndex in 0..<measureCount {
            var items: [ScoreXML.Item] = []
            if measureIndex == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(
                            divisions: divisions,
                            fifths: -3,
                            time: (4, 4),
                            staves: 2,
                            clefs: [("G", 2), ("F", 4)]
                        )
                    )
                )
                items.append(
                    .direction(ScoreXML.Direction(metronome: ("quarter", 72), sound: ["tempo": "72"]))
                )
            }

            for (index, voice) in voices.enumerated() {
                if index > 0 { items.append(.backup(whole)) }
                items.append(
                    contentsOf: fugueVoiceMeasure(
                        measureIndex: measureIndex,
                        entryMeasure: voice.entryMeasure,
                        notes: voice.notes,
                        voice: voice.voice,
                        staff: voice.staff
                    )
                )
            }
            measures.append(ScoreXML.Measure(number: String(measureIndex + 1), items: items))
        }

        return ScoreXML.Score(
            workTitle: "Fugue in C minor",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: measures)]
        ).data()
    }

    /// One measure of one fugal voice: silent before its entry, the subject at
    /// its entry, then a deterministic continuation.
    private static func fugueVoiceMeasure(
        measureIndex: Int,
        entryMeasure: Int,
        notes: [String],
        voice: String,
        staff: Int
    ) -> [ScoreXML.Item] {
        guard measureIndex >= entryMeasure else {
            return [.note(ScoreXML.Note(pitch: nil, duration: whole, type: "whole", voice: voice, staff: staff))]
        }
        let offset = ((measureIndex - entryMeasure) * 4) % notes.count
        return (0..<4).map { beat in
            .note(
                ScoreXML.Note(
                    pitch: notes[(offset + beat) % notes.count],
                    duration: quarter,
                    type: "quarter",
                    voice: voice,
                    staff: staff
                )
            )
        }
    }

    /// A four-part string quartet movement: one part per instrument, with the
    /// phrase slurs a real edition carries. PLY002 realizes those as legato,
    /// so the reference set exercises the slur path at four-part density.
    static func stringQuartetMovement() -> Data {
        let instruments: [(id: String, name: String, abbreviation: String, register: [String])] = [
            ("P1", "Violin I", "Vln. I", ["D5", "F#5", "A5", "D6", "A5", "F#5"]),
            ("P2", "Violin II", "Vln. II", ["A4", "D5", "F#5", "A5", "F#5", "D5"]),
            ("P3", "Viola", "Vla.", ["F#4", "A4", "D5", "F#5", "D5", "A4"]),
            ("P4", "Cello", "Vc.", ["D3", "A3", "D4", "A3", "F#3", "D3"])
        ]
        let measureCount = 16

        let parts = instruments.enumerated().map { partIndex, instrument in
            var measures: [ScoreXML.Measure] = []
            for measureIndex in 0..<measureCount {
                var items: [ScoreXML.Item] = []
                if measureIndex == 0 {
                    items.append(
                        .attributes(
                            ScoreXML.Attributes(
                                divisions: divisions,
                                fifths: 2,
                                time: (4, 4),
                                clefs: [(partIndex == 3 ? "F" : (partIndex == 2 ? "C" : "G"), partIndex == 3 ? 4 : (partIndex == 2 ? 3 : 2))]
                            )
                        )
                    )
                    if partIndex == 0 {
                        items.append(
                            .direction(
                                ScoreXML.Direction(
                                    words: "Allegro",
                                    metronome: ("quarter", 132),
                                    sound: ["tempo": "132"]
                                )
                            )
                        )
                    }
                }
                if measureIndex == 8, partIndex == 0 {
                    items.append(
                        .direction(ScoreXML.Direction(words: "Meno mosso", sound: ["tempo": "96"]))
                    )
                }

                for beat in 0..<4 {
                    let step = (measureIndex * 4 + beat + partIndex) % instrument.register.count
                    items.append(
                        .note(
                            ScoreXML.Note(
                                pitch: instrument.register[step],
                                duration: quarter,
                                type: "quarter",
                                notations: beat == 0
                                    ? [#"<slur type="start" number="1"/>"#]
                                    : (beat == 3 ? [#"<slur type="stop" number="1"/>"#] : []),
                                extraChildren: []
                            )
                        )
                    )
                }
                measures.append(ScoreXML.Measure(number: String(measureIndex + 1), items: items))
            }
            return ScoreXML.Part(
                id: instrument.id,
                name: instrument.name,
                abbreviation: instrument.abbreviation,
                measures: measures
            )
        }

        return ScoreXML.Score(
            workTitle: "Quartet in D",
            composer: "Fixture",
            parts: parts
        ).data()
    }

    /// An orchestral excerpt of realistic density.
    ///
    /// - Parameters:
    ///   - partCount: how many instrument parts. The default 18 is a small
    ///     classical orchestra; raise it to load-test.
    ///   - measureCount: how many measures each part carries.
    ///   - notesPerMeasure: notes per part per measure. This is the density
    ///     knob PLY003 turns for its dropout guardrail — total note count is
    ///     `partCount * measureCount * notesPerMeasure`.
    static func orchestralExcerpt(
        partCount: Int = 18,
        measureCount: Int = 32,
        notesPerMeasure: Int = 8
    ) -> Data {
        precondition(partCount > 0 && measureCount > 0 && notesPerMeasure > 0)

        // Two of the parts transpose, because a real orchestral score has
        // transposing instruments and sounding pitch is the compiler's job.
        let names = [
            "Flute", "Oboe", "Clarinet in B♭", "Bassoon", "Horn in F", "Trumpet in B♭",
            "Trombone", "Tuba", "Timpani", "Harp", "Violin I", "Violin II",
            "Viola", "Violoncello", "Contrabass", "Piccolo", "Cor anglais", "Contrabassoon"
        ]
        let transpositions = ["Clarinet in B♭": -2, "Horn in F": -7, "Trumpet in B♭": -2]
        let scaleDegrees = ["C", "D", "E", "F", "G", "A", "B"]
        let noteTicks = max(1, (divisions * 4) / notesPerMeasure)

        let parts = (0..<partCount).map { partIndex -> ScoreXML.Part in
            let name = partIndex < names.count ? names[partIndex] : "Instrument \(partIndex + 1)"
            let octave = 5 - (partIndex % 4)

            var measures: [ScoreXML.Measure] = []
            for measureIndex in 0..<measureCount {
                var items: [ScoreXML.Item] = []
                if measureIndex == 0 {
                    items.append(
                        .attributes(
                            ScoreXML.Attributes(
                                divisions: divisions,
                                fifths: 0,
                                time: (4, 4),
                                clefs: [(octave <= 3 ? "F" : "G", octave <= 3 ? 4 : 2)],
                                transposeChromatic: transpositions[name]
                            )
                        )
                    )
                    if partIndex == 0 {
                        items.append(
                            .direction(
                                ScoreXML.Direction(words: "Allegro con brio", sound: ["tempo": "144"])
                            )
                        )
                    }
                }
                for step in 0..<notesPerMeasure {
                    // Deterministic, and different per part so the parts are
                    // not one line copied N times.
                    let degree = (measureIndex * notesPerMeasure + step + partIndex * 3) % scaleDegrees.count
                    items.append(
                        .note(
                            ScoreXML.Note(
                                pitch: "\(scaleDegrees[degree])\(octave)",
                                duration: noteTicks,
                                type: notesPerMeasure == 8 ? "eighth" : nil
                            )
                        )
                    )
                }
                measures.append(ScoreXML.Measure(number: String(measureIndex + 1), items: items))
            }
            return ScoreXML.Part(id: "P\(partIndex + 1)", name: name, measures: measures)
        }

        return ScoreXML.Score(
            workTitle: "Orchestral Excerpt",
            composer: "Fixture",
            parts: parts
        ).data()
    }

    // MARK: Criterion fixtures

    /// Repeats, first and second endings, and `D.C. al Fine` in one score.
    ///
    /// Eight measures, laid out so the expanded order is unambiguous:
    ///
    /// | measure | structure |
    /// | --- | --- |
    /// | 1 | plain |
    /// | 2 | forward repeat |
    /// | 3 | `Fine` |
    /// | 4 | first ending, backward repeat |
    /// | 5 | second ending |
    /// | 6 | plain |
    /// | 7 | plain |
    /// | 8 | `D.C. al Fine` |
    ///
    /// Played: 1 2 3 4 2 3 5 6 7 8 1 2 3.
    static func repeatsVoltasAndDaCapo() -> Data {
        let pitches = ["C4", "D4", "E4", "F4", "G4", "A4", "B4", "C5"]
        var measures: [ScoreXML.Measure] = []

        for index in 0..<8 {
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(divisions: divisions, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                    )
                )
                items.append(.direction(ScoreXML.Direction(sound: ["tempo": "120"])))
            }
            if index == 1 { items.append(.barline(.forwardRepeat())) }
            if index == 3 { items.append(.barline(.endingStart("1"))) }
            if index == 4 { items.append(.barline(.endingStart("2"))) }

            if index == 2 {
                items.append(.direction(ScoreXML.Direction(words: "Fine", sound: ["fine": "yes"])))
            }
            if index == 7 {
                items.append(
                    .direction(ScoreXML.Direction(words: "D.C. al Fine", sound: ["dacapo": "yes"]))
                )
            }

            items.append(
                .note(ScoreXML.Note(pitch: pitches[index], duration: whole, type: "whole"))
            )

            if index == 3 { items.append(.barline(.endingStop("1", withRepeat: true))) }
            if index == 4 { items.append(.barline(.endingStop("2", withRepeat: false))) }

            measures.append(ScoreXML.Measure(number: String(index + 1), items: items))
        }

        return ScoreXML.Score(
            workTitle: "Repeat Structure Study",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Keyboard", measures: measures)]
        ).data()
    }

    /// `D.S. al Coda`: a segno, a `To Coda` that is inert until the jump has
    /// happened, and a coda section reached only on the second pass.
    ///
    /// | measure | structure |
    /// | --- | --- |
    /// | 2 | segno |
    /// | 4 | `To Coda` |
    /// | 6 | `D.S. al Coda` |
    /// | 7 | coda |
    ///
    /// Played: 1 2 3 4 5 6 2 3 4 7 8.
    static func dalSegnoAlCoda() -> Data {
        var measures: [ScoreXML.Measure] = []
        for index in 0..<8 {
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(divisions: divisions, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                    )
                )
                items.append(.direction(ScoreXML.Direction(sound: ["tempo": "120"])))
            }
            switch index {
            case 1:
                items.append(.direction(ScoreXML.Direction(segno: true, sound: ["segno": "Segno"])))
            case 3:
                items.append(
                    .direction(ScoreXML.Direction(words: "To Coda", sound: ["tocoda": "Coda"]))
                )
            case 5:
                items.append(
                    .direction(ScoreXML.Direction(words: "D.S. al Coda", sound: ["dalsegno": "Segno"]))
                )
            case 6:
                items.append(.direction(ScoreXML.Direction(coda: true, sound: ["coda": "Coda"])))
            default:
                break
            }
            items.append(.note(ScoreXML.Note(pitch: "C4", duration: whole, type: "whole")))
            measures.append(ScoreXML.Measure(number: String(index + 1), items: items))
        }

        return ScoreXML.Score(
            workTitle: "Segno and Coda Study",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Keyboard", measures: measures)]
        ).data()
    }

    /// A pickup measure, two tempo changes and a fermata over the last note.
    ///
    /// ♩=60 for measures 1–2, ♩=120 from measure 3, and a fermata on the final
    /// whole note.
    static func tempoChangesAndFermata() -> Data {
        var measures: [ScoreXML.Measure] = [
            ScoreXML.Measure(
                number: "0",
                implicit: true,
                items: [
                    .attributes(
                        ScoreXML.Attributes(divisions: divisions, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                    ),
                    .direction(ScoreXML.Direction(metronome: ("quarter", 60), sound: ["tempo": "60"])),
                    .note(ScoreXML.Note(pitch: "G4", duration: quarter, type: "quarter"))
                ]
            )
        ]

        for index in 1...4 {
            var items: [ScoreXML.Item] = []
            if index == 3 {
                items.append(
                    .direction(ScoreXML.Direction(metronome: ("quarter", 120), sound: ["tempo": "120"]))
                )
            }
            let isLast = index == 4
            items.append(
                .note(
                    ScoreXML.Note(
                        pitch: isLast ? "C4" : "E4",
                        duration: whole,
                        type: "whole",
                        fermata: isLast
                    )
                )
            )
            measures.append(ScoreXML.Measure(number: String(index), items: items))
        }

        return ScoreXML.Score(
            workTitle: "Tempo and Fermata Study",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Voice", measures: measures)]
        ).data()
    }

    /// A score whose only unusual feature is one unsupported marking, so a
    /// test can assert on exactly that entry.
    ///
    /// - Parameter marking: raw XML for a `<notations>` child. The default is
    ///   a `schleifer` — a slide ornament this build genuinely does not
    ///   realize. It used to be a mordent; PLY002 sounds mordents now, and a
    ///   fixture named "unsupported" must keep naming something that is.
    static func unsupportedMarking(
        _ marking: String = "<ornaments><schleifer/></ornaments>",
        inMeasure markedMeasure: Int = 2
    ) -> Data {
        let measures = (1...3).map { number -> ScoreXML.Measure in
            var items: [ScoreXML.Item] = []
            if number == 1 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(divisions: divisions, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                    )
                )
                items.append(.direction(ScoreXML.Direction(sound: ["tempo": "100"])))
            }
            items.append(
                .note(
                    ScoreXML.Note(
                        pitch: "C4",
                        duration: whole,
                        type: "whole",
                        notations: number == markedMeasure ? [marking] : []
                    )
                )
            )
            return ScoreXML.Measure(number: String(number), items: items)
        }

        return ScoreXML.Score(
            workTitle: "Unsupported Marking Study",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Recorder", measures: measures)]
        ).data()
    }

    /// A score that contradicts itself: a backward repeat with no forward
    /// repeat to answer it, a forward repeat that nothing ever closes, and a
    /// `D.S.` with no segno anywhere.
    static func contradictoryStructure() -> Data {
        var measures: [ScoreXML.Measure] = []
        for index in 0..<5 {
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(divisions: divisions, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                    )
                )
                items.append(.direction(ScoreXML.Direction(sound: ["tempo": "120"])))
            }
            if index == 3 { items.append(.barline(.forwardRepeat())) }
            if index == 4 {
                items.append(
                    .direction(ScoreXML.Direction(words: "D.S. al Fine", sound: ["dalsegno": "Segno"]))
                )
            }

            items.append(.note(ScoreXML.Note(pitch: "C4", duration: whole, type: "whole")))

            if index == 1 { items.append(.barline(.backwardRepeat())) }
            measures.append(ScoreXML.Measure(number: String(index + 1), items: items))
        }

        return ScoreXML.Score(
            workTitle: "Contradictory Structure Study",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Keyboard", measures: measures)]
        ).data()
    }

    /// Several parts carrying the same unsupported marking many times, for the
    /// report's aggregation rule.
    ///
    /// The string quartet used to serve this, on its slurs. PLY002 realizes
    /// slurs, so proving aggregation now needs a fixture whose marking is
    /// genuinely beyond this build — otherwise the test would quietly stop
    /// testing anything.
    static func repeatedUnsupportedMarkingAcrossParts(
        partCount: Int = 4,
        markingsPerPart: Int = 8
    ) -> Data {
        let parts = (0..<partCount).map { partIndex -> ScoreXML.Part in
            let measures = (0..<markingsPerPart).map { measureIndex -> ScoreXML.Measure in
                var items: [ScoreXML.Item] = []
                if measureIndex == 0 {
                    items.append(
                        .attributes(
                            ScoreXML.Attributes(
                                divisions: divisions,
                                fifths: 0,
                                time: (4, 4),
                                clefs: [("G", 2)]
                            )
                        )
                    )
                }
                items.append(
                    .note(
                        ScoreXML.Note(
                            pitch: "C4",
                            duration: whole,
                            type: "whole",
                            notations: ["<technical><up-bow/></technical>"]
                        )
                    )
                )
                return ScoreXML.Measure(number: String(measureIndex + 1), items: items)
            }
            return ScoreXML.Part(
                id: "P\(partIndex + 1)",
                name: "Instrument \(partIndex + 1)",
                measures: measures
            )
        }

        return ScoreXML.Score(
            workTitle: "Aggregation Study",
            composer: "Fixture",
            parts: parts
        ).data()
    }

    // MARK: Expressive criterion fixtures (PLY002)

    /// Divisions for the expressive fixtures: 24 to the quarter, so a
    /// thirty-second note — the grid an ornament is realized on — is a whole
    /// number of ticks and a failing assertion reads as music.
    static let fineDivisions = 24
    static let fineQuarter = 24
    static let fineEighth = 12
    static let fineHalf = 48
    static let fineWhole = 96

    /// One half note per ornament sign, in C major so every auxiliary note is
    /// a white key and the expected figure is obvious by eye.
    ///
    /// | measure | sign | expected figure from C5 |
    /// | --- | --- | --- |
    /// | 1 | `trill-mark` | C5 D5 C5 D5 … ending on C5 |
    /// | 2 | `mordent` | C5 B4 C5 |
    /// | 3 | `inverted-mordent` | C5 D5 C5 |
    /// | 4 | `turn` | D5 C5 B4 C5 |
    /// | 5 | `inverted-turn` | B4 C5 D5 C5 |
    static func ornamentStudy() -> Data {
        let signs = ["trill-mark", "mordent", "inverted-mordent", "turn", "inverted-turn"]

        let measures = signs.enumerated().map { index, sign -> ScoreXML.Measure in
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(
                            divisions: fineDivisions,
                            fifths: 0,
                            time: (4, 4),
                            clefs: [("G", 2)]
                        )
                    )
                )
                items.append(.direction(ScoreXML.Direction(sound: ["tempo": "60"])))
            }
            items.append(
                .note(
                    ScoreXML.Note(
                        pitch: "C5",
                        duration: fineHalf,
                        type: "half",
                        notations: [ScoreXML.Notation.ornament(sign)]
                    )
                )
            )
            items.append(.note(ScoreXML.Note(pitch: "G4", duration: fineHalf, type: "half")))
            return ScoreXML.Measure(number: String(index + 1), items: items)
        }

        return ScoreXML.Score(
            workTitle: "Ornament Study",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Flute", measures: measures)]
        ).data()
    }

    /// A crescendo written the way an engraver writes one: `p`, a hairpin over
    /// two measures, and the `f` it arrives at printed on the downbeat after
    /// the hairpin closes.
    ///
    /// Sixteen eighth notes fall inside the span, which is enough for the
    /// loudness to be measurably rising note by note rather than in two steps.
    /// - Parameter diminuendo: writes the mirror image — `f`, a diminuendo,
    ///   `p` — so the same fixture proves the downward direction too.
    static func hairpinSpan(diminuendo: Bool = false) -> Data {
        let opening = diminuendo ? "f" : "p"
        let closing = diminuendo ? "p" : "f"
        let wedge = diminuendo ? "diminuendo" : "crescendo"
        let pitches = ["C4", "D4", "E4", "F4", "G4", "A4", "B4", "C5"]

        var measures: [ScoreXML.Measure] = []
        for measureIndex in 0..<3 {
            var items: [ScoreXML.Item] = []
            if measureIndex == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(
                            divisions: fineDivisions,
                            fifths: 0,
                            time: (4, 4),
                            clefs: [("G", 2)]
                        )
                    )
                )
                items.append(.direction(ScoreXML.Direction(sound: ["tempo": "90"])))
                items.append(.direction(.dynamic(opening)))
                items.append(.direction(.wedge(wedge)))
            }
            if measureIndex == 2 {
                items.append(.direction(.wedge("stop")))
                items.append(.direction(.dynamic(closing)))
            }
            for step in 0..<8 {
                items.append(
                    .note(
                        ScoreXML.Note(
                            pitch: pitches[(measureIndex * 8 + step) % pitches.count],
                            duration: fineEighth,
                            type: "eighth"
                        )
                    )
                )
            }
            measures.append(ScoreXML.Measure(number: String(measureIndex + 1), items: items))
        }

        return ScoreXML.Score(
            workTitle: "Hairpin Study",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Clarinet", measures: measures)]
        ).data()
    }

    /// One measure of plain quarters, one of staccato quarters, one slurred
    /// four-note phrase, and one measure of accents — so each shaping rule can
    /// be measured against the plain reading of the same rhythm.
    static func articulationAndSlurStudy() -> Data {
        let pitches = ["C4", "D4", "E4", "F4"]
        let markings: [[String]] = [[], ["staccato"], [], ["accent"], ["tenuto"]]

        var measures: [ScoreXML.Measure] = []
        for (measureIndex, marks) in markings.enumerated() {
            var items: [ScoreXML.Item] = []
            if measureIndex == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(
                            divisions: fineDivisions,
                            fifths: 0,
                            time: (4, 4),
                            clefs: [("G", 2)]
                        )
                    )
                )
                items.append(.direction(ScoreXML.Direction(sound: ["tempo": "60"])))
            }
            let isSlurred = measureIndex == 2
            for beat in 0..<4 {
                var notations = marks.isEmpty ? [] : [ScoreXML.Notation.articulations(marks)]
                if isSlurred, beat == 0 { notations.append(ScoreXML.Notation.slurStart()) }
                if isSlurred, beat == 3 { notations.append(ScoreXML.Notation.slurStop()) }
                items.append(
                    .note(
                        ScoreXML.Note(
                            pitch: pitches[beat],
                            duration: fineQuarter,
                            type: "quarter",
                            notations: notations
                        )
                    )
                )
            }
            measures.append(ScoreXML.Measure(number: String(measureIndex + 1), items: items))
        }

        return ScoreXML.Score(
            workTitle: "Articulation and Slur Study",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Oboe", measures: measures)]
        ).data()
    }

    /// Pedal down on the first measure, changed on the second, released on the
    /// third — the three markings a pianist's part actually carries.
    static func pedalStudy() -> Data {
        var measures: [ScoreXML.Measure] = []
        for measureIndex in 0..<4 {
            var items: [ScoreXML.Item] = []
            if measureIndex == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(
                            divisions: fineDivisions,
                            fifths: 0,
                            time: (4, 4),
                            clefs: [("G", 2)]
                        )
                    )
                )
                items.append(.direction(ScoreXML.Direction(sound: ["tempo": "60"])))
                items.append(.direction(.pedal("start")))
            }
            if measureIndex == 1 { items.append(.direction(.pedal("change"))) }
            if measureIndex == 2 { items.append(.direction(.pedal("stop"))) }
            items.append(
                .note(ScoreXML.Note(pitch: "C4", duration: fineWhole, type: "whole"))
            )
            measures.append(ScoreXML.Measure(number: String(measureIndex + 1), items: items))
        }

        return ScoreXML.Score(
            workTitle: "Pedal Study",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: measures)]
        ).data()
    }

    /// An acciaccatura, an appoggiatura, and a two-note grace group, each
    /// before a plain half note.
    static func graceNoteStudy() -> Data {
        var measures: [ScoreXML.Measure] = []
        for measureIndex in 0..<3 {
            var items: [ScoreXML.Item] = []
            if measureIndex == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(
                            divisions: fineDivisions,
                            fifths: 0,
                            time: (4, 4),
                            clefs: [("G", 2)]
                        )
                    )
                )
                items.append(.direction(ScoreXML.Direction(sound: ["tempo": "60"])))
            }
            switch measureIndex {
            case 0:
                items.append(.note(ScoreXML.graceNote(pitch: "B4", type: "16th", slashed: true)))
            case 1:
                items.append(.note(ScoreXML.graceNote(pitch: "D5", type: "quarter")))
            default:
                items.append(.note(ScoreXML.graceNote(pitch: "A4", type: "16th", slashed: true)))
                items.append(.note(ScoreXML.graceNote(pitch: "B4", type: "16th", slashed: true)))
            }
            items.append(.note(ScoreXML.Note(pitch: "C5", duration: fineHalf, type: "half")))
            items.append(.note(ScoreXML.Note(pitch: "G4", duration: fineHalf, type: "half")))
            measures.append(ScoreXML.Measure(number: String(measureIndex + 1), items: items))
        }

        return ScoreXML.Score(
            workTitle: "Grace Note Study",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Violin", measures: measures)]
        ).data()
    }

    /// The increment's expressive reference piece: one keyboard part, two
    /// staves, two voices per staff, at the density of a real edition.
    ///
    /// Everything REQ-011 names is present and everything is present more than
    /// once, so a realization bug shows up as a pattern rather than as one odd
    /// event: dynamics and hairpins on both staves, pedal across the whole
    /// piece, slurred phrases in the right hand, articulations in the left,
    /// ornaments at four places, and grace notes at two.
    ///
    /// - Parameter measureCount: how far the piece runs. The reference length
    ///   is 16 measures; PLY003 can turn it up for a load test.
    static func expressiveKeyboardPiece(measureCount: Int = 16) -> Data {
        precondition(measureCount >= 8)

        let treble = ["C5", "D5", "E5", "F5", "G5", "A5", "B5", "C6"]
        let trebleInner = ["E4", "F4", "G4", "A4", "B4", "C5", "D5", "E5"]
        let bass = ["C3", "G3", "E3", "G3", "F3", "A3", "D3", "G3"]
        let ornamentSigns = ["trill-mark", "mordent", "turn", "inverted-mordent"]

        var measures: [ScoreXML.Measure] = []
        for measureIndex in 0..<measureCount {
            var items: [ScoreXML.Item] = []

            if measureIndex == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(
                            divisions: fineDivisions,
                            fifths: -3,
                            time: (4, 4),
                            staves: 2,
                            clefs: [("G", 2), ("F", 4)]
                        )
                    )
                )
                items.append(
                    .direction(
                        ScoreXML.Direction(
                            words: "Andante",
                            metronome: ("quarter", 76),
                            sound: ["tempo": "76"]
                        )
                    )
                )
                items.append(.direction(.dynamic("mp", staff: 1)))
                items.append(.direction(.dynamic("p", staff: 2)))
                items.append(.direction(.pedal("start", staff: 2)))
            }
            // A hairpin every four measures, with its target printed where it
            // closes — the shape a real edition has.
            if measureIndex % 4 == 1 { items.append(.direction(.wedge("crescendo", staff: 1))) }
            if measureIndex % 4 == 3 {
                items.append(.direction(.wedge("stop", staff: 1)))
                items.append(.direction(.dynamic(measureIndex % 8 == 3 ? "f" : "mp", staff: 1)))
            }
            if measureIndex % 4 == 2 { items.append(.direction(.pedal("change", staff: 2))) }
            if measureIndex == measureCount - 1 {
                items.append(.direction(.pedal("stop", staff: 2)))
            }

            // Right hand, voice 1: a slurred four-note phrase, ornamented
            // every fourth measure.
            for beat in 0..<4 {
                var notations: [String] = []
                if beat == 0 { notations.append(ScoreXML.Notation.slurStart()) }
                if beat == 3 { notations.append(ScoreXML.Notation.slurStop()) }
                // Ornaments sit inside the hairpin, not beside it: a trill in
                // the middle of a crescendo is where realization and dynamics
                // have to agree, and a fixture that kept them apart would
                // never ask them to.
                if beat == 0, measureIndex % 4 == 2 {
                    notations.append(
                        ScoreXML.Notation.ornament(
                            ornamentSigns[(measureIndex / 4) % ornamentSigns.count]
                        )
                    )
                }
                if beat == 0, measureIndex % 8 == 5 {
                    items.append(
                        .note(
                            ScoreXML.graceNote(
                                pitch: treble[(measureIndex + 7) % treble.count],
                                type: "16th",
                                slashed: true,
                                voice: "1",
                                staff: 1
                            )
                        )
                    )
                }
                items.append(
                    .note(
                        ScoreXML.Note(
                            pitch: treble[(measureIndex + beat) % treble.count],
                            duration: fineQuarter,
                            type: "quarter",
                            voice: "1",
                            staff: 1,
                            notations: notations
                        )
                    )
                )
            }

            // Right hand, voice 2: sustained inner harmony, tied across the
            // bar so the tie path is exercised at density. A tied pair holds
            // one pitch for two measures — a tie between two different notes
            // is not a tie, and a fixture that wrote one would prove nothing.
            items.append(.backup(fineWhole))
            items.append(
                .note(
                    ScoreXML.Note(
                        pitch: trebleInner[(measureIndex / 2) % trebleInner.count],
                        duration: fineWhole,
                        type: "whole",
                        voice: "2",
                        staff: 1,
                        tieStart: measureIndex.isMultiple(of: 2),
                        tieStop: !measureIndex.isMultiple(of: 2)
                    )
                )
            )

            // Left hand: staccato and accented quarters under the pedal.
            items.append(.backup(fineWhole))
            for beat in 0..<4 {
                let marks = beat.isMultiple(of: 2) ? ["staccato"] : (beat == 1 ? ["accent"] : [])
                items.append(
                    .note(
                        ScoreXML.Note(
                            pitch: bass[(measureIndex * 2 + beat) % bass.count],
                            duration: fineQuarter,
                            type: "quarter",
                            voice: "5",
                            staff: 2,
                            notations: marks.isEmpty
                                ? []
                                : [ScoreXML.Notation.articulations(marks)]
                        )
                    )
                )
            }

            measures.append(ScoreXML.Measure(number: String(measureIndex + 1), items: items))
        }

        return ScoreXML.Score(
            workTitle: "Expressive Keyboard Piece",
            composer: "Fixture",
            parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: measures)]
        ).data()
    }
}
