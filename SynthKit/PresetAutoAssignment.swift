import Foundation

/// Chooses the sound a line starts on when a piece is opened for the first
/// time (REQ-007).
///
/// "The closest available instruments named in the score, else a sensible
/// default." The palette in this build is the synth collection, so *closest*
/// means the closest **category**: a violin line starts on a Strings sound, a
/// trumpet line on a Brass sound, and a keyboard line on the Default Voice —
/// which is exactly what increment 003 already sounded like, so a first open
/// changes nothing audible about a piece the owner has heard before.
///
/// Increment 005 refines this with real instruments (INS003). The shape does
/// not change: this still answers "given a line and a palette, which sound?",
/// and the palette simply grows a second kind.
///
/// **Deterministic.** Two owners with the same score and the same palette get
/// the same initial preset, and creating one twice cannot produce two different
/// answers — the matcher is a pure function and ties inside a category are
/// broken by the palette's own stable list order.
public enum PresetAutoAssignment {
    /// One instrument-name rule: the words that select a category.
    ///
    /// An ordered list rather than a dictionary because the rules overlap.
    /// "Contrabass" contains "bass", "bass clarinet" is a wind and not a bass,
    /// and "string bass" is neither — so the first rule that matches wins and
    /// the order below *is* the disambiguation. A dictionary would make that
    /// ordering invisible and the behaviour dependent on hash order.
    struct Rule {
        let category: SoundCategory
        let words: [String]
    }

    /// The rules, most specific first.
    ///
    /// Deliberately small. This is a starting point the owner immediately
    /// overrides in ASN002, not an orchestration database; a rule earns its
    /// place only when getting it wrong would make a first open sound absurd.
    static let rules: [Rule] = [
        // Reeds and flutes before anything that merely contains "bass":
        // a bass clarinet is a wind, and the palette's closest single-note
        // timbre is a lead.
        Rule(category: .leads, words: [
            "clarinet", "oboe", "flute", "piccolo", "bassoon", "recorder",
            "saxophone", "sax", "cor anglais", "english horn", "shawm", "fife"
        ]),
        // "French horn" is brass; "horn" alone is taken as brass too, which is
        // what an orchestral score means by it.
        Rule(category: .brass, words: [
            "trumpet", "trombone", "tuba", "horn", "cornet", "flugelhorn",
            "euphonium", "brass", "sackbut"
        ]),
        Rule(category: .bells, words: [
            "glockenspiel", "vibraphone", "celesta", "celeste", "chimes",
            "tubular", "carillon", "bell", "marimba", "xylophone"
        ]),
        // Keys before plucks: a *harpsi*chord is a keyboard instrument, and
        // "harp" is a substring of it. Ordering is the disambiguation.
        Rule(category: .keys, words: [
            "piano", "pianoforte", "fortepiano", "keyboard", "harpsichord",
            "cembalo", "clavichord", "clavier", "organ", "positive"
        ]),
        Rule(category: .plucks, words: [
            "guitar", "lute", "theorbo", "mandolin", "banjo", "harp",
            "pizzicato", "zither", "cittern"
        ]),
        // After "contrabassoon" has already gone to leads via "bassoon".
        Rule(category: .bass, words: [
            "contrabass", "double bass", "doublebass", "string bass", "bass"
        ]),
        Rule(category: .strings, words: [
            "violin", "viola", "violoncello", "cello", "string", "viol",
            "fiddle", "gamba"
        ])
    ]

    /// The category this build maps a line to when the score names nothing it
    /// recognises.
    ///
    /// Keys, because the palette's Default Voice lives there: an unrecognised
    /// line falls back to the sound the app has made since increment 002 rather
    /// than to something arbitrary.
    public static let fallbackCategory: SoundCategory = .keys

    /// The category `line` best matches, or `nil` when the score names nothing
    /// this build recognises.
    public static func category(for line: LineEntry) -> SoundCategory? {
        // The part name is the instrument; the line's display name may carry
        // "staff 2, voice 5" noise on top of it, so it is only the fallback.
        for text in [line.partName, line.defaultName].compactMap({ $0 }) {
            let folded = text.lowercased()
            for rule in rules where rule.words.contains(where: { folded.contains($0) }) {
                return rule.category
            }
        }
        return nil
    }

    /// The sound `line` starts on, given `palette`.
    ///
    /// - Returns: `nil` only when the palette is empty, which cannot happen in
    ///   the app — the shipped collection is compiled into the build — but is
    ///   representable, so it is answered rather than crashed on.
    public static func sound(for line: LineEntry, from palette: [SoundEntry]) -> SoundEntry? {
        guard !palette.isEmpty else { return nil }
        let ordered = palette.sorted(by: SoundEntry.isOrderedBefore)

        if let matched = category(for: line),
           let inCategory = ordered.first(where: { $0.category == matched }) {
            return inCategory
        }
        if let fallback = ordered.first(where: { $0.category == fallbackCategory }) {
            return fallback
        }
        // A palette with neither the matched category nor the fallback in it.
        // Answer with something playable rather than leaving the line silent.
        return ordered.first
    }

    /// The initial preset content for a whole piece.
    ///
    /// Every line gets an assignment — REQ-006 has no unassigned state — and a
    /// neutral mixer strip, so the result is immediately playable (REQ-007).
    public static func initialContent(
        for inventory: LineInventory,
        palette: [SoundEntry]
    ) -> PresetContent {
        PresetContent(
            lines: inventory.entries.compactMap { entry in
                guard let sound = sound(for: entry, from: palette) else { return nil }
                return PresetLine(
                    lineID: entry.id,
                    assignment: .library(kind: .synth, soundID: sound.id),
                    mixer: .neutral
                )
            }
        )
    }
}
