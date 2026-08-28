import AVFoundation
import CoreAudio
import XCTest
@testable import SynthKit

/// Issue #15, REQ-015: output-device enumeration, in-app selection, following
/// the system default, and graceful connect/disconnect.
///
/// **What can and cannot be tested here.** Enumeration and selection are real:
/// they query the actual HAL and move a running graph onto a real device. A
/// Bluetooth headset walking out of range cannot be staged from a test process
/// — that needs hardware leaving the room — so the disconnect path is covered
/// two ways instead: `SeekAndTransportTests` drives the production recovery
/// call directly, and the PR records a manual drill against a real device
/// appearing and disappearing.
///
/// Every test that needs hardware skips with a reason when there is none, so a
/// headless CI runner reports "skipped", not a false pass.
final class AudioOutputDeviceTests: XCTestCase {
    private func requireOutputDevices() throws -> [AudioOutputDevice] {
        let devices = AudioOutputDeviceCatalog.outputDevices()
        try XCTSkipIf(
            devices.isEmpty,
            "No audio output device on this machine (expected on a headless CI runner)."
        )
        return devices
    }

    // MARK: Enumeration

    /// A refused HAL query must surface as an error, not as "no devices".
    ///
    /// The distinction matters: an empty list is a legitimate state on a
    /// headless machine, so a catalog that swallowed failures would make a
    /// broken HAL indistinguishable from a Mac with nothing plugged in.
    func testEnumerationEitherReturnsDevicesOrThrows() {
        do {
            let devices = try AudioOutputDeviceCatalog.enumerate()
            for device in devices {
                XCTAssertFalse(device.uid.isEmpty, "A device has no UID to persist a preference against.")
                XCTAssertFalse(device.name.isEmpty, "A device has no name to show.")
                XCTAssertGreaterThan(
                    device.outputChannelCount, 0,
                    "\(device.name) has no output channels but was listed as an output."
                )
            }
        } catch {
            // A genuine failure is an acceptable outcome; a silent empty list
            // would not be.
            XCTAssertTrue(error is AudioOutputDeviceCatalog.CatalogError)
        }
    }

    /// Exactly one device is the system default, and it is in the list.
    func testTheDefaultDeviceIsOneOfTheListedDevices() throws {
        let devices = try requireOutputDevices()
        let defaults = devices.filter(\.isDefault)
        XCTAssertLessThanOrEqual(defaults.count, 1, "More than one device claims to be the default.")

        if let current = AudioOutputDeviceCatalog.defaultOutputDevice() {
            XCTAssertTrue(
                devices.contains { $0.uid == current.uid },
                "The default output device is not in the enumerated list."
            )
        }
    }

    /// UIDs are unique, because a preference stored against one has to resolve
    /// back to exactly one device.
    func testDeviceUIDsAreUnique() throws {
        let devices = try requireOutputDevices()
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count, "Two output devices share a UID.")
    }

    // MARK: Selection

    /// A fresh engine follows the system default rather than pinning anything.
    func testANewEngineFollowsTheSystemDefault() {
        let engine = PlaybackEngine()
        XCTAssertNil(engine.preferredDeviceUID, "A new engine should follow the system default.")
    }

    /// Selecting an unknown UID fails rather than silently doing nothing
    /// visible, so a stale preference is detectable.
    func testSelectingAnUnknownDeviceReportsFailure() throws {
        _ = try requireOutputDevices()
        let engine = PlaybackEngine()
        let selected = try engine.selectOutputDevice(uid: "not-a-real-device-uid")
        XCTAssertFalse(selected, "Selecting a nonexistent device reported success.")
    }

    /// Selecting a real device moves the graph onto it.
    func testSelectingARealDeviceMovesTheGraph() throws {
        let devices = try requireOutputDevices()
        let target = try XCTUnwrap(devices.first)

        let engine = PlaybackEngine()
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        try engine.load(timeline: timeline)

        let selected = try engine.selectOutputDevice(uid: target.uid)
        XCTAssertTrue(selected, "Could not select \(target.name).")
        XCTAssertEqual(engine.preferredDeviceUID, target.uid)
        XCTAssertEqual(engine.currentOutputDevice?.uid, target.uid)
    }

    /// Switching output **while the transport is playing** keeps playing and
    /// keeps the position.
    ///
    /// This is the acceptance criterion's first half. It needs two real output
    /// devices; with one it skips, saying so.
    func testSwitchingDeviceMidPlaybackContinuesFromTheSamePosition() throws {
        let devices = try requireOutputDevices()
        try XCTSkipIf(
            devices.count < 2,
            "Only \(devices.count) output device on this machine; a switch needs two."
        )

        let engine = PlaybackEngine()
        let timeline = try AudioRenderFixtures.timeline(MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 20))
        try engine.load(timeline: timeline)

        try engine.selectOutputDevice(uid: devices[0].uid)
        try engine.start()
        engine.play()

        // Let real time pass so the playhead is genuinely moving.
        Thread.sleep(forTimeInterval: 0.6)
        let positionBefore = engine.playbackPositionMicroseconds
        XCTAssertGreaterThan(positionBefore, 100_000, "Playback did not start on the first device.")
        XCTAssertEqual(engine.transportState, .playing)

        let switched = try engine.selectOutputDevice(uid: devices[1].uid)
        XCTAssertTrue(switched, "Could not switch to \(devices[1].name).")

        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(
            engine.transportState, .playing,
            "Playback stopped when the output device changed."
        )
        XCTAssertGreaterThan(
            engine.playbackPositionMicroseconds, positionBefore,
            "The playhead did not advance after the device switch."
        )
        XCTAssertEqual(engine.currentOutputDevice?.uid, devices[1].uid)

        if case .switched(_, _, let resumed)? = engine.lastDeviceEvent {
            XCTAssertTrue(resumed, "The switch did not resume playback.")
        } else {
            XCTFail("No switch event was reported; got \(String(describing: engine.lastDeviceEvent)).")
        }

        // No corrupted audio: a device change must not leave the engine wedged
        // in an overload state.
        XCTAssertEqual(engine.pauseReason, .none)
        engine.stop()
        engine.stopEngine()
    }

    /// Returning to "follow the default" un-pins the device.
    func testReturningToTheSystemDefaultUnpins() throws {
        let devices = try requireOutputDevices()
        let engine = PlaybackEngine()
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        try engine.load(timeline: timeline)

        try engine.selectOutputDevice(uid: devices[0].uid)
        XCTAssertNotNil(engine.preferredDeviceUID)

        try engine.selectOutputDevice(uid: nil)
        XCTAssertNil(engine.preferredDeviceUID, "Selecting nil did not return to following the default.")
    }
}
