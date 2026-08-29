import Foundation

/// Every way a preset operation can fail.
///
/// Each case names the preset or the piece, because the alert the owner sees
/// has to say which one — and each one is thrown only after the transaction
/// rolled back, so their presets really are as they were.
public enum PresetError: Error, Equatable, Sendable {
    /// The preset was not in the store when the operation ran — another
    /// window, or a stale list.
    case presetNotFound(name: String)

    /// A name that is empty or only whitespace is not a name.
    case nameIsEmpty

    /// A piece with no lines has nothing to assign a sound to. A score that
    /// compiles to zero lines is a broken import, not a preset problem.
    case pieceHasNoLines(pieceID: String)

    /// The palette offered has no sound this line could be given. The
    /// symmetric case to `pieceHasNoLines`, and reported for the same reason:
    /// a preset with a line missing would look real and play nothing on it.
    case noSoundAvailableForLine(name: String)

    /// The preset has no entry for that line.
    case lineNotInPreset(lineID: String)

    /// A piece always has one playable preset (REQ-007), so the last one
    /// cannot be deleted — only replaced or renamed.
    case lastPresetCannotBeDeleted(name: String)

    /// The content is not something this build can store: a duplicate line, a
    /// mixer value out of range, an unplayable embedded copy.
    case documentRejected(name: String, reason: String)

    /// The store refused the write. The presets are exactly as they were.
    case storeFailed(name: String, reason: String)
}

extension PresetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .presetNotFound(let name):
            return "“\(name)” is no longer one of this piece's presets."
        case .nameIsEmpty:
            return "A preset needs a name."
        case .pieceHasNoLines:
            return "Synth found no playable lines in this piece, so it cannot make a preset for it."
        case .noSoundAvailableForLine(let name):
            return "Synth has no sound it can give the line “\(name)”."
        case .lineNotInPreset(let lineID):
            return "This preset has no entry for the line \(lineID)."
        case .lastPresetCannotBeDeleted(let name):
            return "“\(name)” is this piece's only preset and cannot be deleted."
        case .documentRejected(let name, let reason):
            return "Synth could not save “\(name)”: \(reason)"
        case .storeFailed(let name, let reason):
            return "Synth could not save “\(name)”. \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .presetNotFound:
            return "The preset list has been refreshed."
        case .nameIsEmpty:
            return "Type a name and try again."
        case .pieceHasNoLines:
            return "Re-import the score; the file Synth stored may not contain any notes."
        case .noSoundAvailableForLine:
            return "Add a sound to your sound library and open the piece again."
        case .lineNotInPreset:
            return "Reopen the piece to rebuild its line list."
        case .lastPresetCannotBeDeleted:
            return "Make another preset first, or rename this one."
        case .documentRejected:
            return "Bring the value it names back into range and try again."
        case .storeFailed:
            return "Nothing was changed and your presets are intact. Try again; if this keeps happening, the library database may be damaged."
        }
    }
}

/// One preset that references a sound the owner is about to delete.
///
/// What the warning REQ-029 requires is built from: which piece, which preset,
/// and how many of its lines would receive an embedded copy.
public struct PresetSoundUsage: Equatable, Sendable {
    public let presetID: String
    public let presetName: String
    public let pieceID: String
    public let lineIDs: [ScoreLineID]

    public init(presetID: String, presetName: String, pieceID: String, lineIDs: [ScoreLineID]) {
        self.presetID = presetID
        self.presetName = presetName
        self.pieceID = pieceID
        self.lineIDs = lineIDs
    }
}

/// The per-piece presets and line renames: **the preset-document contract
/// ASN002, INS003 and EXP001 consume.**
///
/// Four properties of it are the contract, and everything here exists to make
/// them true rather than merely intended:
///
/// 1. **A piece always has exactly one active, playable preset.** Opening a
///    piece that has none creates one (REQ-007); the active flag is a partial
///    unique index rather than a convention; and the last preset cannot be
///    deleted.
/// 2. **Every change is saved as it is made.** There is no `save()` and no
///    dirty flag: `assign`, `setMixer`, `rename` and `activate` each commit one
///    transaction and hand back the preset as it now is. That is what makes
///    REQ-024's auto-save true and switching presets safe by construction —
///    there is never unsaved state for a switch to lose.
/// 3. **References are live, and survive their sound's deletion.** A line holds
///    a library identity, so editing that sound is heard everywhere it is used;
///    deleting it embeds a complete private copy inside the same transaction
///    that removes the row, so no preset ever points at nothing (REQ-029).
/// 4. **Presets do not outlive their piece.** Removing a piece removes them, in
///    the removal's own transaction (REQ-003).
///
/// Like `SoundLibrary`, this is a value-returning API: every mutating method
/// hands back the preset as it now is, so a caller never has to re-query to
/// learn what it just wrote.
public final class PresetLibrary: @unchecked Sendable, PieceDependentStore, SoundDependentStore {
    private let catalog: PresetCatalog
    private let database: SQLiteDatabase
    private let makeIdentity: @Sendable () -> String
    private let now: @Sendable () -> String

    /// The name the auto-created first preset gets (REQ-007).
    public static let initialPresetName = "Default"

    public convenience init(database: SQLiteDatabase) {
        self.init(database: database, catalog: PresetCatalog(database: database))
    }

    /// Seams exist for the paths tests could not otherwise reach: an identity
    /// generator and a clock.
    init(
        database: SQLiteDatabase,
        catalog: PresetCatalog,
        makeIdentity: @escaping @Sendable () -> String = { "preset." + UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> String = { SchemaMigrator.timestamp() }
    ) {
        self.database = database
        self.catalog = catalog
        self.makeIdentity = makeIdentity
        self.now = now
    }

    // MARK: Reading

    /// Every preset of one piece, in list order.
    public func presets(forPieceID pieceID: String) throws -> [Preset] {
        try catalog.presets(forPieceID: pieceID).sorted(by: Preset.isOrderedBefore)
    }

    public func preset(withID id: String) throws -> Preset? {
        try catalog.preset(withID: id)
    }

    /// The piece's active preset, or nil when it has none yet.
    public func activePreset(forPieceID pieceID: String) throws -> Preset? {
        try catalog.activePreset(forPieceID: pieceID)
    }

    public func presetCount(forPieceID pieceID: String) throws -> Int {
        try catalog.presetCount(forPieceID: pieceID)
    }

    // MARK: Line inventory (REQ-005)

    /// The piece's line inventory, with the owner's renames applied.
    public func inventory(for score: CompiledScore) throws -> LineInventory {
        LineInventory(score: score, renames: try catalog.lineNames(forPieceID: score.pieceID))
    }

    /// Renames a line. Its identity does not change, so every preset that
    /// assigns a sound to it keeps working.
    ///
    /// Renaming to exactly the score's own name clears the rename rather than
    /// storing it, so a later improvement to the name deriver still reaches
    /// that line.
    @discardableResult
    public func renameLine(
        _ entry: LineEntry, inPieceID pieceID: String, to name: String
    ) throws -> LineEntry {
        let trimmed = try validName(name)
        do {
            if trimmed == entry.defaultName {
                try catalog.clearLineName(forLineID: entry.id, pieceID: pieceID)
            } else {
                try catalog.setLineName(
                    trimmed, forLineID: entry.id, pieceID: pieceID, at: now()
                )
            }
        } catch {
            throw PresetError.storeFailed(name: entry.name, reason: Self.describe(error))
        }
        return LineEntry(
            id: entry.id,
            defaultName: entry.defaultName,
            name: trimmed,
            partName: entry.partName,
            staff: entry.staff,
            voice: entry.voice
        )
    }

    /// Forgets a rename, putting the line back to the score's own name.
    @discardableResult
    public func resetLineName(_ entry: LineEntry, inPieceID pieceID: String) throws -> LineEntry {
        do {
            try catalog.clearLineName(forLineID: entry.id, pieceID: pieceID)
        } catch {
            throw PresetError.storeFailed(name: entry.name, reason: Self.describe(error))
        }
        return LineEntry(
            id: entry.id,
            defaultName: entry.defaultName,
            name: nil,
            partName: entry.partName,
            staff: entry.staff,
            voice: entry.voice
        )
    }

    // MARK: Opening a piece (REQ-007)

    /// The preset to play `inventory` with, creating and reconciling as needed.
    ///
    /// This is the first-open path, and it is idempotent — every open goes
    /// through it, not only the first. Three things can be true when a piece is
    /// opened, and all three end with one playable active preset:
    ///
    /// * **No presets.** One is created from the auto-mapping (REQ-007) and
    ///   made active.
    /// * **Presets, but none active.** The first in list order becomes active,
    ///   because a piece with presets and no active one is not a state the
    ///   owner can act on.
    /// * **An active preset whose lines no longer match the score.** Missing
    ///   lines are added from the auto-mapping and entries for lines the score
    ///   no longer has are dropped, so "playable" survives a re-import or an
    ///   improved compiler. Untouched lines keep their assignment and mixer
    ///   state exactly.
    ///
    /// Reconciliation touches only the active preset, deliberately: rewriting
    /// every stored preset on open would turn a read into a bulk migration.
    /// Each becomes current the first time it is activated.
    @discardableResult
    public func activePreset(
        for inventory: LineInventory,
        palette: [SoundEntry]
    ) throws -> Preset {
        guard !inventory.isEmpty else {
            throw PresetError.pieceHasNoLines(pieceID: inventory.pieceID)
        }

        if let active = try activePreset(forPieceID: inventory.pieceID) {
            return try reconcile(active, with: inventory, palette: palette)
        }

        if let first = try presets(forPieceID: inventory.pieceID).first {
            let activated = try activate(first)
            return try reconcile(activated, with: inventory, palette: palette)
        }

        return try create(
            named: Self.initialPresetName,
            forPieceID: inventory.pieceID,
            content: try PresetAutoAssignment.initialContent(for: inventory, palette: palette),
            makeActive: true
        )
    }

    /// Brings a preset's lines into agreement with the piece's current lines.
    ///
    /// A no-op — and no write at all — when they already agree, which is the
    /// normal case on every open after the first.
    @discardableResult
    public func reconcile(
        _ preset: Preset,
        with inventory: LineInventory,
        palette: [SoundEntry]
    ) throws -> Preset {
        let wanted = inventory.lineIDs
        let present = preset.content.lines.map(\.lineID)
        guard wanted != present else { return preset }

        let existing = Dictionary(
            preset.content.lines.map { ($0.lineID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // All or nothing, exactly as `initialContent` is: a line the palette
        // cannot cover is reported, never dropped into a preset that looks
        // complete and plays nothing on it.
        let rebuilt = try inventory.entries.map { entry -> PresetLine in
            if let kept = existing[entry.id] { return kept }
            return PresetLine(
                lineID: entry.id,
                assignment: try PresetAutoAssignment.assignment(for: entry, from: palette),
                mixer: .neutral
            )
        }

        return try write(preset) { current in
            (name: current.name, isActive: current.isActive, content: PresetContent(lines: rebuilt))
        }
    }

    // MARK: Writing

    /// Stores a new preset for a piece.
    @discardableResult
    public func create(
        named name: String,
        forPieceID pieceID: String,
        content: PresetContent,
        makeActive: Bool = true
    ) throws -> Preset {
        let trimmed = try validName(name)
        let identity = makeIdentity()
        let timestamp = now()
        let document = try encode(content, named: trimmed)

        let preset = Preset(
            id: identity,
            pieceID: pieceID,
            name: trimmed,
            isActive: makeActive,
            documentVersion: PresetContent.currentVersion,
            revision: 1,
            createdAt: timestamp,
            updatedAt: timestamp,
            content: content
        )

        try transact(named: trimmed) {
            // Cleared first so the partial unique index is never momentarily
            // violated inside the transaction.
            if makeActive { try catalog.clearActive(forPieceID: pieceID) }
            try catalog.insert(preset, document: document)
        }
        return preset
    }

    /// A copy of `preset` under a new name, with the same assignments and mixer
    /// state. The copy is not active unless asked for.
    @discardableResult
    public func duplicate(
        _ preset: Preset, named name: String? = nil, makeActive: Bool = false
    ) throws -> Preset {
        try create(
            named: try name.map(validName) ?? copyName(for: preset),
            forPieceID: preset.pieceID,
            content: preset.content,
            makeActive: makeActive
        )
    }

    /// Renames a preset. Its identity, content and active flag do not change.
    ///
    /// Names are deliberately not unique, for the reason `SoundLibrary` gives:
    /// identity is the `id`, so a collision costs the owner a second look
    /// rather than a preset.
    @discardableResult
    public func rename(_ preset: Preset, to name: String) throws -> Preset {
        let trimmed = try validName(name)
        return try write(preset) { current in
            (name: trimmed, isActive: current.isActive, content: current.content)
        }
    }

    /// Makes this the piece's active preset (REQ-024's "switching").
    ///
    /// **There is nothing to save first.** Every change is already committed as
    /// it is made, so the preset being switched away from is on disk exactly as
    /// the owner left it — auto-save-before-switch is not a step here, it is the
    /// absence of a need for one.
    @discardableResult
    public func activate(_ preset: Preset) throws -> Preset {
        guard !preset.isActive else { return preset }
        return try write(preset) { current in
            (name: current.name, isActive: true, content: current.content)
        }
    }

    /// Replaces one line's sound.
    ///
    /// Auto-saved. REQ-006's exclusivity is structural: this replaces the whole
    /// assignment, so a line cannot end up with two.
    @discardableResult
    public func assign(
        _ assignment: LineAssignment, toLine lineID: ScoreLineID, in preset: Preset
    ) throws -> Preset {
        try mutateLine(lineID, in: preset) { line in
            line.assignment = assignment
        }
    }

    /// Replaces one line's volume, pan, mute, solo and room send. Auto-saved.
    @discardableResult
    public func setMixer(
        _ mixer: LineMixerState, forLine lineID: ScoreLineID, in preset: Preset
    ) throws -> Preset {
        try mutateLine(lineID, in: preset) { line in
            line.mixer = mixer
        }
    }

    /// Records the owner's answer to "your instrument is missing — do you want
    /// to hear something meanwhile?" (issue #24). Auto-saved.
    ///
    /// **Only the owner's own answer reaches this.** Nothing infers it, nothing
    /// sets it as a convenience, and the default is `false`, so a line whose
    /// instrument is absent stays silent until a person says otherwise. That is
    /// the whole gate: a substitution the owner did not ask for is the state
    /// this leaf exists to prevent, and the only way to reach `true` is a
    /// button they pressed.
    @discardableResult
    public func setAcceptsSubstitution(
        _ accepts: Bool, forLine lineID: ScoreLineID, in preset: Preset
    ) throws -> Preset {
        try mutateLine(lineID, in: preset) { line in
            line.acceptsSubstitution = accepts
        }
    }

    /// Deletes a preset.
    ///
    /// Deleting the active one promotes the next in list order, because a piece
    /// without an active preset is not a state the owner can act on; deleting
    /// the only one is refused, because REQ-007 promises a piece is always
    /// playable.
    ///
    /// **Whether this preset is the active one is read from the store, not from
    /// the caller's value**, for the reason `write` gives: a stale list must be
    /// harmless. Trusting `preset.isActive` would let a caller holding a preset
    /// that was deactivated in the meantime promote a *second* active preset,
    /// which the partial unique index then rejects — turning a legitimate
    /// delete into a spurious "could not save".
    public func delete(_ preset: Preset) throws {
        let timestamp = now()

        try transact(named: preset.name) {
            let siblings = try catalog.presets(forPieceID: preset.pieceID)
                .sorted(by: Preset.isOrderedBefore)
            guard let current = siblings.first(where: { $0.id == preset.id }) else {
                throw PresetError.presetNotFound(name: preset.name)
            }
            guard siblings.count > 1 else {
                throw PresetError.lastPresetCannotBeDeleted(name: preset.name)
            }

            let successor = current.isActive
                ? siblings.first(where: { $0.id != preset.id })
                : nil

            try catalog.delete(presetID: preset.id)
            if let successor {
                let promoted = Preset(
                    id: successor.id,
                    pieceID: successor.pieceID,
                    name: successor.name,
                    isActive: true,
                    documentVersion: successor.documentVersion,
                    revision: successor.revision + 1,
                    createdAt: successor.createdAt,
                    updatedAt: timestamp,
                    content: successor.content
                )
                try catalog.update(promoted, document: try encode(promoted.content, named: promoted.name))
            }
        }
    }

    // MARK: Live references and embedding (REQ-029)

    /// Every preset that would receive an embedded copy if this sound were
    /// deleted — the material the warning is built from.
    ///
    /// Scans every piece, not only the open one: a sound the owner deleted is
    /// deleted everywhere, and a warning that counted only the current piece
    /// would understate what is about to happen.
    public func usage(ofSoundID soundID: String) throws -> [PresetSoundUsage] {
        try catalog.allPresets().compactMap { preset in
            let lines = preset.content.lines
                .filter { $0.assignment.referencesLibrarySound(soundID) }
                .map(\.lineID)
            guard !lines.isEmpty else { return nil }
            return PresetSoundUsage(
                presetID: preset.id,
                presetName: preset.name,
                pieceID: preset.pieceID,
                lineIDs: lines
            )
        }
    }

    /// True when at least one preset still references this sound.
    public func isSoundInUse(_ soundID: String) throws -> Bool {
        try !usage(ofSoundID: soundID).isEmpty
    }

    public var dependentDescription: String { "presets" }

    /// REQ-029's embed. Called inside `SoundLibrary`'s deletion transaction,
    /// before the row goes.
    ///
    /// Every live reference to this sound becomes a complete private copy of it
    /// as it is right now — same patch, same name — so the affected presets go
    /// on playing identically. A preset that merely holds an *embedded* copy of
    /// an earlier sound with this identity is untouched: it is already frozen,
    /// and re-embedding it would be a lie about when the copy was taken.
    ///
    /// Nothing is deleted here. That is the whole difference from the piece
    /// cascade below, and the reason `SoundDependentStore` and
    /// `PieceDependentStore` are separate protocols.
    public func soundWillBeDeleted(_ sound: SoundEntry, in database: SQLiteDatabase) throws {
        let timestamp = now()
        let embedded = EmbeddedSound(copying: sound, at: timestamp)

        for preset in try catalog.allPresets() {
            var content = preset.content
            var changed = false
            for index in content.lines.indices
            where content.lines[index].assignment.referencesLibrarySound(sound.id) {
                content.lines[index].assignment = .embedded(embedded)
                changed = true
            }
            guard changed else { continue }

            let updated = Preset(
                id: preset.id,
                pieceID: preset.pieceID,
                name: preset.name,
                isActive: preset.isActive,
                documentVersion: PresetContent.currentVersion,
                revision: preset.revision + 1,
                createdAt: preset.createdAt,
                updatedAt: timestamp,
                content: content
            )
            try catalog.update(updated, document: try encode(content, named: preset.name))
        }
    }

    /// REQ-003's cascade. Called inside `PieceRemover`'s transaction, before the
    /// piece row goes.
    public func removeDependents(ofPieceID pieceID: String, in database: SQLiteDatabase) throws {
        try catalog.deletePresets(forPieceID: pieceID)
        try catalog.deleteLineNames(forPieceID: pieceID)
    }

    // MARK: Internals

    private func mutateLine(
        _ lineID: ScoreLineID,
        in preset: Preset,
        _ change: (inout PresetLine) -> Void
    ) throws -> Preset {
        try write(preset) { current in
            guard var content = Optional(current.content),
                  let index = content.index(ofLine: lineID) else {
                throw PresetError.lineNotInPreset(lineID: lineID.rawValue)
            }
            change(&content.lines[index])
            return (name: current.name, isActive: current.isActive, content: content)
        }
    }

    /// The one update path: read the current row inside the transaction, apply
    /// the change, write it back with the revision bumped.
    ///
    /// Reading inside the transaction rather than trusting the caller's
    /// `preset` is what makes a stale list harmless: the write is against what
    /// is actually stored, and a preset that has since been deleted is reported
    /// rather than resurrected.
    @discardableResult
    private func write(
        _ preset: Preset,
        _ change: (Preset) throws -> (name: String, isActive: Bool, content: PresetContent)
    ) throws -> Preset {
        let timestamp = now()

        do {
            return try database.withTransaction { _ -> Preset in
                guard let current = try catalog.preset(withID: preset.id) else {
                    throw PresetError.presetNotFound(name: preset.name)
                }

                let changed = try change(current)
                let document = try encode(changed.content, named: changed.name)

                let updated = Preset(
                    id: current.id,
                    pieceID: current.pieceID,
                    name: changed.name,
                    isActive: changed.isActive,
                    documentVersion: PresetContent.currentVersion,
                    revision: current.revision + 1,
                    createdAt: current.createdAt,
                    updatedAt: timestamp,
                    content: changed.content
                )

                if changed.isActive {
                    try catalog.clearActive(forPieceID: current.pieceID, except: current.id)
                }
                try catalog.update(updated, document: document)
                return updated
            }
        } catch let error as PresetError {
            throw error
        } catch {
            throw PresetError.storeFailed(name: preset.name, reason: Self.describe(error))
        }
    }

    private func transact(named name: String, _ body: () throws -> Void) throws {
        do {
            try database.withTransaction { _ in try body() }
        } catch let error as PresetError {
            throw error
        } catch {
            throw PresetError.storeFailed(name: name, reason: Self.describe(error))
        }
    }

    private func encode(_ content: PresetContent, named name: String) throws -> String {
        do {
            return String(decoding: try PresetDocument.data(from: content), as: UTF8.self)
        } catch let error as PresetDocumentError {
            throw PresetError.documentRejected(name: name, reason: error.description)
        } catch {
            throw PresetError.documentRejected(name: name, reason: String(describing: error))
        }
    }

    private func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PresetError.nameIsEmpty }
        return trimmed
    }

    /// "Default copy", then "Default copy 2". Deterministic rather than
    /// unique-by-constraint, for the reason `SoundLibrary.copyName` gives:
    /// names are not keys here, so this keeps a list of copies legible rather
    /// than preventing a collision.
    private func copyName(for preset: Preset) -> String {
        let base = preset.name + " copy"
        let taken = Set(
            ((try? catalog.presets(forPieceID: preset.pieceID)) ?? []).map { $0.name.lowercased() }
        )
        guard taken.contains(base.lowercased()) else { return base }

        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
    }
}
