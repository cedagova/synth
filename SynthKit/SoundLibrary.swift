import Foundation

/// Something that holds a live reference to a sound and must be told before
/// that sound is deleted.
///
/// REQ-029 says a preset referencing a deleted sound keeps working by embedding
/// a copy of it. Presets arrive in increment 004, so this leaf cannot — and
/// must not — invent their model. What it can own is the *seam*: the deletion
/// transaction hands every registered holder the complete sound, patch
/// included, before the row goes, and the whole thing commits or does not.
///
/// This is deliberately not the `PieceDependentStore` cascade. Deleting a piece
/// deletes its presets; deleting a *sound* must not delete anything, because
/// the preset survives it. The two hooks look similar and mean opposite things,
/// which is exactly why they are separate protocols.
public protocol SoundDependentStore: Sendable {
    /// Named in errors, so a failed deletion says which store refused.
    var dependentDescription: String { get }

    /// About to delete `sound`. Embed whatever must outlive it.
    ///
    /// Called inside the deletion transaction on `database`; it must not open
    /// one of its own. Deleting a sound nothing references is normal and must
    /// succeed.
    func soundWillBeDeleted(_ sound: SoundEntry, in database: SQLiteDatabase) throws
}

/// Every way a sound-library operation can fail.
///
/// Each case names the sound, because the alert the owner sees has to say which
/// one — and each one is thrown only after the transaction rolled back, so the
/// library really is unchanged.
public enum SoundLibraryError: Error, Equatable, Sendable {
    /// A shipped sound cannot be renamed, re-categorised, edited or deleted
    /// (REQ-017). Use `makeEditableCopy(of:)` instead.
    case shippedSoundIsReadOnly(name: String)

    /// The sound was not in the library when the operation ran — another
    /// window, or a stale list.
    case soundNotFound(name: String)

    /// A name that is empty or only whitespace is not a name.
    case nameIsEmpty

    /// An identity a delete retired can never be handed to another sound.
    case identityRetired(id: String)

    /// The patch is not a sound this build can store: a parameter out of range,
    /// a wrong component count. Reported rather than silently corrected.
    case documentRejected(name: String, reason: String)

    /// A holder of a live reference refused. Nothing was deleted.
    case dependentRefused(name: String, dependent: String, reason: String)

    /// The store refused the write. The library is exactly as it was.
    case storeFailed(name: String, reason: String)
}

extension SoundLibraryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .shippedSoundIsReadOnly(let name):
            return "“\(name)” is one of Synth's own sounds and cannot be changed."
        case .soundNotFound(let name):
            return "“\(name)” is no longer in your sound library."
        case .nameIsEmpty:
            return "A sound needs a name."
        case .identityRetired(let id):
            return "The sound identity \(id) belonged to a sound you deleted and cannot be reused."
        case .documentRejected(let name, let reason):
            return "Synth could not save “\(name)”: \(reason)"
        case .dependentRefused(let name, let dependent, let reason):
            return "Synth could not delete “\(name)”: its \(dependent) could not be updated. \(reason)"
        case .storeFailed(let name, let reason):
            return "Synth could not save “\(name)” to your library. \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .shippedSoundIsReadOnly:
            return "Duplicate it to get an editable copy of your own; the original stays as it is."
        case .soundNotFound:
            return "The sound list has been refreshed."
        case .nameIsEmpty:
            return "Type a name and try again."
        case .identityRetired:
            return "Create the sound again; it will be given a new identity."
        case .documentRejected:
            return "Bring the parameter it names back into range and try again."
        case .dependentRefused, .storeFailed:
            return "Nothing was changed and your sounds are intact. Try again; if this keeps happening, the library database may be damaged."
        }
    }
}

/// The personal sound library: the owner's stored sounds and the shipped
/// collection, as one list.
///
/// **This is the sound-library model the rest of the project consumes** — the
/// editor (SYN003), preset assignment (increment 004), and instrument variants
/// (increment 005). Three properties of it are the contract, and everything
/// here exists to make them true rather than merely intended:
///
/// 1. **Identity is stable.** A rename or a re-categorisation never changes an
///    `id`, and an `id` a delete retired is never handed to another sound. A
///    preset can therefore hold a reference rather than a copy.
/// 2. **Shipped sounds are read-only and are not rows.** Every mutating method
///    refuses one; there is no code path that writes a shipped identity into
///    the store. Editing one means `makeEditableCopy(of:)`, whose result is a
///    new user sound that cannot reach back to the original.
/// 3. **Every write is one transaction.** A failed save leaves the previous
///    version of that sound exactly where it was, and never a half-written one.
///
/// The library is a value-returning API: every mutating method hands back the
/// entry as it now is, so a caller never has to re-query to learn what it just
/// wrote.
public final class SoundLibrary: @unchecked Sendable {
    private let database: SQLiteDatabase
    private let catalog: SoundCatalogStoring
    private let shipped: ShippedSoundCollection
    private let dependentStores: [SoundDependentStore]
    private let makeIdentity: @Sendable () -> String
    private let now: @Sendable () -> String

    /// A library over an opened store.
    public convenience init(
        database: SQLiteDatabase,
        shipped: ShippedSoundCollection = .standard,
        dependentStores: [SoundDependentStore] = []
    ) {
        self.init(
            database: database,
            catalog: SoundCatalog(database: database),
            shipped: shipped,
            dependentStores: dependentStores
        )
    }

    /// Seams exist for the failure paths — a catalog that refuses to write, a
    /// dependent that refuses a deletion, and an identity generator that hands
    /// back one a delete already retired.
    init(
        database: SQLiteDatabase,
        catalog: SoundCatalogStoring,
        shipped: ShippedSoundCollection = .standard,
        dependentStores: [SoundDependentStore] = [],
        makeIdentity: @escaping @Sendable () -> String = { "user." + UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> String = { SchemaMigrator.timestamp() }
    ) {
        self.database = database
        self.catalog = catalog
        self.shipped = shipped
        self.dependentStores = dependentStores
        self.makeIdentity = makeIdentity
        self.now = now
    }

    // MARK: Reading

    /// The whole library — shipped sounds and the owner's — in list order.
    ///
    /// Shipped entries come from the build, so they are present on the very
    /// first run before anything has been written anywhere (REQ-019).
    public func allSounds() throws -> [SoundEntry] {
        (shipped.sounds + (try catalog.allStoredSounds()))
            .sorted(by: SoundEntry.isOrderedBefore)
    }

    /// Just the sounds filed under one category, in list order.
    public func sounds(in category: SoundCategory) throws -> [SoundEntry] {
        try allSounds().filter { $0.category == category }
    }

    /// Every category that has at least one sound in it, with its sounds.
    ///
    /// An array of pairs rather than a dictionary: the order is part of the
    /// answer, and a dictionary would throw it away.
    public func soundsByCategory() throws -> [(category: SoundCategory, sounds: [SoundEntry])] {
        let all = try allSounds()
        return SoundCategory.allCases.compactMap { category in
            let members = all.filter { $0.category == category }
            return members.isEmpty ? nil : (category, members)
        }
    }

    /// The sound with this identity, shipped or stored.
    public func sound(withID id: String) throws -> SoundEntry? {
        if let entry = shipped.sound(withID: id) { return entry }
        return try catalog.storedSound(withID: id)
    }

    /// Just the owner's sounds, in list order.
    public func userSounds() throws -> [SoundEntry] {
        try catalog.allStoredSounds().sorted(by: SoundEntry.isOrderedBefore)
    }

    /// How many sounds the owner has of their own. Shipped sounds are not
    /// counted, because they are not in the store.
    public func userSoundCount() throws -> Int {
        try catalog.storedSoundCount()
    }

    /// The sounds this build ships, in list order.
    public var shippedSounds: [SoundEntry] { shipped.sounds }

    /// True when a delete retired this identity.
    ///
    /// Increment 004 uses this to tell a reference to a sound the owner deleted
    /// from a reference that was never valid.
    public func isRetired(id: String) throws -> Bool {
        try catalog.isRetired(id: id)
    }

    // MARK: Writing

    /// Stores a new sound of the owner's own (REQ-017's "create from scratch").
    ///
    /// The stored patch's `identifier` and `name` are overwritten with the
    /// library's, so an exported document always agrees with the row it came
    /// from; there is no second place where a sound's name lives.
    @discardableResult
    public func create(
        patch: SynthPatch,
        named name: String,
        in category: SoundCategory
    ) throws -> SoundEntry {
        let trimmed = try validName(name)
        return try insert(
            patch: patch,
            name: trimmed,
            category: category,
            shippedOriginID: nil
        )
    }

    /// An editable copy of a shipped sound (REQ-017).
    ///
    /// This is the *only* way a shipped sound changes. The result is a new user
    /// sound with its own identity and its own row; the shipped original is
    /// untouched and stays exactly where it was, because it was never a row in
    /// the first place.
    ///
    /// Applying this to a sound the owner already owns is a plain duplicate,
    /// which is the other entry point REQ-017 asks for — the operation is the
    /// same one either way, so it is the same code.
    @discardableResult
    public func makeEditableCopy(
        of entry: SoundEntry,
        named name: String? = nil
    ) throws -> SoundEntry {
        let requested = try name.map(validName) ?? copyName(for: entry.name)
        return try insert(
            patch: entry.patch,
            name: requested,
            category: entry.category,
            // Provenance is flattened to the shipped root: a copy of a copy of
            // "Glass Keys" still came from "Glass Keys".
            shippedOriginID: entry.origin == .shipped ? entry.id : entry.shippedOriginID
        )
    }

    /// Duplicates any sound. The same operation as `makeEditableCopy(of:)`,
    /// named for what a caller means when the original is already the owner's.
    @discardableResult
    public func duplicate(_ entry: SoundEntry, named name: String? = nil) throws -> SoundEntry {
        try makeEditableCopy(of: entry, named: name)
    }

    /// Renames a sound the owner owns. Its identity does not change.
    ///
    /// Names are deliberately not unique: two sounds may share one, and nothing
    /// is silently renamed or overwritten to avoid a collision. Identity is the
    /// `id`, so a collision costs the owner nothing but a second look.
    @discardableResult
    public func rename(_ entry: SoundEntry, to name: String) throws -> SoundEntry {
        let trimmed = try validName(name)
        return try mutate(entry) { current in
            var patch = current.patch
            patch.name = trimmed
            return (name: trimmed, category: current.category, patch: patch)
        }
    }

    /// Files a sound the owner owns under a different category. Its identity
    /// does not change.
    @discardableResult
    public func recategorize(
        _ entry: SoundEntry,
        to category: SoundCategory
    ) throws -> SoundEntry {
        try mutate(entry) { current in
            (name: current.name, category: category, patch: current.patch)
        }
    }

    /// Replaces the sound of a patch the owner owns — the editor's save.
    ///
    /// The row's name and identity win over whatever the incoming patch says
    /// about itself, so an edit is an edit and never an accidental rename.
    @discardableResult
    public func update(_ entry: SoundEntry, patch: SynthPatch) throws -> SoundEntry {
        try mutate(entry) { current in
            (name: current.name, category: current.category, patch: patch)
        }
    }

    /// Permanently deletes a sound the owner owns, and retires its identity.
    ///
    /// Order is the design: inside one transaction, confirm the sound is still
    /// there, let every holder of a live reference embed what it needs
    /// (REQ-029, increment 004), then delete the row and retire the identity.
    /// Commit or roll back as one.
    ///
    /// A shipped sound cannot reach this method, and has no row to delete if it
    /// somehow did.
    public func delete(_ entry: SoundEntry) throws {
        guard entry.origin == .user else {
            throw SoundLibraryError.shippedSoundIsReadOnly(name: entry.name)
        }

        let timestamp = now()
        do {
            try database.withTransaction { transactionDatabase in
                guard let current = try catalog.storedSound(withID: entry.id) else {
                    throw SoundLibraryError.soundNotFound(name: entry.name)
                }

                for dependent in dependentStores {
                    do {
                        try dependent.soundWillBeDeleted(current, in: transactionDatabase)
                    } catch {
                        throw SoundLibraryError.dependentRefused(
                            name: entry.name,
                            dependent: dependent.dependentDescription,
                            reason: Self.describe(error)
                        )
                    }
                }

                try catalog.deleteAndRetire(id: entry.id, at: timestamp)
            }
        } catch let error as SoundLibraryError {
            throw error
        } catch {
            throw SoundLibraryError.storeFailed(name: entry.name, reason: Self.describe(error))
        }
    }

    // MARK: Internals

    /// The one insertion path. Everything that creates a user sound — from
    /// scratch, from a shipped sound, from a duplicate — goes through here, so
    /// there is exactly one place that allocates an identity and one place that
    /// decides what a stored sound looks like.
    private func insert(
        patch: SynthPatch,
        name: String,
        category: SoundCategory,
        shippedOriginID: String?
    ) throws -> SoundEntry {
        let identity = makeIdentity()
        let timestamp = now()

        var stored = patch
        stored.identifier = identity
        stored.name = name

        let document = try encode(stored, named: name)

        let entry = SoundEntry(
            id: identity,
            name: name,
            category: category,
            origin: .user,
            shippedOriginID: shippedOriginID,
            documentVersion: SynthPatch.currentVersion,
            revision: 1,
            createdAt: timestamp,
            updatedAt: timestamp,
            patch: stored
        )

        do {
            try database.withTransaction { _ in
                guard try !catalog.isRetired(id: identity) else {
                    throw SoundLibraryError.identityRetired(id: identity)
                }
                try catalog.insert(entry, document: document)
            }
        } catch let error as SoundLibraryError {
            throw error
        } catch {
            throw SoundLibraryError.storeFailed(name: name, reason: Self.describe(error))
        }

        return entry
    }

    /// The one update path: read the current row inside the transaction, apply
    /// the change, write it back with the revision bumped.
    ///
    /// Reading inside the transaction rather than trusting the caller's `entry`
    /// is what makes a stale list harmless: the write is against what is
    /// actually stored, and a sound that has since been deleted is reported
    /// rather than resurrected.
    private func mutate(
        _ entry: SoundEntry,
        _ change: (SoundEntry) -> (name: String, category: SoundCategory, patch: SynthPatch)
    ) throws -> SoundEntry {
        guard entry.origin == .user else {
            throw SoundLibraryError.shippedSoundIsReadOnly(name: entry.name)
        }

        let timestamp = now()

        do {
            return try database.withTransaction { _ -> SoundEntry in
                guard let current = try catalog.storedSound(withID: entry.id) else {
                    throw SoundLibraryError.soundNotFound(name: entry.name)
                }

                let changed = change(current)

                var stored = changed.patch
                // Identity and name live in the row. Whatever the incoming
                // patch claims about itself loses, every time.
                stored.identifier = current.id
                stored.name = changed.name

                let document = try encode(stored, named: changed.name)

                let updated = SoundEntry(
                    id: current.id,
                    name: changed.name,
                    category: changed.category,
                    origin: .user,
                    shippedOriginID: current.shippedOriginID,
                    documentVersion: SynthPatch.currentVersion,
                    revision: current.revision + 1,
                    createdAt: current.createdAt,
                    updatedAt: timestamp,
                    patch: stored
                )

                try catalog.update(updated, document: document)
                return updated
            }
        } catch let error as SoundLibraryError {
            throw error
        } catch {
            throw SoundLibraryError.storeFailed(name: entry.name, reason: Self.describe(error))
        }
    }

    /// Serialises a patch through SYN001's document format — the one
    /// serialisation contract — and reports a rejected parameter as a rejected
    /// *save*, naming the sound, rather than as a bare document error.
    private func encode(_ patch: SynthPatch, named name: String) throws -> String {
        do {
            return String(decoding: try SynthPatchDocument.data(from: patch), as: UTF8.self)
        } catch let error as SynthPatchDocumentError {
            throw SoundLibraryError.documentRejected(name: name, reason: error.description)
        } catch {
            throw SoundLibraryError.documentRejected(name: name, reason: String(describing: error))
        }
    }

    private func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SoundLibraryError.nameIsEmpty }
        return trimmed
    }

    /// A deterministic, non-colliding name for a copy: "Glass Keys copy", then
    /// "Glass Keys copy 2", "Glass Keys copy 3".
    ///
    /// Deterministic rather than unique-by-constraint. Names are not keys here,
    /// so this exists to keep a library of copies legible, not to prevent a
    /// collision that would cost anything.
    private func copyName(for original: String) -> String {
        let base = original + " copy"
        let taken = Set(
            ((try? catalog.allStoredSounds()) ?? []).map { $0.name.lowercased() }
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
