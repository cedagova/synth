import XCTest
@testable import SynthKit

/// The sound library's acceptance criteria are persistence and immutability
/// claims, so almost every test here proves its point by **reopening the
/// store** rather than by asking an in-memory object what it remembers. A
/// library model that returns the right value from a cache and never wrote it
/// would pass the second kind of test and lose the owner's work on quit.
final class SoundLibraryTests: XCTestCase {
    private var sandboxRoot: URL!
    private var container: AppContainer!

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        container = AppContainer(rootURL: sandboxRoot.appending(path: "Synth"))
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    /// A launch of the app: the same container, opened fresh.
    private func launch(
        soundDependentStores: [@Sendable (SQLiteDatabase) -> SoundDependentStore] = []
    ) throws -> LibraryStore {
        try LibraryStore.open(
            container: container,
            appVersion: "1.0 (1)",
            soundDependentStores: soundDependentStores
        )
    }

    /// A patch that is recognisably not any of the shipped ones, so a test can
    /// tell the sound it stored from the sound it copied.
    private func testPatch(
        detuneCents: Double = 0,
        cutoff: Double = 3_000
    ) -> SynthPatch {
        SynthPatch(
            identifier: "ignored.by.the.library",
            name: "Ignored By The Library",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.8, detuneCents: detuneCents),
                .init(type: .analog, analogShape: .square, level: 0.3),
                .init(level: 0)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2, cutoffHertz: cutoff),
            outputLevel: 0.2
        )
    }

    // MARK: First run (REQ-019)

    func testAFreshLibraryHasTheShippedCollectionAndNothingWritten() throws {
        let store = try launch()
        defer { store.close() }

        let all = try store.sounds.allSounds()
        XCTAssertEqual(all.count, ShippedSoundCollection.standard.sounds.count)
        XCTAssertTrue(all.allSatisfy { $0.origin == .shipped })

        // Present without a single row being written: the shipped half is app
        // content, not user storage.
        XCTAssertEqual(try store.sounds.userSoundCount(), 0)
        XCTAssertEqual(
            try store.database.scalarInt("SELECT count(*) FROM \(SoundCatalog.tableName);"),
            0
        )
    }

    func testTheSoundTablesArriveAsAnAdditiveSchemaStep() throws {
        let store = try launch()
        defer { store.close() }

        XCTAssertEqual(store.schemaVersion, SchemaMigrator.latestVersion)
        XCTAssertTrue(try store.database.tableExists(SoundCatalog.tableName))
        XCTAssertTrue(try store.database.tableExists(SoundCatalog.retiredTableName))
    }

    // MARK: CRUD across relaunch (REQ-023 / REQ-025)

    /// The acceptance criterion, end to end: create, rename, re-categorise and
    /// delete, with a relaunch after every step so each one is proved against
    /// what is actually on disk.
    func testCreateRenameRecategorizeAndDeleteAllSurviveRelaunch() throws {
        // Create.
        let created: SoundEntry
        do {
            let store = try launch()
            defer { store.close() }
            created = try store.sounds.create(
                patch: testPatch(detuneCents: 11),
                named: "My First Sound",
                in: .pads
            )
        }

        // Relaunch: it is there, with everything it was given.
        do {
            let store = try launch()
            defer { store.close() }
            let reloaded = try XCTUnwrap(try store.sounds.sound(withID: created.id))
            XCTAssertEqual(reloaded.name, "My First Sound")
            XCTAssertEqual(reloaded.category, .pads)
            XCTAssertEqual(reloaded.origin, .user)
            XCTAssertTrue(reloaded.isEditable)
            XCTAssertEqual(reloaded.patch.oscillators[0].detuneCents, 11)
            XCTAssertEqual(try store.sounds.userSoundCount(), 1)

            // Rename, in this launch.
            let renamed = try store.sounds.rename(reloaded, to: "Renamed Sound")
            XCTAssertEqual(renamed.id, created.id, "A rename must not change identity")
        }

        // Relaunch: the rename stuck, and the identity did not move.
        do {
            let store = try launch()
            defer { store.close() }
            let reloaded = try XCTUnwrap(try store.sounds.sound(withID: created.id))
            XCTAssertEqual(reloaded.name, "Renamed Sound")
            XCTAssertEqual(reloaded.category, .pads)

            let moved = try store.sounds.recategorize(reloaded, to: .bells)
            XCTAssertEqual(moved.id, created.id, "Re-categorising must not change identity")
        }

        // Relaunch: the re-categorisation stuck.
        do {
            let store = try launch()
            defer { store.close() }
            let reloaded = try XCTUnwrap(try store.sounds.sound(withID: created.id))
            XCTAssertEqual(reloaded.category, .bells)
            XCTAssertEqual(reloaded.name, "Renamed Sound")
            XCTAssertTrue(
                try store.sounds.sounds(in: .bells).contains { $0.id == created.id }
            )
            XCTAssertFalse(
                try store.sounds.sounds(in: .pads).contains { $0.id == created.id }
            )

            try store.sounds.delete(reloaded)
        }

        // Relaunch: the delete stuck, and only the user sound went.
        do {
            let store = try launch()
            defer { store.close() }
            XCTAssertNil(try store.sounds.sound(withID: created.id))
            XCTAssertEqual(try store.sounds.userSoundCount(), 0)
            XCTAssertEqual(
                try store.sounds.allSounds().count,
                ShippedSoundCollection.standard.sounds.count
            )
        }
    }

    func testAnEditedPatchSurvivesRelaunchExactly() throws {
        let created: SoundEntry
        do {
            let store = try launch()
            defer { store.close() }
            created = try store.sounds.create(patch: testPatch(), named: "Editable", in: .leads)

            var edited = created.patch
            edited.filter.cutoffHertz = 812.5
            edited.reverb = .init(isEnabled: true, roomSize: 0.81, dampening: 0.22,
                                  mix: 0.37, preDelaySeconds: 0.045)
            edited.seed = 0xDEAD_BEEF_1234_5678
            _ = try store.sounds.update(created, patch: edited)
        }

        let store = try launch()
        defer { store.close() }
        let reloaded = try XCTUnwrap(try store.sounds.sound(withID: created.id))
        XCTAssertEqual(reloaded.patch.filter.cutoffHertz, 812.5)
        XCTAssertTrue(reloaded.patch.reverb.isEnabled)
        XCTAssertEqual(reloaded.patch.reverb.roomSize, 0.81)
        XCTAssertEqual(reloaded.patch.seed, 0xDEAD_BEEF_1234_5678)
    }

    /// The stored document is the sound's own record of itself, so it must not
    /// be able to disagree with the row it lives in.
    func testAStoredPatchAlwaysAgreesWithItsRow() throws {
        let store = try launch()
        defer { store.close() }

        // The incoming patch claims a different identity and a different name.
        let created = try store.sounds.create(
            patch: testPatch(), named: "The Row's Name", in: .keys
        )
        XCTAssertEqual(created.patch.identifier, created.id)
        XCTAssertEqual(created.patch.name, "The Row's Name")

        let renamed = try store.sounds.rename(created, to: "A Later Name")
        XCTAssertEqual(renamed.patch.name, "A Later Name")
        XCTAssertEqual(renamed.patch.identifier, created.id)

        // An edit that tries to smuggle a rename through the patch loses.
        var sneaky = renamed.patch
        sneaky.name = "Not This"
        sneaky.identifier = "not-this-either"
        let updated = try store.sounds.update(renamed, patch: sneaky)
        XCTAssertEqual(updated.name, "A Later Name")
        XCTAssertEqual(updated.patch.name, "A Later Name")
        XCTAssertEqual(updated.patch.identifier, created.id)
    }

    // MARK: Shipped immutability and edit-as-copy (REQ-017)

    /// Both directions of the criterion: the copy is genuinely the owner's and
    /// genuinely editable, and the shipped original is genuinely untouched —
    /// after a relaunch, so this is a claim about disk and not about a cache.
    func testEditingAShippedSoundYieldsACopyAndLeavesTheOriginalUntouched() throws {
        let shipped = try XCTUnwrap(
            ShippedSoundCollection.standard.sound(withID: "shipped.warm-analog-pad")
        )
        let originalPatch = shipped.patch

        let copyID: String
        do {
            let store = try launch()
            defer { store.close() }
            let copy = try store.sounds.makeEditableCopy(of: shipped)
            copyID = copy.id

            XCTAssertNotEqual(copy.id, shipped.id)
            XCTAssertEqual(copy.origin, .user)
            XCTAssertTrue(copy.isEditable)
            XCTAssertEqual(copy.shippedOriginID, shipped.id)
            XCTAssertEqual(copy.category, shipped.category)
            XCTAssertEqual(copy.name, "Warm Analog Pad copy")
            // The copy starts as the same sound, identity and name aside.
            XCTAssertEqual(copy.patch.oscillators, shipped.patch.oscillators)
            XCTAssertEqual(copy.patch.filter, shipped.patch.filter)

            var changed = copy.patch
            changed.filter.cutoffHertz = 220
            changed.reverb.isEnabled = false
            _ = try store.sounds.update(copy, patch: changed)
        }

        let store = try launch()
        defer { store.close() }

        // The copy kept the edit.
        let reloadedCopy = try XCTUnwrap(try store.sounds.sound(withID: copyID))
        XCTAssertEqual(reloadedCopy.patch.filter.cutoffHertz, 220)
        XCTAssertFalse(reloadedCopy.patch.reverb.isEnabled)

        // The shipped sound did not move an inch — not in the library's view,
        // and not in the app content it comes from.
        let reloadedShipped = try XCTUnwrap(try store.sounds.sound(withID: shipped.id))
        XCTAssertEqual(reloadedShipped.origin, .shipped)
        XCTAssertEqual(reloadedShipped.patch, originalPatch)
        XCTAssertEqual(ShippedSoundCollection.standard.sound(withID: shipped.id)?.patch, originalPatch)

        // And the store still holds exactly one sound: the copy. Editing a
        // shipped sound must not have written the shipped one anywhere.
        XCTAssertEqual(try store.sounds.userSoundCount(), 1)
        XCTAssertNil(
            try store.database.scalarText(
                "SELECT id FROM \(SoundCatalog.tableName) WHERE id = ?;",
                [.text(shipped.id)]
            )
        )
    }

    func testEveryMutationRefusesAShippedSound() throws {
        let store = try launch()
        defer { store.close() }
        let shipped = try XCTUnwrap(try store.sounds.allSounds().first { $0.origin == .shipped })

        func expectReadOnly(
            _ operation: () throws -> Void,
            _ label: String,
            line: UInt = #line
        ) {
            XCTAssertThrowsError(try operation(), label, line: line) { error in
                XCTAssertEqual(
                    error as? SoundLibraryError,
                    .shippedSoundIsReadOnly(name: shipped.name),
                    label, line: line
                )
            }
        }

        expectReadOnly({ _ = try store.sounds.rename(shipped, to: "Mine Now") }, "rename")
        expectReadOnly({ _ = try store.sounds.recategorize(shipped, to: .bass) }, "recategorize")
        expectReadOnly({ _ = try store.sounds.update(shipped, patch: self.testPatch()) }, "update")
        expectReadOnly({ try store.sounds.delete(shipped) }, "delete")

        XCTAssertFalse(shipped.isEditable)
        XCTAssertEqual(try store.sounds.userSoundCount(), 0, "No refusal may have written a row")
        XCTAssertEqual(try store.sounds.sound(withID: shipped.id)?.patch, shipped.patch)
    }

    /// Duplicating a sound the owner already has is the same operation, and the
    /// provenance of a copy of a copy still points at the shipped root.
    func testDuplicatingACopyKeepsTheShippedProvenance() throws {
        let store = try launch()
        defer { store.close() }
        let shipped = try XCTUnwrap(
            ShippedSoundCollection.standard.sound(withID: "shipped.fm-bell")
        )

        let first = try store.sounds.makeEditableCopy(of: shipped)
        let second = try store.sounds.duplicate(first)

        XCTAssertEqual(second.shippedOriginID, shipped.id)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.origin, .user)
    }

    func testACopyMadeFromScratchHasNoShippedProvenance() throws {
        let store = try launch()
        defer { store.close() }
        let created = try store.sounds.create(patch: testPatch(), named: "Mine", in: .leads)
        XCTAssertNil(created.shippedOriginID)
    }

    // MARK: Identity

    func testRenamingDoesNotChangeIdentityAndDeletesNeverReuseOne() throws {
        let store = try launch()
        defer { store.close() }

        let created = try store.sounds.create(patch: testPatch(), named: "Doomed", in: .plucks)
        let renamed = try store.sounds.rename(created, to: "Still Doomed")
        XCTAssertEqual(renamed.id, created.id)

        try store.sounds.delete(renamed)
        XCTAssertTrue(try store.sounds.isRetired(id: created.id))

        // Twenty more sounds, none of which may be handed the dead identity.
        for index in 0..<20 {
            let next = try store.sounds.create(
                patch: testPatch(), named: "Later \(index)", in: .plucks
            )
            XCTAssertNotEqual(next.id, created.id)
        }
    }

    /// The ledger is enforced by the database, not only by the library, so a
    /// future writer that bypasses `SoundLibrary` cannot resurrect an identity
    /// either.
    func testTheStoreItselfRefusesARetiredIdentity() throws {
        let store = try launch()
        defer { store.close() }

        let created = try store.sounds.create(patch: testPatch(), named: "Gone", in: .bass)
        try store.sounds.delete(created)

        XCTAssertThrowsError(
            try store.database.execute(
                """
                INSERT INTO \(SoundCatalog.tableName)
                    (id, name, category, shipped_origin_id, document_version,
                     document, revision, created_at, updated_at)
                VALUES (?, 'Smuggled', 'bass', NULL, 1, '{}', 1, '', '');
                """,
                [.text(created.id)]
            )
        ) { error in
            guard case StoreError.statementFailed(_, _, let message) = error else {
                return XCTFail("Expected statementFailed, got \(error)")
            }
            XCTAssertTrue(
                message.contains("never reused"),
                "The trigger should say why: \(message)"
            )
        }

        XCTAssertEqual(try store.sounds.userSoundCount(), 0)
    }

    /// The library reports a retired identity typed, rather than letting the
    /// trigger's message be the only explanation.
    func testTheLibraryReportsARetiredIdentityByName() throws {
        let store = try launch()
        defer { store.close() }

        // First allocate and delete an identity, then force the generator to
        // hand back that exact identity again.
        let doomedID = "user.always-the-same"
        let repeating = SoundLibrary(
            database: store.database,
            catalog: SoundCatalog(database: store.database),
            makeIdentity: { doomedID }
        )

        let created = try repeating.create(patch: testPatch(), named: "First", in: .keys)
        XCTAssertEqual(created.id, doomedID)
        try repeating.delete(created)

        XCTAssertThrowsError(
            try repeating.create(patch: testPatch(), named: "Second", in: .keys)
        ) { error in
            XCTAssertEqual(error as? SoundLibraryError, .identityRetired(id: doomedID))
        }
        XCTAssertEqual(try repeating.userSoundCount(), 0)
    }

    func testEveryEditBumpsTheRevisionAndNothingElseDoes() throws {
        let store = try launch()
        defer { store.close() }

        let created = try store.sounds.create(patch: testPatch(), named: "Counted", in: .brass)
        XCTAssertEqual(created.revision, 1)

        let renamed = try store.sounds.rename(created, to: "Counted Twice")
        XCTAssertEqual(renamed.revision, 2)

        let moved = try store.sounds.recategorize(renamed, to: .strings)
        XCTAssertEqual(moved.revision, 3)

        let edited = try store.sounds.update(moved, patch: testPatch(cutoff: 999))
        XCTAssertEqual(edited.revision, 4)
        XCTAssertEqual(edited.id, created.id)
        XCTAssertEqual(edited.createdAt, created.createdAt, "An edit is not a re-creation")

        // Reading does not.
        XCTAssertEqual(try store.sounds.sound(withID: created.id)?.revision, 4)
        XCTAssertEqual(try store.sounds.sound(withID: created.id)?.revision, 4)

        // Shipped sounds have no revisions to bump.
        XCTAssertTrue(store.sounds.shippedSounds.allSatisfy { $0.revision == 0 })
    }

    // MARK: Names

    func testTwoSoundsMayShareTheSameNameAndNeitherIsLost() throws {
        let store = try launch()
        defer { store.close() }

        let first = try store.sounds.create(patch: testPatch(cutoff: 1_000), named: "Twin", in: .keys)
        let second = try store.sounds.create(patch: testPatch(cutoff: 2_000), named: "Twin", in: .keys)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try store.sounds.userSoundCount(), 2)
        XCTAssertEqual(try store.sounds.sound(withID: first.id)?.patch.filter.cutoffHertz, 1_000)
        XCTAssertEqual(try store.sounds.sound(withID: second.id)?.patch.filter.cutoffHertz, 2_000)

        // And renaming one onto the other's name is allowed, and still loses
        // nothing.
        let renamed = try store.sounds.rename(first, to: "Twin")
        XCTAssertEqual(renamed.id, first.id)
        XCTAssertEqual(try store.sounds.userSoundCount(), 2)
    }

    func testCopyNamesAreDeterministicAndDoNotStackUpAmbiguously() throws {
        let store = try launch()
        defer { store.close() }
        let shipped = try XCTUnwrap(
            ShippedSoundCollection.standard.sound(withID: "shipped.sub-bass")
        )

        XCTAssertEqual(try store.sounds.makeEditableCopy(of: shipped).name, "Sub Bass copy")
        XCTAssertEqual(try store.sounds.makeEditableCopy(of: shipped).name, "Sub Bass copy 2")
        XCTAssertEqual(try store.sounds.makeEditableCopy(of: shipped).name, "Sub Bass copy 3")
        XCTAssertEqual(
            try store.sounds.makeEditableCopy(of: shipped, named: "Chosen").name,
            "Chosen"
        )
    }

    func testANameThatIsOnlyWhitespaceIsRefused() throws {
        let store = try launch()
        defer { store.close() }

        XCTAssertThrowsError(
            try store.sounds.create(patch: testPatch(), named: "   \n ", in: .keys)
        ) { XCTAssertEqual($0 as? SoundLibraryError, .nameIsEmpty) }

        let created = try store.sounds.create(patch: testPatch(), named: "  Trimmed  ", in: .keys)
        XCTAssertEqual(created.name, "Trimmed")

        XCTAssertThrowsError(try store.sounds.rename(created, to: "")) {
            XCTAssertEqual($0 as? SoundLibraryError, .nameIsEmpty)
        }
        XCTAssertEqual(try store.sounds.sound(withID: created.id)?.name, "Trimmed")
    }

    // MARK: Failure behaviour

    /// A save that the store refuses must leave the previous version of that
    /// sound exactly where it was — not half-written, and not gone.
    func testAStoreFailureOnSaveLeavesTheExistingEntryIntact() throws {
        let store = try launch()
        defer { store.close() }

        let created = try store.sounds.create(
            patch: testPatch(cutoff: 4_321), named: "Precious", in: .pads
        )

        // A trigger standing in for the real failures — a damaged database, a
        // full disk — because a refused write is the behaviour under test, not
        // the reason it was refused.
        try store.database.executeScript(
            """
            CREATE TRIGGER refuse_updates_to_precious
                BEFORE UPDATE ON \(SoundCatalog.tableName)
                WHEN OLD.name = 'Precious'
            BEGIN
                SELECT RAISE(ABORT, 'the disk is full');
            END;
            """
        )

        XCTAssertThrowsError(try store.sounds.rename(created, to: "Renamed")) { error in
            guard case SoundLibraryError.storeFailed(let name, let reason) = error else {
                return XCTFail("Expected storeFailed, got \(error)")
            }
            XCTAssertEqual(name, "Precious", "The failure must name the sound")
            XCTAssertFalse(reason.isEmpty)
        }

        let survivor = try XCTUnwrap(try store.sounds.sound(withID: created.id))
        XCTAssertEqual(survivor.name, "Precious")
        XCTAssertEqual(survivor.revision, 1, "A refused write must not have bumped anything")
        XCTAssertEqual(survivor.patch.filter.cutoffHertz, 4_321)
        XCTAssertEqual(try store.sounds.userSoundCount(), 1)
    }

    func testAPatchOutsideTheEnginesRangesIsReportedNotSilentlyClamped() throws {
        let store = try launch()
        defer { store.close() }

        var impossible = testPatch()
        impossible.filter.cutoffHertz = 900_000

        XCTAssertThrowsError(
            try store.sounds.create(patch: impossible, named: "Impossible", in: .leads)
        ) { error in
            guard case SoundLibraryError.documentRejected(let name, let reason) = error else {
                return XCTFail("Expected documentRejected, got \(error)")
            }
            XCTAssertEqual(name, "Impossible")
            XCTAssertTrue(
                reason.contains("filter.cutoffHertz"),
                "The reason must name the parameter: \(reason)"
            )
        }
        XCTAssertEqual(try store.sounds.userSoundCount(), 0)
    }

    func testARowThisBuildCannotReadIsReportedRatherThanSkipped() throws {
        let store = try launch()
        defer { store.close() }
        _ = try store.sounds.create(patch: testPatch(), named: "Fine", in: .keys)

        // A category from a build that does not exist.
        try store.database.execute(
            """
            INSERT INTO \(SoundCatalog.tableName)
                (id, name, category, shipped_origin_id, document_version,
                 document, revision, created_at, updated_at)
            VALUES ('user.from-the-future', 'Future', 'gamelan', NULL, 1, ?, 1, '', '');
            """,
            [.text(String(decoding: try SynthPatchDocument.data(from: .defaultVoice), as: UTF8.self))]
        )

        XCTAssertThrowsError(try store.sounds.allSounds()) { error in
            guard case StoreError.soundRowUnreadable(let id, let reason) = error else {
                return XCTFail("Expected soundRowUnreadable, got \(error)")
            }
            XCTAssertEqual(id, "user.from-the-future")
            XCTAssertTrue(reason.contains("gamelan"), reason)
        }
    }

    func testADocumentThisBuildCannotReadIsReportedRatherThanSkipped() throws {
        let store = try launch()
        defer { store.close() }

        try store.database.executeScript(
            """
            INSERT INTO \(SoundCatalog.tableName)
                (id, name, category, shipped_origin_id, document_version,
                 document, revision, created_at, updated_at)
            VALUES ('user.corrupt', 'Corrupt', 'keys', NULL, 1,
                    'this is not a patch document', 1, '', '');
            """
        )

        XCTAssertThrowsError(try store.sounds.allSounds()) { error in
            guard case StoreError.soundRowUnreadable(let id, _) = error else {
                return XCTFail("Expected soundRowUnreadable, got \(error)")
            }
            XCTAssertEqual(id, "user.corrupt")
        }
    }

    /// The row's recorded format version and the document's own must agree.
    ///
    /// They cannot disagree by accident today — there is one version — but the
    /// column exists so a future forward migration can ask "which sounds are
    /// below format version N?", and that query is only trustworthy if
    /// something keeps the two honest. This is that something.
    func testARowWhoseFormatVersionDisagreesWithItsDocumentIsRefused() throws {
        let store = try launch()
        defer { store.close() }

        try store.database.execute(
            """
            INSERT INTO \(SoundCatalog.tableName)
                (id, name, category, shipped_origin_id, document_version,
                 document, revision, created_at, updated_at)
            VALUES ('user.mislabelled', 'Mislabelled', 'keys', NULL, 7, ?, 1, '', '');
            """,
            [.text(String(decoding: try SynthPatchDocument.data(from: .defaultVoice), as: UTF8.self))]
        )

        XCTAssertThrowsError(try store.sounds.allSounds()) { error in
            guard case StoreError.soundRowUnreadable(let id, let reason) = error else {
                return XCTFail("Expected soundRowUnreadable, got \(error)")
            }
            XCTAssertEqual(id, "user.mislabelled")
            XCTAssertTrue(reason.contains("7"), reason)
            XCTAssertTrue(reason.contains("\(SynthPatch.currentVersion)"), reason)
        }
    }

    /// Everything the library writes itself satisfies that invariant.
    func testEverySoundTheLibraryWritesRecordsItsRealFormatVersion() throws {
        let store = try launch()
        defer { store.close() }

        let created = try store.sounds.create(patch: testPatch(), named: "Consistent", in: .keys)
        _ = try store.sounds.rename(created, to: "Consistent Still")
        _ = try store.sounds.makeEditableCopy(of: store.sounds.shippedSounds[0])

        let rows = try store.database.query(
            "SELECT document_version, document FROM \(SoundCatalog.tableName);"
        )
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            let recorded = try XCTUnwrap(row.integer("document_version"))
            let declared = try SynthPatchDocument.version(
                of: Data(try XCTUnwrap(row.text("document")).utf8)
            )
            XCTAssertEqual(Int(recorded), declared)
        }
    }

    /// The recovery text has to match what actually happens. Reading is
    /// all-or-nothing — one bad row stops the whole list — so a message that
    /// reassured the owner their other sounds were fine would be wrong at the
    /// exact moment they are deciding whether they have lost their work.
    func testTheUnreadableRowMessageDoesNotPromiseTheOtherSoundsAreListable() throws {
        let error = StoreError.soundRowUnreadable(id: "user.corrupt", reason: "It is not a patch.")
        let text = [error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")

        XCTAssertTrue(text.contains("cannot list"), text)
        XCTAssertTrue(text.contains("No sounds can be listed"), text)
        XCTAssertFalse(text.lowercased().contains("unaffected"), text)
        XCTAssertTrue(text.contains("backup"), text)
    }

    func testDeletingASoundThatIsAlreadyGoneIsReportedNotSilent() throws {
        let store = try launch()
        defer { store.close() }

        let created = try store.sounds.create(patch: testPatch(), named: "Once", in: .keys)
        try store.sounds.delete(created)

        XCTAssertThrowsError(try store.sounds.delete(created)) { error in
            XCTAssertEqual(error as? SoundLibraryError, .soundNotFound(name: "Once"))
        }
    }

    func testSoundLibraryErrorsAreOwnerReadable() {
        let errors: [SoundLibraryError] = [
            .shippedSoundIsReadOnly(name: "Warm Analog Pad"),
            .soundNotFound(name: "Gone"),
            .nameIsEmpty,
            .identityRetired(id: "user.dead"),
            .documentRejected(name: "Broken", reason: "filter.cutoffHertz is 900000."),
            .dependentRefused(name: "Used", dependent: "presets", reason: "The disk is full."),
            .storeFailed(name: "Precious", reason: "The disk is full.")
        ]

        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error) has no description")
            XCTAssertNotNil(error.recoverySuggestion, "\(error) has no recovery suggestion")
        }
    }

    // MARK: Live references (the seam increment 004 uses for REQ-029)

    func testDeletingASoundHandsItToEveryLiveReferenceFirst() throws {
        let recorder = RecordingDependent()
        let store = try launch(soundDependentStores: [{ _ in recorder }])
        defer { store.close() }

        let created = try store.sounds.create(patch: testPatch(cutoff: 777), named: "Referenced", in: .bells)
        try store.sounds.delete(created)

        XCTAssertEqual(recorder.seen.count, 1)
        let seen = try XCTUnwrap(recorder.seen.first)
        XCTAssertEqual(seen.id, created.id)
        XCTAssertEqual(seen.name, "Referenced")
        XCTAssertEqual(
            seen.patch.filter.cutoffHertz, 777,
            "A holder must get the whole sound, or it cannot embed a copy of it"
        )
        // Handed over before the row went, but the row really did go.
        XCTAssertNil(try store.sounds.sound(withID: created.id))
    }

    func testAReferenceHolderThatRefusesLeavesTheSoundInPlace() throws {
        let refusing = RefusingDependent()
        let store = try launch(soundDependentStores: [{ _ in refusing }])
        defer { store.close() }

        let created = try store.sounds.create(patch: testPatch(), named: "Safe", in: .bells)

        XCTAssertThrowsError(try store.sounds.delete(created)) { error in
            guard case SoundLibraryError.dependentRefused(let name, let dependent, _) = error else {
                return XCTFail("Expected dependentRefused, got \(error)")
            }
            XCTAssertEqual(name, "Safe")
            XCTAssertEqual(dependent, "test reference holder")
        }

        XCTAssertNotNil(try store.sounds.sound(withID: created.id))
        XCTAssertFalse(
            try store.sounds.isRetired(id: created.id),
            "A rolled-back delete must not have retired the identity"
        )
    }

    private final class RecordingDependent: SoundDependentStore, @unchecked Sendable {
        private(set) var seen: [SoundEntry] = []
        let dependentDescription = "test reference holder"
        func soundWillBeDeleted(_ sound: SoundEntry, in database: SQLiteDatabase) throws {
            seen.append(sound)
        }
    }

    private struct RefusingDependent: SoundDependentStore {
        struct Refused: LocalizedError { var errorDescription: String? { "The disk is full." } }
        let dependentDescription = "test reference holder"
        func soundWillBeDeleted(_ sound: SoundEntry, in database: SQLiteDatabase) throws {
            throw Refused()
        }
    }

    // MARK: Listing

    func testTheLibraryIsListedByCategoryThenNameDeterministically() throws {
        let store = try launch()
        defer { store.close() }
        _ = try store.sounds.create(patch: testPatch(), named: "zzz Last Pad", in: .pads)
        _ = try store.sounds.create(patch: testPatch(), named: "aaa First Key", in: .keys)

        let grouped = try store.sounds.soundsByCategory()
        let categories = grouped.map(\.category)
        XCTAssertEqual(
            categories,
            SoundCategory.allCases.filter { category in categories.contains(category) },
            "Categories must come out in declaration order"
        )
        XCTAssertFalse(grouped.contains { $0.sounds.isEmpty })

        let keys = try XCTUnwrap(grouped.first { $0.category == .keys }?.sounds)
        XCTAssertEqual(keys.first?.name, "aaa First Key")

        // Listing twice gives the same answer.
        XCTAssertEqual(try store.sounds.allSounds().map(\.id), try store.sounds.allSounds().map(\.id))
    }

    // MARK: Migration from the previous build's schema

    /// A store the previous build wrote — schema v3, with pieces and
    /// preferences in it — opens at the new schema with everything intact.
    func testAStoreAtSchemaThreeMigratesForwardKeepingEverything() throws {
        try container.prepare()

        // Exactly the chain the previous build shipped.
        let previousBuildChain = Array(SchemaMigrator.migrations.prefix(3))
        XCTAssertEqual(previousBuildChain.last?.version, 3)

        do {
            let database = try SQLiteDatabase.open(at: container.databaseURL)
            defer { database.close() }
            try SchemaMigrator.migrate(
                database, appVersion: "0.9 (1)", migrations: previousBuildChain
            )
            try database.execute(
                """
                INSERT INTO pieces (
                    id, title, composer, work_title, work_number, movement_title,
                    movement_number, source_file_name, source_format,
                    content_file_name, content_sha256, content_byte_count, imported_at
                ) VALUES (?, ?, NULL, NULL, NULL, NULL, NULL, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .text("piece-1"), .text("Still Here"), .text("kept.musicxml"),
                    .text("musicxml"), .text("kept-content.musicxml"), .text("abc123"),
                    .integer(12), .text("2026-01-01T00:00:00Z")
                ]
            )
            try PreferenceStore(database: database)
                .setHumanization(HumanizationSettings(isEnabled: false, intensity: 42))
            XCTAssertFalse(try database.tableExists(SoundCatalog.tableName))
        }

        let store = try launch()
        defer { store.close() }

        XCTAssertEqual(store.migrationOutcome.previousVersion, 3)
        XCTAssertEqual(store.migrationOutcome.currentVersion, SchemaMigrator.latestVersion)
        XCTAssertEqual(
            store.migrationOutcome.appliedMigrationNames, ["create_sounds", "create_presets", "create_installed_instrument_libraries"]
        )

        // Nothing the previous build wrote was disturbed.
        XCTAssertEqual(try store.pieceCount(), 1)
        XCTAssertEqual(
            try store.database.scalarText("SELECT title FROM pieces WHERE id = 'piece-1';"),
            "Still Here"
        )
        XCTAssertEqual(
            store.preferences.humanization(),
            HumanizationSettings(isEnabled: false, intensity: 42)
        )

        // And the sound library works on the migrated store.
        XCTAssertEqual(try store.sounds.userSoundCount(), 0)
        XCTAssertEqual(
            try store.sounds.allSounds().count,
            ShippedSoundCollection.standard.sounds.count
        )
        let created = try store.sounds.create(patch: testPatch(), named: "After Migration", in: .keys)
        XCTAssertEqual(try store.sounds.sound(withID: created.id)?.name, "After Migration")
    }

    /// What reverting this build actually does to a store it already migrated.
    ///
    /// The forward-only migrator refuses a store written by a newer build
    /// rather than guessing — the contract LIB001 established and every
    /// increment since has inherited. So an earlier binary does not silently
    /// open a v4 store; it says so, by name and version, and **touches
    /// nothing**. That second half is what makes the revert safe: because this
    /// step only added tables, every byte the earlier build wrote is still
    /// exactly where it was, so rolling forward again recovers the whole
    /// library including the sounds.
    func testAnEarlierBuildRefusesThisStoreLoudlyWithoutDamagingIt() throws {
        do {
            let store = try launch()
            defer { store.close() }
            _ = try store.sounds.create(patch: testPatch(), named: "Orphaned By A Revert", in: .keys)
        }

        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }

        XCTAssertThrowsError(
            try SchemaMigrator.migrate(
                database, appVersion: "0.9 (1)",
                migrations: Array(SchemaMigrator.migrations.prefix(3))
            )
        ) { error in
            guard case StoreError.storeWrittenByNewerApp = error else {
                return XCTFail("Expected storeWrittenByNewerApp, got \(error)")
            }
        }

        // Everything the store held is still there and still readable, because
        // nothing this leaf added touched it — including the sound it wrote.
        XCTAssertEqual(try database.scalarInt("SELECT count(*) FROM pieces;"), 0)
        XCTAssertTrue(try database.tableExists(PreferenceStore.tableName))
        XCTAssertEqual(try database.scalarInt("SELECT count(*) FROM \(SoundCatalog.tableName);"), 1)
    }
}

/// Issue #19, REQ-027: what VoiceOver says a row in the sound list is.
///
/// Asserted here rather than read off the running app's accessibility tree,
/// because an `AXOutline` does not vend its rows to a walk from inside the same
/// process — the gap PLY004 recorded for the piece list. The sentence is
/// therefore proved at the layer that can prove it.
final class SoundEntryAccessibilityTests: XCTestCase {
    private func entry(
        name: String,
        category: SoundCategory,
        origin: SoundOrigin
    ) -> SoundEntry {
        SoundEntry(
            id: origin == .shipped ? "builtin.\(name)" : "user.\(name)",
            name: name,
            category: category,
            origin: origin,
            documentVersion: SynthPatch.currentVersion,
            revision: origin == .shipped ? 0 : 1,
            createdAt: origin == .shipped ? "" : "2026-08-28T00:00:00Z",
            updatedAt: origin == .shipped ? "" : "2026-08-28T00:00:00Z",
            patch: .defaultVoice
        )
    }

    func testAShippedSoundSpeaksAsOneSentenceAndSaysItIsReadOnly() {
        XCTAssertEqual(
            entry(name: "Warm Analog Pad", category: .pads, origin: .shipped)
                .accessibilityDescription,
            "Warm Analog Pad, Pads, one of Synth's own sounds, read-only"
        )
    }

    func testTheOwnersSoundSpeaksAsOneSentenceAndSaysItIsTheirs() {
        XCTAssertEqual(
            entry(name: "Evening Bells", category: .bells, origin: .user)
                .accessibilityDescription,
            "Evening Bells, Bells, your sound"
        )
    }

    /// Every shipped sound has one, and no two of them read the same — a list
    /// where two rows speak identically is a list VoiceOver cannot navigate.
    func testEveryShippedSoundHasADistinctSpokenForm() {
        let spoken = ShippedSoundCollection.standard.sounds.map(\.accessibilityDescription)
        XCTAssertEqual(spoken.count, 13)
        XCTAssertEqual(Set(spoken).count, spoken.count, "Two shipped sounds read the same: \(spoken)")
        for sentence in spoken {
            XCTAssertTrue(sentence.hasSuffix("one of Synth's own sounds, read-only"), sentence)
        }
    }
}
