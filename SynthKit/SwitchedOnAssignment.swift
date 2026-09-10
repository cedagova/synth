import Foundation

/// A preset that plays the piece the way *Switched-On Bach* would have: every
/// line whose part the score names gets the Baroque Modular sound built for
/// that instrument.
///
/// **By part name only, and never by guessing.** A line is assigned when its
/// `part-name` contains one of the words below; a line with no part name, or
/// a part name that matches nothing, keeps whatever the current preset gives
/// it. The mixer state of every line is carried over untouched — this is a
/// re-orchestration of the mix the owner has, not a new mix.
///
/// The words are ordered most specific first for the reason
/// `PresetAutoAssignment.rules` is: "contrabassoon" contains "bass" and is a
/// reed, "violoncello" contains "cello" and is not a violin, "alto flute" is a
/// flute. The first rule that matches wins, so the order *is* the
/// disambiguation.
public enum SwitchedOnAssignment {
    /// One rule: the words that select a shipped sound.
    public struct Rule: Sendable {
        public let soundID: String
        public let words: [String]
    }

    /// The mapping, in matching order. Every sound named here is shipped, so
    /// a preset made from this table can never point at a sound that is not
    /// there.
    public static let rules: [Rule] = [
        // Reeds before anything containing "bass" (bassoon, contrabassoon).
        Rule(soundID: "shipped.wachet-reed", words: [
            "oboe", "hautbois", "bassoon", "fagott", "clarinet", "clarinetto",
            "cor anglais", "english horn", "sax", "shawm", "dulcian"
        ]),
        // Flutes before the voices, so "alto flute" is a flute.
        Rule(soundID: "shipped.air-flute", words: [
            "flute", "flauto", "flöte", "recorder", "piccolo", "traverso",
            "blockflöte", "fife", "ocarina"
        ]),
        // Brass. "horn" alone is a brass instrument in a score; the English
        // horn has already gone to the reeds above.
        Rule(soundID: "shipped.cantata-trumpet", words: [
            "trumpet", "tromba", "clarino", "horn", "corno", "trombone",
            "cornet", "cornett", "zink", "brass", "sackbut", "tuba"
        ]),
        // Keyboards before plucks ("harpsichord" contains "harp") and before
        // the voices ("continuo" is a keyboard part).
        Rule(soundID: "shipped.modular-harpsichord", words: [
            "harpsichord", "cembalo", "clavecin", "clavier", "clavichord",
            "continuo", "piano", "fortepiano", "keyboard", "spinet", "virginal"
        ]),
        Rule(soundID: "shipped.sinfonia-organ", words: [
            "organ", "organo", "orgel", "orgue", "positive", "harmonium"
        ]),
        // Voices. "bass" as a voice part is caught here only when the score
        // says so; a bare "bass" is the continuo line below.
        Rule(soundID: "shipped.chorale-vox", words: [
            "soprano", "mezzo", "alto", "contralto", "tenor", "baritone",
            "bass voice", "basso", "choir", "chorus", "chor", "voice", "vox",
            "cantus", "vocal", "sopran"
        ]),
        Rule(soundID: "shipped.pizzicato-pulse", words: [
            "lute", "theorbo", "chitarrone", "guitar", "chitarra", "harp",
            "arpa", "pizzicato", "mandolin", "cittern", "archlute"
        ]),
        Rule(soundID: "shipped.clank-box", words: [
            "bell", "glockenspiel", "celesta", "celeste", "carillon", "chime",
            "vibraphone", "xylophone", "marimba"
        ]),
        // The named basses before the strings: "violone" contains "viol" and
        // "contrabass" is not a viol. The bare word "bass" waits until last.
        Rule(soundID: "shipped.continuo-bass", words: [
            "contrabass", "double bass", "doublebass", "string bass", "violone",
            "kontrabass", "contrebasse"
        ]),
        // Strings, highest first. "viola" is not a substring of "violin" and
        // "violoncello" contains "cello", so these three are safe in this
        // order; "viol" (gamba) comes after both. The French singular
        // "violon" is deliberately absent: it is a prefix of "violoncelle"
        // and "violone", both of which are lower instruments. The plural
        // "violons" is safe.
        Rule(soundID: "shipped.brandenburg-violin", words: [
            "violin", "violino", "violons", "fiddle", "geige"
        ]),
        Rule(soundID: "shipped.modular-cello", words: [
            "cello", "violoncell", "viola", "gamba", "viol", "bratsche"
        ]),
        // Last, so the bare word catches only what nothing above claimed.
        Rule(soundID: "shipped.continuo-bass", words: ["bass"])
    ]

    /// The shipped sound this part name calls for, or nil when it names
    /// nothing in the table — or names nothing at all.
    public static func soundID(forPartName partName: String?) -> String? {
        guard let partName else { return nil }
        let text = partName.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        for rule in rules {
            if rule.words.contains(where: { text.contains($0) }) { return rule.soundID }
        }
        return nil
    }

    /// What making the preset would do: the new content, and the counts the
    /// status line reports.
    public struct Plan: Equatable, Sendable {
        public let content: PresetContent
        /// Lines given a Baroque Modular sound.
        public let assignedCount: Int
        /// Lines with a part name the table does not know.
        public let unmatchedCount: Int
        /// Lines whose score gives no part name at all.
        public let unnamedCount: Int

        /// The status-line sentence.
        public func summary(named name: String) -> String {
            var kept: [String] = []
            if unmatchedCount > 0 {
                kept.append("\(unmatchedCount) kept \(unmatchedCount == 1 ? "its" : "their") sound "
                            + "(instrument not in the table)")
            }
            if unnamedCount > 0 {
                kept.append("\(unnamedCount) kept \(unnamedCount == 1 ? "its" : "their") sound "
                            + "(no instrument name in the score)")
            }
            let total = assignedCount + unmatchedCount + unnamedCount
            var sentence = "Made “\(name)”: \(assignedCount) of \(total) line"
                + "\(total == 1 ? "" : "s") given a Switched-On sound"
            if !kept.isEmpty { sentence += "; " + kept.joined(separator: ", ") }
            return sentence + "."
        }
    }

    /// Re-orchestrate `current` for the lines in `inventory`.
    ///
    /// Only the assignment of a matched line changes. Mixer state, the
    /// substitution acknowledgment and humanization all carry over, and a
    /// line the table does not know is left exactly as it was.
    public static func plan(from current: PresetContent, inventory: LineInventory) -> Plan {
        var content = current
        var assigned = 0
        var unmatched = 0
        var unnamed = 0

        for entry in inventory.entries {
            guard let index = content.index(ofLine: entry.id) else { continue }
            guard let partName = entry.partName,
                  !partName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                unnamed += 1
                continue
            }
            guard let soundID = soundID(forPartName: partName) else {
                unmatched += 1
                continue
            }
            content.lines[index].assignment = .library(kind: .synth, soundID: soundID)
            assigned += 1
        }

        return Plan(
            content: content, assignedCount: assigned,
            unmatchedCount: unmatched, unnamedCount: unnamed
        )
    }

    /// The preset's name, and "Switched-On 2" when the piece already has one.
    public static func presetName(existing names: [String]) -> String {
        let base = "Switched-On"
        let taken = Set(names.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }
}
