import XCTest
@testable import SynthKit

/// What a line does when its instrument is not there, and what a first open
/// maps lines to when it is (issue #24, REQ-007, REQ-020).
///
/// **The rule under test is that silence is the default and a substitute is a
/// decision.** A line assigned an instrument the owner has not downloaded is
/// flagged and renders nothing; it plays something else only after the owner
/// has been told and has said yes. Quietly handing it a synth patch would be
/// the pleasanter failure and is exactly the state this leaf exists to prevent,
/// so most of this file is about proving it does not happen.
final class InstrumentAssignmentTests: XCTestCase {
    private var directory: URL!
    private var container: AppContainer!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "InstrumentAssignmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = AppContainer(rootURL: directory)
        store = try LibraryStore.open(container: container, appVersion: "test")
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: Resolving one reference

    private var celloReference: InstrumentReference {
        InstrumentReference(
            libraryID: "vsco2-ce",
            instrumentID: "vsco2.cello.section",
            libraryName: "VSCO 2 Community Edition",
            instrumentName: "Cello section"
        )
    }

    func testANotDownloadedInstrumentIsNotADamagedStore() throws {
        let resolution = try store.instruments.resolve(celloReference)
        guard case .notDownloaded(let library, let instrument) = resolution else {
            return XCTFail("Expected notDownloaded, got \(resolution)")
        }
        XCTAssertEqual(library.identifier, "vsco2-ce")
        XCTAssertEqual(instrument.name, "Cello section")
        XCTAssertTrue(resolution.isFixableByDownloading)
    }

    func testAnInstalledLibraryWithMissingFilesIsItsOwnCase() throws {
        // A row says the library is installed, but nothing is on disk — an
        // interrupted install, or files deleted from underneath the app.
        try store.instruments.recordInstall(
            of: try XCTUnwrap(InstrumentCatalog.library(withIdentifier: "vsco2-ce"))
        )
        let resolution = try store.instruments.resolve(celloReference)
        guard case .filesMissing = resolution else {
            return XCTFail("Expected filesMissing, got \(resolution)")
        }
        XCTAssertTrue(resolution.isFixableByDownloading, "Re-downloading is the fix")
    }

    func testAnInstrumentThisBuildDoesNotHaveSaysDownloadingWillNotHelp() throws {
        let gone = InstrumentReference(
            libraryID: "some-library-a-later-build-had",
            instrumentID: "some.instrument",
            libraryName: "Some Library",
            instrumentName: "Some Instrument"
        )
        let resolution = try store.instruments.resolve(gone)
        guard case .notInThisVersion = resolution else {
            return XCTFail("Expected notInThisVersion, got \(resolution)")
        }
        XCTAssertFalse(
            resolution.isFixableByDownloading,
            "There is nothing to download, so the flag must not offer one"
        )
    }

    func testInstallingTheLibraryResolvesTheReference() throws {
        _ = try installCello()
        let resolution = try store.instruments.resolve(celloReference)
        XCTAssertTrue(resolution.isPlayable)
        XCTAssertEqual(resolution.available?.coverage.name, "Cello section")
    }

    // MARK: Family gaps — the harpsichord ruling (INS001)

    /// "Not downloaded" and "no openly licensed source exists" are two different
    /// facts, and the second must never wear the first's wording.
    func testAFamilyWithNothingDownloadedOffersTheDownload() throws {
        let gaps = try store.instruments.familyGaps()
        let strings = try XCTUnwrap(gaps.first { $0.family == .strings })

        XCTAssertTrue(strings.isFixableByDownloading)
        XCTAssertTrue(
            strings.explanation.contains("instrument catalog"),
            strings.explanation
        )
        XCTAssertTrue(strings.explanation.contains("VSCO 2"), strings.explanation)
    }

    /// Every REQ-020 family this build's catalog covers is a download away, and
    /// nothing else is claimed.
    func testEveryFamilyGapIsClassifiedByWhetherTheCatalogCouldCoverIt() throws {
        for gap in try store.instruments.familyGaps() {
            let sources = InstrumentCatalog.libraries.filter { $0.families.contains(gap.family) }
            switch gap {
            case .notDownloaded(_, let libraries):
                XCTAssertFalse(sources.isEmpty, "\(gap.family) claims a source it does not have")
                XCTAssertEqual(libraries.map(\.identifier), sources.map(\.identifier))
            case .noOpenlyLicensedSource:
                XCTAssertTrue(
                    sources.isEmpty,
                    "\(gap.family) is covered by \(sources.map(\.name)); "
                        + "calling it sourceless would be untrue"
                )
                XCTAssertTrue(
                    gap.explanation.contains("downloading will not produce one"),
                    gap.explanation
                )
            }
        }
    }

    /// A line whose part is one of the instruments this build genuinely cannot
    /// supply says so, even while it is happily playing the closest thing.
    ///
    /// INS001's owner ruling is that no clean-licence harpsichord exists. The
    /// catalog says so at catalog level; this is the same fact at line level,
    /// so the owner knows why a harpsichord part is being played by something
    /// else rather than assuming a download will fix it.
    func testAHarpsichordPartSaysNoOpenlyLicensedSourceExists() throws {
        let piece = try importScore(Self.namedEnsemble(), named: "ensemble.musicxml")
        let performance = try store.openActivePreset(for: try compile(piece))

        let harpsichord = try XCTUnwrap(
            performance.lines.first { $0.name.localizedCaseInsensitiveContains("harpsichord") },
            "The fixture must have a harpsichord line"
        )
        let advice = try XCTUnwrap(
            harpsichord.advice.first,
            "A harpsichord line must carry the shortfall, not stay silent about it"
        )
        guard case .noOpenlyLicensedSource(let named, let playing) = advice else {
            return XCTFail("Expected noOpenlyLicensedSource, got \(advice)")
        }
        XCTAssertEqual(named, "harpsichord")
        XCTAssertFalse(playing.isEmpty, "It must say what is playing instead")
        XCTAssertFalse(advice.isFixableByDownloading)
        XCTAssertFalse(advice.isSilent, "It is playing something; it is not silent")
        XCTAssertTrue(
            advice.explanation.contains("openly licensed source"),
            advice.explanation
        )
    }

    /// The guarded case ASN001 recorded, now doubly live: "harpsichord"
    /// contains "harp", and this build has a harp and no harpsichord at all.
    func testAHarpsichordNeverMapsToAHarp() throws {
        _ = try installCello()
        let entry = LineEntry(
            id: ScoreLineID(partID: "P1", staff: 1, voice: "1"),
            defaultName: "Harpsichord",
            partName: "Harpsichord"
        )

        XCTAssertEqual(
            PresetAutoAssignment.family(for: entry), .keyboards,
            "A harpsichord is a keyboard instrument, whatever substring it contains"
        )
        XCTAssertEqual(
            PresetAutoAssignment.category(for: entry), .keys,
            "…and the synth fallback agrees"
        )
    }

    // MARK: A missing instrument is silent, not substituted (issue #24)

    func testALineAssignedANotDownloadedInstrumentIsFlaggedAndSilent() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let inventory = try store.lineInventory(for: score)
        let preset = try store.presets.activePreset(
            for: inventory, palette: try store.sounds.allSounds()
        )
        let line = try XCTUnwrap(preset.lines.first).lineID

        // Assign the cello's identity while nothing is installed — which is
        // what re-opening a piece on another machine, or after removing a
        // library, produces.
        _ = try store.presets.assign(
            .library(kind: .instrument, soundID: celloReference.soundID),
            toLine: line, in: preset
        )

        let performance = try store.openActivePreset(for: score)
        let resolved = try XCTUnwrap(performance.lines.first { $0.lineID == line })

        guard case .instrumentNotInstalled(_, let reference) = resolved.source else {
            return XCTFail("Expected instrumentNotInstalled, got \(resolved.source)")
        }
        XCTAssertEqual(reference.instrumentName, "Cello section")
        XCTAssertFalse(resolved.source.isMissing, "This is not a damaged store")

        let advice = try XCTUnwrap(resolved.advice.first)
        XCTAssertTrue(advice.isSilent)
        XCTAssertTrue(advice.isFixableByDownloading)
        XCTAssertTrue(advice.explanation.contains("this line is silent"), advice.explanation)
        XCTAssertTrue(advice.explanation.contains("instrument catalog"), advice.explanation)

        // The provider is silence, not a synth patch wearing the cello's name.
        let provider = resolved.voiceProvider(instruments: store.sampledInstruments)
        XCTAssertTrue(
            provider is SilentVoiceProvider,
            "A missing instrument must not be substituted without the owner's say-so; "
                + "got \(type(of: provider))"
        )
        XCTAssertEqual(provider.displayName, "Cello section", "It still says what is missing")

        // And a substitute is *offered*, named, so the owner can choose it.
        XCTAssertTrue(resolved.canOfferSubstitution)
        let offer = try XCTUnwrap(AssignmentDisplay.substitutionOffer(resolved))
        XCTAssertTrue(offer.hasPrefix("Play “"), offer)
    }

    func testTheOwnersAcknowledgementIsWhatMakesTheLineSubstitute() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let inventory = try store.lineInventory(for: score)
        var preset = try store.presets.activePreset(
            for: inventory, palette: try store.sounds.allSounds()
        )
        let line = try XCTUnwrap(preset.lines.first).lineID
        preset = try store.presets.assign(
            .library(kind: .instrument, soundID: celloReference.soundID),
            toLine: line, in: preset
        )

        // The owner presses the button.
        _ = try store.presets.setAcceptsSubstitution(true, forLine: line, in: preset)

        let performance = try store.openActivePreset(for: score)
        let resolved = try XCTUnwrap(performance.lines.first { $0.lineID == line })

        XCTAssertTrue(resolved.acceptsSubstitution)
        let advice = try XCTUnwrap(resolved.advice.first)
        XCTAssertTrue(advice.isSilent, "The instrument is still missing")

        let provider = resolved.voiceProvider(instruments: store.sampledInstruments)
        XCTAssertTrue(
            provider is SynthPatchVoiceProvider,
            "After the acknowledgment the line plays the named substitute; got \(type(of: provider))"
        )
        XCTAssertEqual(
            provider.identifier,
            SynthPatchVoiceProvider(patch: try XCTUnwrap(resolved.substitute).patch).identifier
        )
    }

    /// "Downloading resolves the flag."
    func testInstallingTheInstrumentClearsTheFlagWithoutTouchingThePreset() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let inventory = try store.lineInventory(for: score)
        let preset = try store.presets.activePreset(
            for: inventory, palette: try store.sounds.allSounds()
        )
        let line = try XCTUnwrap(preset.lines.first).lineID
        let assigned = try store.presets.assign(
            .library(kind: .instrument, soundID: celloReference.soundID),
            toLine: line, in: preset
        )

        XCTAssertFalse(try store.openActivePreset(for: score).silentLines.isEmpty)

        _ = try installCello()

        let after = try store.openActivePreset(for: score)
        let resolved = try XCTUnwrap(after.lines.first { $0.lineID == line })
        XCTAssertTrue(resolved.advice.isEmpty, "Downloading it resolves the flag automatically")
        XCTAssertFalse(resolved.isSilent)
        XCTAssertTrue(
            resolved.voiceProvider(instruments: store.sampledInstruments)
                is SampledInstrumentVoiceProvider,
            "The line now plays the instrument it was assigned"
        )

        // The preset was never rewritten to work around the absence.
        let stored = try XCTUnwrap(try store.presets.preset(withID: assigned.id))
        XCTAssertEqual(
            stored.line(withID: line)?.assignment,
            .library(kind: .instrument, soundID: celloReference.soundID)
        )
    }

    /// An offline render must make the same decision live playback does.
    func testAnOfflineRenderOfAMissingInstrumentIsSilentRatherThanSubstituted() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let inventory = try store.lineInventory(for: score)
        let preset = try store.presets.activePreset(
            for: inventory, palette: try store.sounds.allSounds()
        )
        for line in preset.lines {
            _ = try store.presets.assign(
                .library(kind: .instrument, soundID: celloReference.soundID),
                toLine: line.lineID,
                in: try XCTUnwrap(try store.presets.preset(withID: preset.id))
            )
        }

        let performance = try store.openActivePreset(for: score)
        let realized = PerformanceRealizer().realize(score, settings: .literal)
        let rendered = try PlaybackEngine.renderTimelineOffline(
            realized, voices: performance.voiceAssignment(instruments: store.sampledInstruments)
        )
        XCTAssertEqual(
            max(
                AudioRenderFixtures.peak(rendered.left),
                AudioRenderFixtures.peak(rendered.right)
            ),
            0, accuracy: 1e-9,
            "Every line's instrument is missing and unacknowledged, so the render is silent — "
                + "not a piece full of synth patches nobody asked for"
        )
    }

    // MARK: An unbuilt voice is flagged rather than silently silent

    /// Carried forward from INS002, which recorded the failure and left the
    /// flag to this leaf.
    ///
    /// Driven with a provider that always fails to build rather than by
    /// exhausting the machine's memory: what is under test is that a failure
    /// becomes a flag, and the real allocation failure is one `if` above this.
    func testALineWhoseVoiceCouldNotBeBuiltIsFlaggedRatherThanQuietlySilent() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let realized = PerformanceRealizer().realize(score, settings: .literal)
        let performance = try store.openActivePreset(for: score)
        let failing = try XCTUnwrap(performance.lines.first).lineID

        let program = try RenderProgram(
            timeline: realized,
            sampleRate: 44_100,
            voices: LineVoiceAssignment { lineID -> any LineVoiceProvider in
                lineID == failing
                    ? UnbuildableVoiceProvider(displayName: "Cello section")
                    : SynthPatchVoiceProvider()
            }
        )

        XCTAssertEqual(program.unbuiltVoiceLineIDs, [failing])

        let reports = LineRenderHealth.silentLines(in: program, resolvedAs: performance.lines)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.lineID, failing)

        let flagged = performance.flaggingUnbuiltVoices(in: program)
        let line = try XCTUnwrap(flagged.lines.first { $0.lineID == failing })
        let advice = try XCTUnwrap(line.advice.last)
        guard case .silentVoice = advice else {
            return XCTFail("Expected silentVoice, got \(advice)")
        }
        XCTAssertTrue(advice.isSilent)
        XCTAssertTrue(
            advice.explanation.contains("playing silence rather than some other sound"),
            advice.explanation
        )
        XCTAssertTrue(
            flagged.lines.filter { $0.lineID != failing }.allSatisfy { $0.advice.isEmpty },
            "Only the line that actually failed is flagged"
        )
    }

    /// A provider that always fails, standing in for memory exhaustion.
    private struct UnbuildableVoiceProvider: LineVoiceProvider {
        let displayName: String
        var identifier: String { "unbuildable:\(displayName)" }
        var unbuiltVoiceCount: Int { 1 }

        func makeVoice(sampleRate: Double) -> LineVoiceInstance {
            SilentVoiceProvider(identifier: identifier, displayName: displayName)
                .makeVoice(sampleRate: sampleRate)
                .failing()
        }
    }

    // MARK: Instrument-aware auto-mapping (REQ-007)

    /// "First open of an orchestral piece with downloads present maps lines to
    /// the score-named instruments."
    func testFirstOpenMapsScoreNamedLinesToDownloadedInstruments() throws {
        _ = try installVSCO()

        let piece = try importScore(Self.namedEnsemble(), named: "ensemble.musicxml")
        let performance = try store.openActivePreset(for: try compile(piece))

        func sound(of partName: String) throws -> ResolvedLine {
            try XCTUnwrap(
                performance.lines.first { $0.name.localizedCaseInsensitiveContains(partName) },
                "no line for \(partName)"
            )
        }

        XCTAssertEqual(try sound(of: "Violin").source.displayName, "Violin section")
        XCTAssertEqual(try sound(of: "Trumpet").source.displayName, "Trumpet")
        XCTAssertEqual(try sound(of: "Contrabass").source.displayName, "Contrabass")

        // The harpsichord has no instrument anywhere, so it takes the closest
        // *keyboard* that is installed rather than a harp or a synth pluck.
        XCTAssertEqual(try sound(of: "Harpsichord").source.displayName, "Pipe organ")

        for line in performance.lines {
            XCTAssertFalse(line.isSilent, "\(line.name) should be playing something")
        }
    }

    /// With nothing downloaded, a first open is exactly what increment 004 made
    /// — so a piece the owner already knows sounds the same until they download.
    func testWithNoDownloadsFirstOpenIsUnchangedFromTheSynthOnlyBuild() throws {
        let piece = try importScore(Self.namedEnsemble(), named: "ensemble.musicxml")
        let performance = try store.openActivePreset(for: try compile(piece))

        for line in performance.lines {
            XCTAssertEqual(line.content.kind, .synth, "\(line.name) should be on a synth sound")
            XCTAssertFalse(line.isSilent, "\(line.name) must be playable")
        }
    }

    /// A part name that reads as one player takes the solo instrument, and one
    /// that reads as a desk takes the section — which is why the curated set
    /// ships both.
    func testAPartNameDecidesBetweenTheSoloAndTheSectionInstrument() throws {
        _ = try installVSCO()
        let instruments = try store.sounds.allSounds()

        func chosen(_ partName: String) throws -> String {
            let entry = LineEntry(
                id: ScoreLineID(partID: "P1", staff: 1, voice: "1"),
                defaultName: partName,
                partName: partName
            )
            return try XCTUnwrap(
                PresetAutoAssignment.instrument(for: entry, from: instruments), partName
            ).name
        }

        XCTAssertEqual(try chosen("Violin I"), "Violin section", "A desk number means a section")
        XCTAssertEqual(try chosen("Violin 2"), "Violin section")
        XCTAssertEqual(try chosen("Violins"), "Violin section", "A plural means a section")
        XCTAssertEqual(try chosen("Violin"), "Solo violin", "A bare part is one player")

        XCTAssertFalse(
            PresetAutoAssignment.namesASection("brass"),
            "A word that merely ends in double-s is not a plural"
        )
        XCTAssertFalse(PresetAutoAssignment.namesASection("contrabass"))
    }

    /// A part whose family is matched but whose name shares no word with any
    /// installed instrument still lands inside that family.
    func testAFamilyMatchWithoutANameMatchTakesTheFamilysFirstInstrument() throws {
        _ = try installVSCO()
        let instruments = try store.sounds.allSounds()
        let entry = LineEntry(
            id: ScoreLineID(partID: "P9", staff: 1, voice: "1"),
            defaultName: "Cor anglais",
            partName: "Cor anglais"
        )

        let chosen = try XCTUnwrap(PresetAutoAssignment.instrument(for: entry, from: instruments))
        XCTAssertEqual(chosen.category, SoundCategory.woodwinds)
        XCTAssertEqual(chosen.origin, SoundOrigin.instrument)
    }

    /// A "Bass drum" part is percussion, not a contrabass — the family rules
    /// resolve the shared word before the name pass ever sees it.
    func testABassDrumIsPercussionRatherThanAContrabass() throws {
        _ = try installVSCO()
        let instruments = try store.sounds.allSounds()
        let entry = LineEntry(
            id: ScoreLineID(partID: "P9", staff: 1, voice: "1"),
            defaultName: "Bass drum",
            partName: "Bass drum"
        )

        XCTAssertEqual(PresetAutoAssignment.family(for: entry), .percussion)
        let chosen = try XCTUnwrap(PresetAutoAssignment.instrument(for: entry, from: instruments))
        XCTAssertEqual(chosen.category, SoundCategory.percussion, "got \(chosen.name)")
    }

    // MARK: Fixtures

    /// Installs the whole VSCO catalog entry by writing one playable SFZ for
    /// every instrument it names, so the store resolves every one of them
    /// exactly as it would after a real download.
    @discardableResult
    private func installVSCO() throws -> [AvailableInstrument] {
        let library = try XCTUnwrap(InstrumentCatalog.library(withIdentifier: "vsco2-ce"))
        let root = store.instruments.stagingArea.installedURL(forLibraryID: library.identifier)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SFZFixtures.writeWave(
            SFZFixtures.sine(hertz: 440, seconds: 1.0), to: root.appending(path: "tone.wav")
        )
        for instrument in library.coverage {
            for path in instrument.allSFZPaths {
                let url = root.appending(path: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try """
                    <group> ampeg_attack=0 ampeg_release=0.2
                    <region> sample=tone.wav lokey=21 hikey=108 pitch_keycenter=69
                    """.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        try store.instruments.recordInstall(of: library)
        return try store.instruments.availableInstruments()
    }

    @discardableResult
    private func installCello() throws -> AvailableInstrument {
        let installed = try installVSCO()
        return try XCTUnwrap(
            installed.first { $0.coverage.identifier == "vsco2.cello.section" }
        )
    }

    private func importScore(_ musicXML: Data, named name: String) throws -> PieceRecord {
        let url = directory.appending(path: name)
        try musicXML.write(to: url)
        return try store.makeImporter().importPiece(from: url).piece
    }

    private func importFugue() throws -> PieceRecord {
        try importScore(MusicXMLScoreFixtures.keyboardFugueExposition(), named: "fugue.musicxml")
    }

    private func compile(_ piece: PieceRecord) throws -> CompiledScore {
        try ScoreCompiler().compile(piece: piece, contentStore: store.pieceContent)
    }

    /// A quartet whose parts are named after real instruments, including the
    /// one this build cannot supply.
    private static func namedEnsemble() -> Data {
        func part(id: String, name: String, pitch: String) -> ScoreXML.Part {
            ScoreXML.Part(
                id: id,
                name: name,
                measures: [
                    ScoreXML.Measure(
                        number: "1",
                        items: [
                            .attributes(
                                ScoreXML.Attributes(
                                    divisions: 4, fifths: 0, time: (4, 4), clefs: [("G", 2)]
                                )
                            ),
                            .note(ScoreXML.Note(pitch: pitch, duration: 16, type: "whole"))
                        ]
                    )
                ]
            )
        }
        return ScoreXML.Score(
            workTitle: "Named Ensemble",
            composer: "Fixture",
            parts: [
                part(id: "P1", name: "Violin I", pitch: "A5"),
                part(id: "P2", name: "Trumpet in B♭", pitch: "D5"),
                part(id: "P3", name: "Harpsichord", pitch: "F4"),
                part(id: "P4", name: "Contrabass", pitch: "A2")
            ]
        ).data()
    }
}

private extension LineVoiceInstance {
    /// The same voice, marked as one its provider meant to build and could not.
    func failing() -> LineVoiceInstance {
        LineVoiceInstance(vtable: vtable, didFailToBuild: true, release: release)
    }
}
