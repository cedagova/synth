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
/// Increment 005 refines this with real instruments (INS003), and the shape did
/// not change: this still answers "given a line and a palette, which sound?",
/// and the palette simply grew a second kind. What changed is the order of the
/// question — a downloaded instrument named by the score wins over a synth
/// sound in the same category, because "the closest available instruments named
/// in the score" is what REQ-007 asks for and an actual violin is closer to a
/// violin part than a Bowed Strings patch is.
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

    // MARK: Instruments (REQ-007's "closest available instruments")

    /// One instrument-family rule: the words that select a REQ-020 family.
    struct FamilyRule {
        let family: InstrumentCoverage.Family
        let words: [String]
    }

    /// The family rules, most specific first.
    ///
    /// **Ordered for the same reason the category rules are, and with the same
    /// trap in it.** "Harpsichord" contains "harp", and a harpsichord is a
    /// keyboard instrument — so keyboards must be matched before harp or an
    /// orchestral harpsichord part is handed a harp. `PresetLibraryTests`
    /// already pins that for the synth categories; it is pinned here too,
    /// because increment 005 made it doubly live: this build has a harp and no
    /// harpsichord at all, so getting the order wrong would produce a confident
    /// wrong answer rather than a visible gap.
    static let familyRules: [FamilyRule] = [
        FamilyRule(family: .woodwinds, words: [
            "clarinet", "oboe", "flute", "piccolo", "bassoon", "recorder",
            "saxophone", "sax", "cor anglais", "english horn", "shawm", "fife",
            "woodwind"
        ]),
        FamilyRule(family: .brass, words: [
            "trumpet", "trombone", "tuba", "horn", "cornet", "flugelhorn",
            "euphonium", "brass", "sackbut"
        ]),
        FamilyRule(family: .percussion, words: [
            "timpani", "glockenspiel", "vibraphone", "celesta", "celeste",
            "chimes", "tubular", "carillon", "marimba", "xylophone",
            "percussion", "snare", "cymbal", "triangle", "tambourine",
            "bass drum", "drum"
        ]),
        // Keyboards before harp: a *harpsi*chord is a keyboard instrument, and
        // "harp" is a substring of it.
        FamilyRule(family: .keyboards, words: [
            "piano", "pianoforte", "fortepiano", "keyboard", "harpsichord",
            "cembalo", "clavichord", "clavier", "organ", "positive"
        ]),
        FamilyRule(family: .harp, words: ["harp"]),
        FamilyRule(family: .strings, words: [
            "violin", "viola", "violoncello", "cello", "contrabass",
            "double bass", "doublebass", "string bass", "string", "viol",
            "fiddle", "gamba", "bass"
        ])
    ]

    /// The REQ-020 family `line` best matches, or nil when the score names
    /// nothing this build recognises.
    public static func family(for line: LineEntry) -> InstrumentCoverage.Family? {
        for text in [line.partName, line.defaultName].compactMap({ $0 }) {
            let folded = text.lowercased()
            for rule in familyRules where rule.words.contains(where: { folded.contains($0) }) {
                return rule.family
            }
        }
        return nil
    }

    /// The installed instrument `line` should start on, or nil when none fits.
    ///
    /// Two passes, and the order is the whole of "closest available":
    ///
    /// 1. **By name.** A part called "Violin I" and an instrument called
    ///    "Violin section" share the word "violin", so the score's own word
    ///    picks the instrument out of its family. Longer shared words win, so
    ///    "contrabass" beats "bass".
    /// 2. **By family.** Nothing shares a word, so the first instrument of the
    ///    matched family in catalog order plays it — a viola part on a viola
    ///    section, a harpsichord part on whichever keyboard is installed.
    ///
    /// Both passes are inside the matched family, so a "Bass drum" part cannot
    /// land on a contrabass through the word "bass": the family rules put it in
    /// percussion first and the name pass never leaves it.
    ///
    /// Deterministic: ties are broken by the palette's own stable list order,
    /// so two owners with the same score and the same downloads get the same
    /// preset.
    public static func instrument(
        for line: LineEntry, from instruments: [SoundEntry]
    ) -> SoundEntry? {
        guard let family = family(for: line) else { return nil }
        let category = SoundCategory.forInstrumentFamily(family)
        let candidates = instruments
            .filter { $0.origin == .instrument && $0.category == category }
            .sorted(by: SoundEntry.isOrderedBefore)
        guard !candidates.isEmpty else { return nil }

        let text = [line.partName, line.defaultName]
            .compactMap { $0 }.joined(separator: " ").lowercased()

        // The words of the family rule that matched, longest first, so
        // "contrabass" is tried before "bass".
        let words = (familyRules.first { $0.family == family }?.words ?? [])
            .sorted { $0.count > $1.count }

        let wantsSection = namesASection(text)
        for word in words where text.contains(word) {
            let named = candidates.filter { $0.name.lowercased().contains(word) }
            guard !named.isEmpty else { continue }
            // Among the instruments sharing the score's word, prefer the one
            // whose *number of players* matches what the part name implies.
            // The curated set has both "Solo violin" and "Violin section", and
            // handing "Violin I" a solo instrument would be a first open that
            // sounds thin for a reason the owner cannot see.
            if let matched = named.first(where: {
                $0.name.localizedCaseInsensitiveContains("section") == wantsSection
            }) {
                return matched
            }
            return named[0]
        }
        return candidates.first
    }

    /// True when the part name reads as more than one player.
    ///
    /// The three markers orchestral scores actually use: the word itself, a
    /// desk number ("Violin I", "Violin 2"), and the plural ("Violins"). A
    /// chamber part — "Violin", "Cello" — matches none of them and takes the
    /// solo instrument when the catalog has one.
    static func namesASection(_ lowercasedText: String) -> Bool {
        if lowercasedText.contains("section") || lowercasedText.contains("ensemble") { return true }
        for token in lowercasedText.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if token.allSatisfy(\.isNumber) { return true }
            if ["i", "ii", "iii", "iv"].contains(String(token)) { return true }
            // "violins", but not "brass" or "bass".
            if token.count > 4, token.hasSuffix("s"), !token.hasSuffix("ss") { return true }
        }
        return false
    }

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
    /// **Instruments first, then synth categories** (REQ-007's refinement in
    /// increment 005). A downloaded instrument the score actually names is the
    /// closest available thing to that part, so it wins; a piece opened with no
    /// downloads gets exactly what increment 004 gave it, which is why a first
    /// open of a piece the owner already knows sounds the same until they
    /// download something.
    ///
    /// - Returns: `nil` only when the palette is empty, which cannot happen in
    ///   the app — the shipped collection is compiled into the build — but is
    ///   representable, so it is answered rather than crashed on.
    public static func sound(for line: LineEntry, from palette: [SoundEntry]) -> SoundEntry? {
        guard !palette.isEmpty else { return nil }

        if let instrument = instrument(for: line, from: palette) { return instrument }

        // The synth half never offers an instrument by accident: a line the
        // instrument pass could not place must not land on a downloaded
        // instrument merely because its family shares a category with one.
        let ordered = palette
            .filter { $0.origin != .instrument }
            .sorted(by: SoundEntry.isOrderedBefore)
        guard !ordered.isEmpty else {
            return palette.sorted(by: SoundEntry.isOrderedBefore).first
        }

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
    ///
    /// **All or nothing.** A palette that cannot supply a sound for some line is
    /// reported rather than quietly skipping that line, which would produce a
    /// preset that looks real and plays nothing on it. The app cannot reach
    /// that — `ShippedSoundCollection` is compiled into the build, so the
    /// palette is never empty — but this is public API, and a later caller
    /// passing a filtered palette (INS003's "instruments only", say) would.
    /// The symmetric case, an inventory with no lines, is already
    /// `PresetError.pieceHasNoLines`; this is the other half of that guard.
    ///
    /// - Throws: `PresetError.noSoundAvailableForLine`.
    public static func initialContent(
        for inventory: LineInventory,
        palette: [SoundEntry]
    ) throws -> PresetContent {
        PresetContent(
            lines: try inventory.entries.map { entry in
                PresetLine(
                    lineID: entry.id,
                    assignment: try assignment(for: entry, from: palette),
                    mixer: .neutral
                )
            }
        )
    }

    /// The assignment one line starts on, or a reported failure.
    ///
    /// - Throws: `PresetError.noSoundAvailableForLine`.
    public static func assignment(
        for entry: LineEntry,
        from palette: [SoundEntry]
    ) throws -> LineAssignment {
        guard let sound = sound(for: entry, from: palette) else {
            throw PresetError.noSoundAvailableForLine(name: entry.name)
        }
        // The kind comes from the sound rather than from a constant, which is
        // the whole of what ASN001's discriminator was reserved for.
        return .library(kind: sound.kind, soundID: sound.id)
    }
}
