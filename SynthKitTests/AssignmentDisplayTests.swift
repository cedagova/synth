import Foundation
import XCTest
@testable import SynthKit

/// What the assignment and mixer panel says, asserted where it can be asserted.
///
/// A sentence assembled inside a SwiftUI `body` is untestable, so the panel
/// assembles none: every string, every fader position and the "how many lines
/// are actually being heard" rule live here, and the view only places them.
final class AssignmentDisplayTests: XCTestCase {

    // MARK: The fader

    func testUnityGainIsZeroDecibels() {
        XCTAssertEqual(AssignmentDisplay.decibels(forVolume: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(AssignmentDisplay.volumeText(1), "0.0 dB")
    }

    func testHalfGainIsSixDecibelsDown() {
        XCTAssertEqual(AssignmentDisplay.decibels(forVolume: 0.5), -6.0206, accuracy: 1e-3)
        XCTAssertEqual(AssignmentDisplay.volumeText(0.5), "-6.0 dB")
    }

    /// The two directions agree, which is what keeps a slider from drifting as
    /// it is dragged: every position it reports is a position it accepts back.
    func testTheFaderRoundTripsAtEveryPositionItCanReach() {
        for step in 0...78 {
            let decibels = AssignmentDisplay.minimumDecibels + Double(step)
            let volume = AssignmentDisplay.volume(forDecibels: decibels)
            guard volume > 0 else {
                XCTAssertEqual(decibels, AssignmentDisplay.minimumDecibels)
                continue
            }
            XCTAssertEqual(
                AssignmentDisplay.decibels(forVolume: volume), decibels, accuracy: 1e-6,
                "The fader did not come back to \(decibels) dB."
            )
        }
    }

    /// The bottom of the travel is silence, not sixty decibels of it. A fader
    /// the owner cannot use to turn a line off is not a fader.
    func testTheBottomOfTheFaderIsSilence() {
        XCTAssertEqual(AssignmentDisplay.volume(forDecibels: AssignmentDisplay.minimumDecibels), 0)
        XCTAssertEqual(AssignmentDisplay.volume(forDecibels: -1_000), 0)
        XCTAssertEqual(AssignmentDisplay.volumeText(0), "Silent")
        XCTAssertEqual(AssignmentDisplay.spokenVolume(0), "silent")
    }

    /// The top of the travel is inside what the store will accept, so a fader
    /// pushed all the way up can never be refused by `PresetDocument.validate`.
    func testTheTopOfTheFaderIsWithinWhatThePresetWillStore() {
        let loudest = AssignmentDisplay.volume(forDecibels: AssignmentDisplay.maximumDecibels)
        XCTAssertLessThanOrEqual(loudest, LineMixerState.maximumVolume)
        XCTAssertGreaterThan(loudest, 7.9)
        XCTAssertNoThrow(
            try PresetDocument.validate(
                PresetContent(lines: [
                    PresetLine(
                        lineID: ScoreLineID(rawValue: "p1.s1.v1"),
                        assignment: .library(kind: .synth, soundID: "s"),
                        mixer: LineMixerState(volume: loudest)
                    )
                ])
            )
        )
    }

    /// A fader cannot be pushed past what the preset will store, so a value out
    /// of range never reaches `PresetDocument.validate` to be refused.
    func testAVolumeAboveTheCeilingIsClampedRatherThanRefused() {
        let ceiling = AssignmentDisplay.volume(forDecibels: AssignmentDisplay.maximumDecibels)
        XCTAssertEqual(AssignmentDisplay.volume(forDecibels: 40), ceiling, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(ceiling, LineMixerState.maximumVolume)
    }

    func testSpokenVolumeSaysWhichWay() {
        XCTAssertEqual(AssignmentDisplay.spokenVolume(1), "unity")
        XCTAssertEqual(AssignmentDisplay.spokenVolume(0.5), "6.0 decibels down")
        XCTAssertEqual(AssignmentDisplay.spokenVolume(2), "6.0 decibels up")
    }

    // MARK: Pan

    func testPanTextIsTheShortFormAStripHasRoomFor() {
        XCTAssertEqual(AssignmentDisplay.panText(0), "Centre")
        XCTAssertEqual(AssignmentDisplay.panText(-0.6), "L60")
        XCTAssertEqual(AssignmentDisplay.panText(0.35), "R35")
        XCTAssertEqual(AssignmentDisplay.panText(1), "R100")
    }

    func testSpokenPanIsASentence() {
        XCTAssertEqual(AssignmentDisplay.spokenPan(0), "centre")
        XCTAssertEqual(AssignmentDisplay.spokenPan(-0.6), "60 percent left")
        XCTAssertEqual(AssignmentDisplay.spokenPan(1), "hard right")
        XCTAssertEqual(AssignmentDisplay.spokenPan(-1), "hard left")
    }

    // MARK: Where the sound came from (REQ-029's visible mark)

    func testALiveLibraryReferenceNeedsNoExplanation() {
        XCTAssertNil(AssignmentDisplay.sourceNote(.library(soundID: "s1", name: "Bright Lead")))
    }

    func testAnEmbeddedCopySaysSoAndSaysWhy() {
        let note = AssignmentDisplay.sourceNote(
            .embedded(originalSoundID: "s1", name: "Doomed")
        )
        XCTAssertEqual(
            note,
            "Embedded copy of “Doomed” — the sound it came from was deleted."
        )
    }

    func testAVanishedSoundIsNeverSilentAboutBeingOne() {
        let note = AssignmentDisplay.sourceNote(.missing(soundID: "s1", wasRetired: true))
        XCTAssertEqual(
            note,
            "That sound is no longer in your library, so this line is playing "
                + "Synth's default voice."
        )
    }

    // MARK: A whole strip, spoken (REQ-027)

    func testAStripSpeaksItsNameSoundAndBothValues() {
        let line = Self.line(named: "Soprano", soundNamed: "Bright Lead",
                             mixer: LineMixerState(volume: 0.5, pan: -0.6))
        XCTAssertEqual(
            AssignmentDisplay.spokenStrip(line),
            "Soprano, Bright Lead. Volume 6.0 decibels down, pan 60 percent left, dry, no room."
        )
    }

    func testAMutedStripSaysSo() {
        let line = Self.line(named: "Bass", soundNamed: "Deep Sub",
                             mixer: LineMixerState(isMuted: true))
        XCTAssertEqual(
            AssignmentDisplay.spokenStrip(line),
            "Bass, Deep Sub, muted. Volume unity, pan centre, dry, no room."
        )
    }

    func testAnEmbeddedStripSaysThatToo() {
        let line = ResolvedLine(
            lineID: ScoreLineID(rawValue: "p1.s1.v1"),
            name: "Tenor",
            source: .embedded(originalSoundID: "s9", name: "Doomed"),
            content: .synth(.defaultVoice),
            mixer: .neutral
        )
        XCTAssertEqual(
            AssignmentDisplay.spokenStrip(line),
            "Tenor, Doomed, embedded copy. Volume unity, pan centre, dry, no room."
        )
    }

    // MARK: What is actually being heard

    /// The engine's rule, restated: mute wins over solo, and while anything is
    /// soloed every line that is not is silent. `LineMixerRenderTests` proves
    /// the engine behaves this way; this proves the panel says so.
    func testMuteWinsOverSoloJustAsTheEngineHasIt() {
        let line = Self.line(named: "L", soundNamed: "S",
                             mixer: LineMixerState(isMuted: true, isSoloed: true))
        XCTAssertFalse(AssignmentDisplay.isAudible(line, whileSoloing: true))
    }

    func testAnUnsoloedLineIsSilentWhileAnythingIsSoloed() {
        let plain = Self.line(named: "L", soundNamed: "S", mixer: .neutral)
        XCTAssertTrue(AssignmentDisplay.isAudible(plain, whileSoloing: false))
        XCTAssertFalse(AssignmentDisplay.isAudible(plain, whileSoloing: true))
    }

    func testTheSummaryCountsWhatIsHeard() {
        let lines = [
            Self.line(named: "1", soundNamed: "S", mixer: .neutral),
            Self.line(named: "2", soundNamed: "S", mixer: .neutral),
            Self.line(named: "3", soundNamed: "S", mixer: LineMixerState(isMuted: true)),
            Self.line(named: "4", soundNamed: "S", mixer: .neutral)
        ]
        XCTAssertEqual(AssignmentDisplay.audibleLineCount(lines), 3)
        XCTAssertEqual(AssignmentDisplay.mixSummary(lines), "4 lines · 1 muted · 3 heard")
    }

    func testTheSummarySaysWhenOneVoiceIsAllYouAreHearing() {
        var lines = (1...4).map {
            Self.line(named: "\($0)", soundNamed: "S", mixer: .neutral)
        }
        lines[2] = Self.line(named: "3", soundNamed: "S", mixer: LineMixerState(isSoloed: true))
        XCTAssertEqual(AssignmentDisplay.audibleLineCount(lines), 1)
        XCTAssertEqual(AssignmentDisplay.mixSummary(lines), "4 lines · 1 soloed · 1 heard")
    }

    /// **The summary must not count a line as heard while the panel is telling
    /// the owner it is silent.**
    ///
    /// A line whose instrument is not downloaded is routed — nothing muted it
    /// and nothing is soloed over it — and produces nothing, because issue #24
    /// requires exactly that. Folding it into "heard" made this sentence
    /// contradict the banner directly above it, which the review caught in the
    /// PR's own screenshot: six lines, one flagged silent, "6 heard".
    func testTheSummaryDoesNotCountASilentLineAsHeard() {
        var lines = (1...6).map {
            Self.line(named: "\($0)", soundNamed: "S", mixer: .neutral)
        }
        lines[4] = Self.silentLine(named: "5")

        XCTAssertTrue(
            AssignmentDisplay.isRouted(lines[4], whileSoloing: false),
            "Nothing muted it and nothing is soloed over it"
        )
        XCTAssertFalse(
            AssignmentDisplay.isHeard(lines[4], whileSoloing: false),
            "…and it is still producing nothing"
        )
        XCTAssertEqual(AssignmentDisplay.audibleLineCount(lines), 5)
        XCTAssertEqual(AssignmentDisplay.silentLineCount(lines), 1)
        XCTAssertEqual(AssignmentDisplay.mixSummary(lines), "6 lines · 1 silent · 5 heard")
    }

    /// A muted line that is *also* silent is counted once, as muted.
    ///
    /// It is not routed, so it is not one of the lines this leaf's new count is
    /// about: the owner turned it off, which is a different fact from the app
    /// having nothing to play.
    func testAMutedSilentLineIsCountedAsMutedRatherThanTwice() {
        var lines = (1...3).map {
            Self.line(named: "\($0)", soundNamed: "S", mixer: .neutral)
        }
        lines[1] = Self.silentLine(named: "2", mixer: LineMixerState(isMuted: true))

        XCTAssertEqual(AssignmentDisplay.silentLineCount(lines), 0)
        XCTAssertEqual(AssignmentDisplay.audibleLineCount(lines), 2)
        XCTAssertEqual(AssignmentDisplay.mixSummary(lines), "3 lines · 1 muted · 2 heard")
    }

    /// Once the owner accepts a stand-in, the line is heard again — and the
    /// summary says so, because the stand-in really is sounding.
    func testAcceptingAStandInPutsTheLineBackIntoTheHeardCount() {
        var lines = (1...3).map {
            Self.line(named: "\($0)", soundNamed: "S", mixer: .neutral)
        }
        lines[1] = Self.silentLine(named: "2")
        XCTAssertEqual(AssignmentDisplay.mixSummary(lines), "3 lines · 1 silent · 2 heard")

        lines[1] = Self.substitutedLine(named: "2")
        XCTAssertEqual(AssignmentDisplay.mixSummary(lines), "3 lines · 3 heard")
    }

    func testTheSummaryIsHonestAboutAnEmptyPiece() {
        XCTAssertEqual(AssignmentDisplay.mixSummary([]), "No lines.")
    }

    // MARK: Presets (REQ-024's auto-save indication)

    func testTheAutoSaveIndicationNamesThePresetAndItsRevision() {
        XCTAssertEqual(
            AssignmentDisplay.autoSaveText(Self.preset(named: "Chamber", revision: 7)),
            "Saved automatically — “Chamber”, revision 7."
        )
    }

    func testTheAutoSaveIndicationCopesWithHavingNoPresetYet() {
        XCTAssertEqual(AssignmentDisplay.autoSaveText(nil), "No preset yet.")
    }

    func testTheSpokenPresetSaysItIsActiveAndHowManyThereAre() {
        XCTAssertEqual(
            AssignmentDisplay.spokenPreset(Self.preset(named: "Chamber", revision: 1), of: 3),
            "Chamber, active, one of 3 presets"
        )
        XCTAssertEqual(
            AssignmentDisplay.spokenPreset(Self.preset(named: "Default", revision: 1), of: 1),
            "Default, active, the only preset"
        )
    }

    // MARK: Fixtures

    /// A line whose instrument is not downloaded: routed, flagged, and
    /// producing nothing.
    private static func silentLine(
        named name: String, mixer: LineMixerState = .neutral
    ) -> ResolvedLine {
        let reference = InstrumentReference(
            libraryID: "l", instrumentID: "i", libraryName: "L", instrumentName: "I"
        )
        return ResolvedLine(
            lineID: ScoreLineID(rawValue: "piece.\(name)"),
            name: name,
            source: .instrumentNotInstalled(soundID: reference.soundID, reference: reference),
            content: .instrument(InstrumentVariant(reference: reference)),
            instrumentResolution: .notInThisVersion(reference: reference),
            advice: [.notDownloaded(instrumentName: "I", libraryName: "L")],
            mixer: mixer
        )
    }

    /// The same line after the owner has accepted a stand-in: routed, flagged,
    /// and audibly playing something.
    private static func substitutedLine(named name: String) -> ResolvedLine {
        let reference = InstrumentReference(
            libraryID: "l", instrumentID: "i", libraryName: "L", instrumentName: "I"
        )
        return ResolvedLine(
            lineID: ScoreLineID(rawValue: "piece.\(name)"),
            name: name,
            source: .instrumentNotInstalled(soundID: reference.soundID, reference: reference),
            content: .instrument(InstrumentVariant(reference: reference)),
            instrumentResolution: .notInThisVersion(reference: reference),
            advice: [.substituted(instrumentName: "I", substituteName: "Nylon Pluck")],
            acceptsSubstitution: true,
            substitute: LineSubstitute(
                soundID: "builtin.pluck", name: "Nylon Pluck", patch: .defaultVoice
            ),
            mixer: .neutral
        )
    }

    private static func line(
        named name: String, soundNamed soundName: String, mixer: LineMixerState
    ) -> ResolvedLine {
        ResolvedLine(
            lineID: ScoreLineID(rawValue: "piece.\(name)"),
            name: name,
            source: .library(soundID: "sound.\(soundName)", name: soundName),
            content: .synth(.defaultVoice),
            mixer: mixer
        )
    }

    private static func preset(named name: String, revision: Int) -> Preset {
        Preset(
            id: "preset.1",
            pieceID: "piece.1",
            name: name,
            isActive: true,
            documentVersion: PresetContent.currentVersion,
            revision: revision,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            content: PresetContent(lines: [])
        )
    }
}
