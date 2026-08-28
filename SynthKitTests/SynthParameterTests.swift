import XCTest
@testable import SynthKit

/// Issue #19: "Every SYN001 parameter is editable — oscillators, filters,
/// envelopes, LFOs, modulation matrix, effects", and "invalid parameter entry
/// clamps to valid ranges".
///
/// The first claim is the awkward one to test, because the way it fails is by
/// *omission*: a parameter nobody wrote a control for does not throw, it simply
/// is not there. So the coverage test below does not check that a list has the
/// length somebody expected. It walks `SynthPatch` itself with `Mirror`, finds
/// every leaf value in it, then walks the editor's parameter list and records
/// which of those leaves each parameter can actually change. Adding a field to
/// the patch without adding a control for it fails here.
final class SynthParameterTests: XCTestCase {

    // MARK: Coverage

    /// Every value in a patch can be changed through the editor's parameter
    /// list — except the two the library owns.
    func testEveryPatchParameterIsEditable() {
        let start = SynthPatch.defaultVoice
        let everyField = Self.leafFields(of: start)

        var reachable: Set<String> = []
        for parameter in SynthParameter.all {
            guard let current = start.value(for: parameter.id) else {
                return XCTFail("\(parameter.id) has no value on a default patch.")
            }
            let changed = start.setting(parameter.id, to: Self.alternative(to: current, for: parameter))
            let touched = Self.changedFields(from: everyField, to: Self.leafFields(of: changed))
            XCTAssertFalse(
                touched.isEmpty,
                "Setting \(parameter.group) — \(parameter.name) to a different value changed nothing."
            )
            reachable.formUnion(touched)
        }

        // `identifier` and `name` are the library row's, not the editor's:
        // `SoundLibrary.update` overwrites whatever the incoming patch claims
        // about itself, so a control for them would be a lie.
        let ownedByTheLibrary: Set<String> = ["identifier", "name"]
        let missing = Set(everyField.keys).subtracting(reachable).subtracting(ownedByTheLibrary)

        XCTAssertTrue(
            missing.isEmpty,
            "No editor control can change: \(missing.sorted().joined(separator: ", ")). "
                + "Every parameter of a patch has to be editable (REQ-016)."
        )
    }

    /// …and nothing in the list is a control for something that is not there.
    func testNoParameterIsUnreachableOnAPatch() {
        let patch = SynthPatch.defaultVoice
        for parameter in SynthParameter.all {
            XCTAssertNotNil(
                patch.value(for: parameter.id),
                "\(parameter.group) — \(parameter.name) has no value to show."
            )
        }
    }

    func testEveryParameterIsInExactlyOneGroupAndTheGroupsCoverThemAll() {
        let grouped = SynthParameter.groups.flatMap(\.parameters)
        XCTAssertEqual(grouped.count, SynthParameter.all.count)
        XCTAssertEqual(Set(grouped.map(\.id)), Set(SynthParameter.all.map(\.id)))

        // The panel order the editor lays out, stated once so a reordering is a
        // deliberate change rather than an accident of dictionary iteration.
        XCTAssertEqual(
            SynthParameter.groups.map(\.name),
            [
                "Oscillator 1", "Oscillator 2", "Oscillator 3", "Mixer", "Filter",
                "Amplitude Envelope", "Modulation Envelope", "LFO 1", "LFO 2",
                "Modulation Matrix", "Equaliser", "Chorus", "Delay", "Reverb", "Voice"
            ]
        )
    }

    func testEveryParameterIdentityIsUnique() {
        XCTAssertEqual(Set(SynthParameter.all.map(\.id)).count, SynthParameter.all.count)
    }

    /// Two controls on one panel must not read out as the same thing.
    func testEveryAccessibilityLabelIsUnique() {
        let labels = SynthParameter.all.map(\.accessibilityLabel)
        XCTAssertEqual(Set(labels).count, labels.count, "Duplicate VoiceOver labels: \(labels)")
    }

    // MARK: Round trip

    /// Set it, read it back, get the same thing. For every parameter, at both
    /// ends of its range and in the middle.
    func testEveryParameterRoundTrips() {
        for parameter in SynthParameter.all {
            for value in Self.probeValues(for: parameter) {
                let patch = SynthPatch.defaultVoice.setting(parameter.id, to: value)
                let readBack = patch.value(for: parameter.id)
                XCTAssertEqual(
                    readBack, value,
                    "\(parameter.group) — \(parameter.name) did not round-trip \(value)."
                )
            }
        }
    }

    /// …and survives a trip through the stored document, which is what actually
    /// happens between editing a sound and hearing it again tomorrow.
    func testEveryParameterSurvivesTheStoredDocument() throws {
        var patch = SynthPatch.defaultVoice
        for parameter in SynthParameter.all {
            guard let current = patch.value(for: parameter.id) else { continue }
            patch = patch.setting(parameter.id, to: Self.alternative(to: current, for: parameter))
        }

        let data = try SynthPatchDocument.data(from: patch)
        let restored = try SynthPatchDocument.patch(from: data)

        for parameter in SynthParameter.all {
            XCTAssertEqual(
                restored.value(for: parameter.id), patch.value(for: parameter.id),
                "\(parameter.group) — \(parameter.name) did not survive serialisation."
            )
        }
    }

    // MARK: Clamping

    /// "Invalid parameter entry clamps to valid ranges" — the issue's failure
    /// clause, for every continuous parameter there is.
    func testOutOfRangeEntryClampsForEveryContinuousParameter() {
        for parameter in SynthParameter.all {
            guard case .number(let range, _, _, _) = parameter.kind else { continue }

            let tooLow = SynthPatch.defaultVoice
                .setting(parameter.id, to: .number(range.lowerBound - 1_000_000))
            XCTAssertEqual(
                tooLow.value(for: parameter.id)?.numberValue, range.lowerBound,
                "\(parameter.group) — \(parameter.name) did not clamp up to its minimum."
            )

            let tooHigh = SynthPatch.defaultVoice
                .setting(parameter.id, to: .number(range.upperBound + 1_000_000))
            XCTAssertEqual(
                tooHigh.value(for: parameter.id)?.numberValue, range.upperBound,
                "\(parameter.group) — \(parameter.name) did not clamp down to its maximum."
            )
        }
    }

    /// A field that is empty, or holds something that is not a number at all,
    /// becomes the bottom of the range rather than putting a NaN into the audio.
    func testANonNumericEntryBecomesTheMinimumRatherThanANaN() {
        for parameter in SynthParameter.all {
            guard case .number(let range, _, _, _) = parameter.kind else { continue }
            for broken in [Double.nan, .infinity, -.infinity] {
                let patch = SynthPatch.defaultVoice.setting(parameter.id, to: .number(broken))
                let result = patch.value(for: parameter.id)?.numberValue
                XCTAssertNotNil(result)
                XCTAssertTrue(result?.isFinite == true, "\(parameter.name) let \(broken) through.")
                if broken.isNaN {
                    XCTAssertEqual(result, range.lowerBound)
                }
            }
        }
    }

    func testIntegerParametersClampToTheirRange() {
        for parameter in SynthParameter.all {
            guard case .integer(let range) = parameter.kind else { continue }
            let low = SynthPatch.defaultVoice.setting(parameter.id, to: .integer(-9_999_999))
            let high = SynthPatch.defaultVoice.setting(parameter.id, to: .integer(999_999_999))
            XCTAssertEqual(low.value(for: parameter.id)?.integerValue, range.lowerBound, "\(parameter.name)")
            XCTAssertGreaterThanOrEqual(range.upperBound, high.value(for: parameter.id)?.integerValue ?? .max)
        }
    }

    /// The filter has two slopes, not three. A stepper between them must land
    /// on one of them rather than on a value the engine will quietly fold.
    func testFilterSlopeOnlyEverLandsOnTwoOrFourPoles() {
        for requested in [-1, 0, 1, 2, 3, 4, 5, 99] {
            let patch = SynthPatch.defaultVoice.setting(.filterPoles, to: .integer(requested))
            let poles = patch.value(for: .filterPoles)?.integerValue
            XCTAssertTrue(poles == 2 || poles == 4, "\(requested) became \(String(describing: poles))")
        }
    }

    /// A value of the wrong shape is refused rather than coerced.
    func testAValueOfTheWrongKindLeavesThePatchAlone() {
        let start = SynthPatch.defaultVoice
        XCTAssertEqual(start.setting(.filterCutoff, to: .flag(true)), start)
        XCTAssertEqual(start.setting(.filterEnabled, to: .number(1)), start)
        XCTAssertEqual(start.setting(.filterType, to: .option("not-a-filter")), start)
        XCTAssertEqual(start.setting(.maximumVoices, to: .option("eight")), start)
    }

    /// An index outside the fixed architecture is a caller error, and the
    /// answer to it is "nothing happened", not a crash.
    func testAnIndexOutsideTheArchitectureIsIgnored() {
        let start = SynthPatch.defaultVoice
        XCTAssertNil(start.value(for: .oscillatorLevel(9)))
        XCTAssertNil(start.value(for: .lfoRate(9)))
        XCTAssertNil(start.value(for: .modulationAmount(99)))
        XCTAssertEqual(start.setting(.oscillatorLevel(9), to: .number(1)), start)
    }

    // MARK: Display

    func testNumbersReadTheWayAnInstrumentWritesThem() {
        let cutoff = try! XCTUnwrap(SynthParameter.parameter(.filterCutoff))
        XCTAssertEqual(cutoff.displayText(for: .number(440)), "440 Hz")
        XCTAssertEqual(cutoff.displayText(for: .number(12_000)), "12 kHz")
        XCTAssertEqual(cutoff.displayText(for: .number(1_250)), "1.25 kHz")

        let attack = try! XCTUnwrap(SynthParameter.parameter(.envelopeAttack(.amplitude)))
        XCTAssertEqual(attack.displayText(for: .number(0.008)), "8 ms")
        XCTAssertEqual(attack.displayText(for: .number(2.5)), "2.5 s")

        let level = try! XCTUnwrap(SynthParameter.parameter(.outputLevel))
        XCTAssertEqual(level.displayText(for: .number(0.14)), "14%")

        let gain = try! XCTUnwrap(SynthParameter.parameter(.equalizerLowGain))
        XCTAssertEqual(gain.displayText(for: .number(-3.5)), "-3.5 dB")
        XCTAssertEqual(gain.displayText(for: .number(0)), "0 dB")

        let coarse = try! XCTUnwrap(SynthParameter.parameter(.oscillatorDetuneSemitones(1)))
        XCTAssertEqual(coarse.displayText(for: .number(12)), "12 st")

        let type = try! XCTUnwrap(SynthParameter.parameter(.oscillatorType(0)))
        XCTAssertEqual(type.displayText(for: .option("frequencyModulation")), "FM")

        let retrigger = try! XCTUnwrap(SynthParameter.parameter(.oscillatorRetriggersPhase(0)))
        XCTAssertEqual(retrigger.displayText(for: .flag(true)), "On")
        XCTAssertEqual(retrigger.displayText(for: .flag(false)), "Off")
    }

    /// VoiceOver has to say a phrase, not spell an abbreviation.
    func testSpokenValuesAreWordsRatherThanAbbreviations() {
        let cutoff = try! XCTUnwrap(SynthParameter.parameter(.filterCutoff))
        XCTAssertEqual(cutoff.spokenValue(for: .number(440)), "440 hertz")
        XCTAssertEqual(cutoff.spokenValue(for: .number(12_000)), "12 kilohertz")

        let attack = try! XCTUnwrap(SynthParameter.parameter(.envelopeAttack(.amplitude)))
        XCTAssertEqual(attack.spokenValue(for: .number(0.008)), "8 milliseconds")

        let gain = try! XCTUnwrap(SynthParameter.parameter(.equalizerLowGain))
        XCTAssertEqual(gain.spokenValue(for: .number(-3.5)), "-3.5 decibels")

        let resonance = try! XCTUnwrap(SynthParameter.parameter(.filterResonance))
        XCTAssertEqual(resonance.spokenValue(for: .number(0.4)), "40 percent")
    }

    /// A label a person can read, on every control, in every panel.
    func testEveryParameterCarriesAHint() {
        for parameter in SynthParameter.all {
            XCTAssertFalse(parameter.name.isEmpty, "\(parameter.id) has no name.")
            XCTAssertFalse(parameter.group.isEmpty, "\(parameter.id) has no group.")
            XCTAssertGreaterThan(
                parameter.detail.count, 20,
                "\(parameter.group) — \(parameter.name) has no useful hint: “\(parameter.detail)”."
            )
        }
    }

    // MARK: Slider mapping

    func testTheSliderMappingIsItsOwnInverse() {
        for parameter in SynthParameter.all {
            guard case .number(let range, _, _, _) = parameter.kind else { continue }
            for position in stride(from: 0.0, through: 1.0, by: 0.125) {
                let value = parameter.denormalized(position)
                XCTAssertTrue(range.contains(value), "\(parameter.name) left its range at \(position).")
                XCTAssertEqual(
                    parameter.normalized(value), position, accuracy: 1e-9,
                    "\(parameter.name) does not map back at \(position)."
                )
            }
        }
    }

    /// The middle of a logarithmic control is the geometric mean of its ends,
    /// which is the whole reason it is logarithmic: a linear cutoff slider
    /// spends nine tenths of its travel above 2 kHz.
    func testALogarithmicControlSpendsHalfItsTravelBelowTheGeometricMean() {
        let cutoff = try! XCTUnwrap(SynthParameter.parameter(.filterCutoff))
        XCTAssertEqual(cutoff.denormalized(0.5), (20.0 * 20_000.0).squareRoot(), accuracy: 0.5)
        XCTAssertLessThan(cutoff.denormalized(0.5), 1_000)
    }

    // MARK: - Reflection helpers

    /// Every leaf value inside a patch, keyed by its path.
    ///
    /// `Mirror` rather than a hand-written list, so the answer comes from the
    /// type as it actually is. A field added to `SynthPatch` appears here the
    /// moment it exists, which is what makes the coverage test above a guard
    /// rather than a restatement.
    static func leafFields(of patch: SynthPatch) -> [String: String] {
        var fields: [String: String] = [:]
        walk(Mirror(reflecting: patch), path: "", into: &fields)
        return fields
    }

    private static func walk(_ mirror: Mirror, path: String, into fields: inout [String: String]) {
        for (offset, child) in mirror.children.enumerated() {
            let label = child.label ?? "\(offset)"
            let childPath = path.isEmpty ? label : "\(path).\(label)"
            let childMirror = Mirror(reflecting: child.value)

            // A struct or an array has children to descend into. An enum with
            // no payload, a number, a flag and a string do not, and are the
            // leaves this is looking for.
            if childMirror.children.isEmpty || childMirror.displayStyle == .enum {
                fields[childPath] = String(describing: child.value)
            } else {
                walk(childMirror, path: childPath, into: &fields)
            }
        }
    }

    private static func changedFields(
        from before: [String: String],
        to after: [String: String]
    ) -> Set<String> {
        var changed: Set<String> = []
        for (key, value) in before where after[key] != value { changed.insert(key) }
        return changed
    }

    // MARK: - Value helpers

    /// A value for this parameter that is not the one it already has.
    static func alternative(
        to current: SynthParameterValue,
        for parameter: SynthParameter
    ) -> SynthParameterValue {
        switch (parameter.kind, current) {
        case (.flag, .flag(let flag)):
            return .flag(!flag)

        case (.integer(let range), .integer(let number)):
            return .integer(number == range.upperBound ? range.lowerBound : range.upperBound)

        case (.number(let range, _, _, _), .number(let number)):
            // The end of the range it is furthest from, so the difference is
            // always the largest one the parameter allows.
            let low = abs(number - range.lowerBound)
            let high = abs(range.upperBound - number)
            return .number(low > high ? range.lowerBound : range.upperBound)

        case (.option(let values, _), .option(let raw)):
            return .option(values.first { $0 != raw } ?? raw)

        default:
            return current
        }
    }

    /// Values to probe a parameter's round trip with: both ends and the middle.
    static func probeValues(for parameter: SynthParameter) -> [SynthParameterValue] {
        switch parameter.kind {
        case .flag:
            return [.flag(true), .flag(false)]
        case .integer(let range):
            let middle = (range.lowerBound + range.upperBound) / 2
            // The filter's slope is the one integer parameter with a gap in it.
            if case .filterPoles = parameter.id { return [.integer(2), .integer(4)] }
            return [.integer(range.lowerBound), .integer(middle), .integer(range.upperBound)]
        case .number(let range, _, _, _):
            return [
                .number(range.lowerBound),
                .number(parameter.denormalized(0.5)),
                .number(range.upperBound)
            ]
        case .option(let values, _):
            return values.map { .option($0) }
        }
    }
}
