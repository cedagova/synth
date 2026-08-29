import XCTest
@testable import SynthKit

/// REQ-021's central claim, tested where it is decided: a customization control
/// is offered only when the samples the owner actually downloaded can do the
/// thing it claims, and one that cannot is disabled *with an explanation*.
///
/// **Every capability here is measured, never declared.** Each test writes real
/// SFZ text and real WAV files, loads them through `SampledInstrument` — the
/// same entry point a downloaded library goes through — and asks
/// `InstrumentCapabilities` what that produced. Nothing switches on a library
/// identifier, which is issue #24's stated invariant, and a test that asserted
/// on a hand-built `SampledInstrumentFeatures` would have proved the switch
/// statement rather than the gate.
final class InstrumentCapabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try SFZFixtures.makeLibraryDirectory("capabilities")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func capabilities(
        of available: AvailableInstrument
    ) throws -> InstrumentCapabilities {
        let instrument = try SampledInstrument(available)
        return InstrumentCapabilities(
            features: instrument.features,
            coverage: available.coverage,
            alternateArticulationCount: available.alternateSFZURLs.count
        )
    }

    // MARK: Dynamics response (the acceptance criterion)

    /// "On an instrument with limited assets (e.g. a 1-layer VCSL patch),
    /// unsupported controls are disabled with an explanation."
    func testAOneLayerPatchCannotOfferDynamicsResponseAndSaysWhy() throws {
        let thin = try SFZFixtures.pitchedInstrument(in: root)
        let measured = try capabilities(of: thin)

        XCTAssertEqual(measured.sampledDynamicLayerCount, 1)

        let dynamics = measured.availability(of: .dynamicsResponse)
        XCTAssertFalse(
            dynamics.isSupported,
            "One sampled layer means there are no recorded dynamics to shape"
        )
        let explanation = try XCTUnwrap(dynamics.explanation)
        XCTAssertTrue(
            explanation.contains("one sampled dynamic layer"),
            "The explanation must state the measured fact: \(explanation)"
        )
        XCTAssertTrue(
            explanation.contains(thin.coverage.name),
            "The explanation must name the instrument: \(explanation)"
        )
    }

    /// "…on Salamander, dynamics-response is enabled."
    ///
    /// The fixture is Salamander-shaped rather than Salamander itself: sixteen
    /// velocity layers on one key with sampled releases behind them. The
    /// capability is measured from those files, so what this proves about the
    /// real library is proved by `testTheCuratedCatalogsOwnLayerCountsAreWhatTheGateReads`
    /// below plus the measurement here.
    func testASixteenLayerPatchOffersDynamicsResponse() throws {
        let deep = try SFZFixtures.deeplyLayeredInstrument(in: root)
        let measured = try capabilities(of: deep)

        XCTAssertEqual(measured.sampledDynamicLayerCount, 16)
        XCTAssertTrue(measured.isSupported(.dynamicsResponse))
        XCTAssertNil(measured.availability(of: .dynamicsResponse).explanation)
        XCTAssertTrue(
            measured.hasReleaseTriggers,
            "Sampled releases are part of what makes this instrument the deep one"
        )
    }

    /// The measurement wins over the catalog, and the disagreement is said out
    /// loud rather than resolved silently.
    func testWhenTheFilesAndTheCatalogDisagreeTheExplanationSaysBoth() throws {
        // One region on the key, but a catalog entry claiming eight layers —
        // the shape of a half-installed or re-pinned library.
        var thin = try SFZFixtures.pitchedInstrument(in: root)
        thin = AvailableInstrument(
            libraryID: thin.libraryID,
            libraryName: thin.libraryName,
            coverage: InstrumentCoverage(
                identifier: thin.coverage.identifier,
                name: thin.coverage.name,
                family: thin.coverage.family,
                sfzPath: thin.coverage.sfzPath,
                dynamicLayerCount: 8
            ),
            sfzURL: thin.sfzURL,
            alternateSFZURLs: thin.alternateSFZURLs,
            libraryRootURL: thin.libraryRootURL,
            requiredAttribution: thin.requiredAttribution
        )

        let measured = try capabilities(of: thin)
        XCTAssertFalse(measured.isSupported(.dynamicsResponse), "The files decide, not the catalog")

        let explanation = try XCTUnwrap(measured.availability(of: .dynamicsResponse).explanation)
        XCTAssertTrue(
            explanation.contains("catalog lists 8 layers"),
            "A disagreement must be visible rather than quietly resolved: \(explanation)"
        )
        XCTAssertTrue(explanation.contains("re-downloading"), explanation)
    }

    // MARK: Pitch controls

    func testAnUnpitchedPatchOffersNeitherVibratoNorTuning() throws {
        // Every region pins its sample to the recorded pitch, which is what a
        // General MIDI style percussion map does.
        let unpitched = try SFZFixtures.velocityLayeredInstrument(in: root)
        let measured = try capabilities(of: unpitched)

        XCTAssertFalse(measured.isPitched)
        for control in [InstrumentControl.vibrato, .tuning] {
            let availability = measured.availability(of: control)
            XCTAssertFalse(availability.isSupported, "\(control) must be off on an unpitched patch")
            let explanation = try XCTUnwrap(availability.explanation)
            XCTAssertTrue(
                explanation.contains("pins every sample to the pitch it was recorded at"),
                "\(control): \(explanation)"
            )
        }
    }

    func testAPitchedPatchOffersBothPitchControls() throws {
        let pitched = try SFZFixtures.pitchedInstrument(in: root)
        let measured = try capabilities(of: pitched)

        XCTAssertTrue(measured.isPitched)
        XCTAssertTrue(measured.isSupported(.vibrato))
        XCTAssertTrue(measured.isSupported(.tuning))
    }

    // MARK: Envelope

    func testAOneShotOnlyPatchCannotOfferReleaseShaping() throws {
        let percussion = try SFZFixtures.oneShotInstrument(in: root)
        let measured = try capabilities(of: percussion)

        XCTAssertFalse(measured.respondsToNoteOff)
        let release = measured.availability(of: .release)
        XCTAssertFalse(release.isSupported)
        let releaseExplanation = try XCTUnwrap(release.explanation)
        XCTAssertTrue(
            releaseExplanation.contains("ignores when the note stops"), releaseExplanation
        )

        // Attack softening still works: it adds to the recording rather than
        // depending on the note ending.
        XCTAssertTrue(measured.isSupported(.attack))
    }

    func testAnInstrumentThatReleasesOffersReleaseShaping() throws {
        let sustaining = try SFZFixtures.pitchedInstrument(in: root)
        XCTAssertTrue(try capabilities(of: sustaining).isSupported(.release))
    }

    // MARK: Articulation

    func testOneArticulationMeansNothingToSwitchBetween() throws {
        let single = try SFZFixtures.pitchedInstrument(in: root)
        let measured = try capabilities(of: single)

        let articulation = measured.availability(of: .articulation)
        XCTAssertFalse(articulation.isSupported)
        let articulationExplanation = try XCTUnwrap(articulation.explanation)
        XCTAssertTrue(
            articulationExplanation.contains("installs one articulation"), articulationExplanation
        )
    }

    func testAlternateFilesMakeArticulationAvailable() throws {
        let deep = try SFZFixtures.deeplyLayeredInstrument(in: root)
        XCTAssertTrue(try capabilities(of: deep).isSupported(.articulation))
    }

    // MARK: Tone is the one thing every asset can do

    func testEveryInstrumentCanBeShelved() throws {
        for available in [
            try SFZFixtures.pitchedInstrument(in: root),
            try SFZFixtures.oneShotInstrument(in: root),
            try SFZFixtures.velocityLayeredInstrument(in: root)
        ] {
            let measured = try capabilities(of: available)
            XCTAssertTrue(measured.isSupported(.toneLow), available.coverage.name)
            XCTAssertTrue(measured.isSupported(.toneHigh), available.coverage.name)
        }
    }

    // MARK: The invariant, over every control of every fixture

    /// Not one control anywhere is allowed to be disabled without a sentence.
    ///
    /// A greyed-out slider with nothing beside it tells the owner the app is
    /// broken. This walks the whole product of controls and fixtures so a new
    /// control added without an explanation fails here rather than in front of
    /// somebody.
    func testEveryUnsupportedControlCarriesAnExplanationNamingTheInstrument() throws {
        let fixtures = [
            try SFZFixtures.pitchedInstrument(in: root),
            try SFZFixtures.oneShotInstrument(in: root),
            try SFZFixtures.velocityLayeredInstrument(in: root),
            try SFZFixtures.deeplyLayeredInstrument(in: root)
        ]

        for available in fixtures {
            let measured = try capabilities(of: available)
            for control in InstrumentControl.allCases {
                let availability = measured.availability(of: control)
                if availability.isSupported {
                    XCTAssertNil(availability.explanation, "\(control) is on; nothing to explain")
                    continue
                }
                let explanation = try XCTUnwrap(
                    availability.explanation,
                    "\(available.coverage.name) disables \(control) with no explanation"
                )
                XCTAssertTrue(
                    explanation.contains(available.coverage.name),
                    "\(control) on \(available.coverage.name): \(explanation)"
                )
                XCTAssertTrue(explanation.hasSuffix("."), "Explanations are sentences: \(explanation)")
                XCTAssertNotNil(availability.accessibilityExplanation)
            }
        }
    }

    // MARK: The gate has teeth

    /// Disabled means inert, not merely greyed out.
    ///
    /// A variant made while a library was installed and played after it was
    /// removed, or a document written by hand, must not reach the render core
    /// with a control the instrument cannot support — so every path from
    /// storage to the engine goes through `bounded`.
    func testBoundedPutsEveryUnsupportedControlBackToTheRecording() throws {
        let unpitched = try SFZFixtures.velocityLayeredInstrument(in: root)
        let measured = try capabilities(of: unpitched)

        let asked = InstrumentCustomization(
            toneLowDecibels: -4,
            toneHighDecibels: 3,
            dynamicsResponse: 1.6,
            attackSeconds: 0.1,
            releaseScale: 2,
            vibratoDepthCents: 40,
            vibratoRateHz: 6,
            tuningOffsetCents: 25,
            articulationFileName: "somewhere.sfz"
        )
        let bounded = measured.bounded(asked)

        // Supported: kept exactly.
        XCTAssertEqual(bounded.toneLowDecibels, -4)
        XCTAssertEqual(bounded.toneHighDecibels, 3)
        XCTAssertEqual(bounded.attackSeconds, 0.1)
        XCTAssertEqual(bounded.releaseScale, 2)
        XCTAssertEqual(bounded.dynamicsResponse, 1.6, "Three layers is enough for dynamics")

        // Unsupported: back to the recording, whatever was asked for.
        XCTAssertEqual(bounded.vibratoDepthCents, 0)
        XCTAssertEqual(bounded.tuningOffsetCents, 0)
        XCTAssertNil(bounded.articulationFileName)
    }

    /// A variant stored while an instrument was deeper than it is now cannot
    /// smuggle the old setting past the gate.
    ///
    /// The live case: a library re-pinned to different bytes, or a variant
    /// carried between machines. The stored document is untouched — nothing
    /// rewrites the owner's variant behind their back — but what reaches the
    /// render core is bounded to what the files on disk can actually do.
    func testAStoredSettingForAControlTheAssetLostIsBoundedAway() throws {
        let deep = try SFZFixtures.deeplyLayeredInstrument(in: root)
        let thin = try SFZFixtures.pitchedInstrument(in: root, sampleRate: 44_100)

        let saved = InstrumentCustomization(toneLowDecibels: 3, dynamicsResponse: 1.7)
        XCTAssertEqual(
            try capabilities(of: deep).bounded(saved).dynamicsResponse, 1.7,
            "While the instrument has its layers, the setting stands"
        )

        let afterRepinning = try capabilities(of: thin).bounded(saved)
        XCTAssertEqual(
            afterRepinning.dynamicsResponse, 1,
            "Once the files have one layer, the stored setting has no effect"
        )
        XCTAssertEqual(
            afterRepinning.toneLowDecibels, 3,
            "…and the controls the instrument still supports are untouched"
        )
    }

    /// An instrument that is not installed has nothing measured, so nothing is
    /// offered — and the explanation is the one that helps: download it.
    func testAnUninstalledInstrumentDisablesEverythingAndOffersTheDownload() throws {
        let coverage = InstrumentCoverage(
            identifier: "vsco2.cello.section",
            name: "Cello section",
            family: .strings,
            sfzPath: "Cello.sfz",
            dynamicLayerCount: 2,
            qualityNotes: ["A section patch standing in for a solo line."]
        )
        let measured = InstrumentCapabilities(uninstalled: coverage)

        XCTAssertFalse(measured.isMeasured)
        for control in InstrumentControl.allCases {
            let availability = measured.availability(of: control)
            XCTAssertFalse(availability.isSupported, "\(control)")
            let explanation = try XCTUnwrap(availability.explanation)
            XCTAssertTrue(explanation.contains("is not downloaded"), explanation)
            XCTAssertTrue(explanation.contains("instrument catalog"), explanation)
        }

        XCTAssertEqual(measured.bounded(InstrumentCustomization(
            toneLowDecibels: 6, vibratoDepthCents: 50
        )), .asRecorded, "Nothing measured means nothing applied")

        // The catalog's own quality notes survive: they are worth showing even
        // when there is nothing to measure.
        XCTAssertEqual(measured.qualityNotes, coverage.qualityNotes)
    }

    // MARK: What the shipped catalog actually says

    /// The acceptance criterion names two real instruments. This pins the
    /// catalog figures the gate reads for them, so a re-pinned library that
    /// changed either one fails here rather than silently changing which
    /// controls the owner is offered.
    func testTheCuratedCatalogsOwnLayerCountsAreWhatTheGateReads() throws {
        let byIdentifier = Dictionary(
            InstrumentCatalog.libraries.flatMap(\.coverage).map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let salamander = try XCTUnwrap(byIdentifier["salamander.grand"])
        XCTAssertEqual(salamander.dynamicLayerCount, 16, "Salamander is the deep one")

        // The thin ones the acceptance criterion is about. Each is a real
        // catalog entry whose single layer is why its dynamics control is off.
        for identifier in ["vsco2.harp", "vsco2.piccolo", "vsco2.organ", "vsco2.percussion.kit"] {
            let coverage = try XCTUnwrap(byIdentifier[identifier], identifier)
            XCTAssertEqual(coverage.dynamicLayerCount, 1, "\(identifier) is a one-layer patch")
        }
    }
}
