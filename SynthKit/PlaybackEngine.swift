import AVFoundation
import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// Plays a `PerformanceTimeline`.
///
/// **One graph, two modes (AD2).** `rebuildGraph` is the only place a graph is
/// ever constructed, and real-time playback and offline manual rendering both
/// go through it with nothing but a different format. That is what makes
/// increment 006's export-equals-live claim (REQ-026) structural rather than a
/// promise: there is no second render path to drift.
///
/// Everything audible happens in `SynthAudioCore.c`. This type is the control
/// thread: it owns the AVAudioEngine, the program, the output device, and the
/// rules about when it is safe to hand the render thread something new.
///
/// **Not internally synchronised.** One owner calls it — normally the main
/// thread, which is also where the HAL notifications are delivered. It is
/// `Sendable` so that an offline export (increment 006) can own one on a
/// background thread instead, not so that two threads can share one.
public final class PlaybackEngine: @unchecked Sendable {
    /// Stereo float, deinterleaved — the format the C core writes.
    static func renderFormat(sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }

    public enum RenderMode: Equatable {
        /// Play to an output device in real time.
        case realtime
        /// Render as fast as the CPU allows, touching no hardware. Used by the
        /// deterministic tests here and by increment 006's export.
        case offline(sampleRate: Double)
    }

    public enum EngineError: Error, CustomStringConvertible {
        case noProgramLoaded
        case notInOfflineMode
        case notInRealtimeMode
        case manualRenderingFailed(status: Int)
        case couldNotStart(reason: String)

        public var description: String {
            switch self {
            case .noProgramLoaded:
                return "No timeline has been loaded."
            case .notInOfflineMode:
                return "Offline rendering requires the engine to be in offline render mode."
            case .notInRealtimeMode:
                return "Real-time playback requires the engine to be in real-time render mode."
            case .manualRenderingFailed(let status):
                return "Manual rendering returned status \(status)."
            case .couldNotStart(let reason):
                return "The audio engine could not start: \(reason)"
            }
        }
    }

    // MARK: Stored state

    private let avEngine = AVAudioEngine()
    private let voiceProvider: LineVoiceProvider

    private var sourceNode: AVAudioSourceNode?
    private var program: RenderProgram?
    private var timeline: PerformanceTimeline?
    private var mode: RenderMode = .realtime

    /// Set while the engine is deliberately reconfiguring itself, so the
    /// configuration-change notification does not chase its own tail.
    private var isReconfiguring = false

    private var deviceObserver: AudioOutputDeviceObserver?
    private var configurationObserver: NSObjectProtocol?

    /// What the caller asked for; nil means "follow the system default".
    public private(set) var preferredDeviceUID: String?

    /// Reported after a device change so a UI can explain itself.
    public private(set) var lastDeviceEvent: DeviceEvent?

    public enum DeviceEvent: Equatable, Sendable {
        /// The engine moved to this device and kept playing.
        case switched(deviceUID: String?, deviceName: String, resumedPlaying: Bool)
        /// The chosen device disappeared and nothing usable was left, so
        /// playback paused with its position intact.
        case lostWithNoFallback(previousDeviceName: String)
    }

    public init(voiceProvider: LineVoiceProvider = SynthPatchVoiceProvider()) {
        self.voiceProvider = voiceProvider
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        deviceObserver?.stop()
        avEngine.stop()
    }

    // MARK: Loading

    /// Hand the engine a performance to play.
    ///
    /// Stops the graph first. Publishing a program is the one control-thread
    /// write that is not a single word, and stopping the AVAudioEngine is the
    /// synchronisation edge that makes the new program's contents visible to
    /// the render thread — which is why there is no lock anywhere in this file.
    public func load(timeline: PerformanceTimeline) throws {
        let wasRunning = avEngine.isRunning
        avEngine.stop()

        self.timeline = timeline
        try rebuildProgramAndGraph()

        if wasRunning, case .realtime = mode {
            try startAVEngine()
        }
    }

    /// Sample rate the graph currently renders at.
    public var sampleRate: Double {
        switch mode {
        case .offline(let rate):
            return rate
        case .realtime:
            let deviceRate = avEngine.outputNode.outputFormat(forBus: 0).sampleRate
            return deviceRate > 0 ? deviceRate : 48_000
        }
    }

    public func setRenderMode(_ newMode: RenderMode) throws {
        guard newMode != mode else { return }
        avEngine.stop()

        if case .offline = mode, case .realtime = newMode {
            avEngine.disableManualRenderingMode()
        }
        mode = newMode
        try rebuildProgramAndGraph()
    }

    /// Rebuild the program at the current rate and reconnect the graph.
    ///
    /// A program stores event positions in frames, so it belongs to exactly one
    /// sample rate. Every reason the rate can change — a device switch, the
    /// user picking another output, entering offline rendering — therefore ends
    /// up here, on one path, with the playhead carried across in microseconds
    /// so it survives the rate change.
    private func rebuildProgramAndGraph() throws {
        let carriedMicroseconds = playbackPositionMicroseconds
        let wasPlaying = transportState == .playing

        let rate: Double
        switch mode {
        case .offline(let offlineRate):
            rate = offlineRate
            let format = Self.renderFormat(sampleRate: offlineRate)
            try avEngine.enableManualRenderingMode(
                .offline,
                format: format,
                maximumFrameCount: AVAudioFrameCount(RenderProgram.maximumFrameCount)
            )
        case .realtime:
            rate = sampleRate
        }

        if let timeline {
            program = try RenderProgram(
                timeline: timeline,
                sampleRate: rate,
                voiceProvider: voiceProvider
            )
        } else {
            program = nil
        }

        rebuildGraph(sampleRate: rate)

        if let program, carriedMicroseconds > 0 {
            let frame = RenderProgram.frame(forMicroseconds: carriedMicroseconds, sampleRate: rate)
            synth_engine_seek(program.engine, frame)
            if wasPlaying { synth_engine_play(program.engine) }
        }
    }

    /// **The one place a graph is built.** Live and offline differ only in the
    /// format handed in.
    private func rebuildGraph(sampleRate: Double) {
        if let existing = sourceNode {
            avEngine.detach(existing)
            sourceNode = nil
        }
        guard let program else { return }

        let format = Self.renderFormat(sampleRate: sampleRate)
        let enginePointer = program.engine
        let isRealtime: Bool
        if case .realtime = mode { isRealtime = true } else { isRealtime = false }
        synth_engine_set_realtime_mode(enginePointer, isRealtime ? 1 : 0)

        // The entire Swift presence on the audio thread. It captures one
        // trivial pointer, so there is no ARC traffic, and it does nothing but
        // call into C. `RealtimeSafetyTests` reads this closure back out of the
        // source and fails if anything else appears inside it.
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
            var silence: Int32 = 0
            let status = synth_audio_core_render(
                enginePointer,
                audioBufferList,
                Int32(frameCount),
                &silence
            )
            isSilence.pointee = ObjCBool(silence != 0)
            return status
        }

        avEngine.attach(node)
        avEngine.connect(node, to: avEngine.mainMixerNode, format: format)
        sourceNode = node
    }

    // MARK: Real-time playback

    /// Start the audio hardware. Idempotent.
    public func start() throws {
        guard case .realtime = mode else { throw EngineError.notInRealtimeMode }
        guard program != nil else { throw EngineError.noProgramLoaded }
        try startAVEngine()
        beginObservingDevices()
    }

    private func startAVEngine() throws {
        guard !avEngine.isRunning else { return }
        avEngine.prepare()
        do {
            try avEngine.start()
        } catch {
            throw EngineError.couldNotStart(reason: (error as NSError).localizedDescription)
        }
    }

    public func stopEngine() {
        avEngine.stop()
    }

    public var isRunning: Bool { avEngine.isRunning }

    // MARK: Transport

    public enum TransportState: Int, Sendable {
        case stopped = 0
        case playing = 1
        case paused = 2
    }

    /// Why playback last stopped on its own.
    public enum PauseReason: Int, Sendable {
        case none = 0
        case reachedEnd = 1
        /// Sustained render overload; the engine faded out rather than glitch.
        case overload = 2
        case deviceLost = 3
    }

    public func play() {
        guard let program else { return }
        synth_engine_play(program.engine)
    }

    public func pause() {
        guard let program else { return }
        synth_engine_pause(program.engine)
    }

    public func stop() {
        guard let program else { return }
        synth_engine_stop(program.engine)
    }

    /// Move the playhead. Takes effect after a few milliseconds of fade, so the
    /// jump is inaudible; `isSeekSettled` reports when it has landed.
    public func seek(toMicroseconds microseconds: Int64) {
        guard let program else { return }
        let frame = RenderProgram.frame(forMicroseconds: max(0, microseconds), sampleRate: program.sampleRate)
        synth_engine_seek(program.engine, frame)
    }

    public func seek(toFrame frame: Int64) {
        guard let program else { return }
        synth_engine_seek(program.engine, max(0, frame))
    }

    public var isSeekSettled: Bool {
        guard let program else { return true }
        return synth_engine_seek_settled(program.engine) != 0
    }

    public var transportState: TransportState {
        guard let program else { return .stopped }
        return TransportState(rawValue: Int(synth_engine_transport_state(program.engine))) ?? .stopped
    }

    public var pauseReason: PauseReason {
        guard let program else { return .none }
        return PauseReason(rawValue: Int(synth_engine_pause_reason(program.engine))) ?? .none
    }

    public var playbackPositionFrame: Int64 {
        guard let program else { return 0 }
        return synth_engine_playhead_frame(program.engine)
    }

    public var playbackPositionMicroseconds: Int64 {
        guard let program else { return 0 }
        return RenderProgram.microseconds(forFrame: playbackPositionFrame, sampleRate: program.sampleRate)
    }

    public var loadedProgram: RenderProgram? { program }

    // MARK: Per-line mixer (REQ-008 basis)

    /// Per-line gain, pan, mute and solo, addressed by the compiled score's own
    /// `ScoreLineID`. Every setter is a single atomic store, so it is safe to
    /// call while audio is playing; the change lands on the next buffer.
    public struct LineMixer {
        let engine: OpaquePointer
        let index: Int32

        /// Linear, 0…8. 1 is unity.
        public var gain: Float {
            get { synth_engine_line_gain(engine, index) }
            nonmutating set { synth_engine_set_line_gain(engine, index, newValue) }
        }

        /// -1 hard left … +1 hard right, equal-power.
        public var pan: Float {
            get { synth_engine_line_pan(engine, index) }
            nonmutating set { synth_engine_set_line_pan(engine, index, newValue) }
        }

        public var isMuted: Bool {
            get { synth_engine_line_muted(engine, index) != 0 }
            nonmutating set { synth_engine_set_line_muted(engine, index, newValue ? 1 : 0) }
        }

        /// While any line is soloed, every line that is not soloed is silent.
        public var isSoloed: Bool {
            get { synth_engine_line_soloed(engine, index) != 0 }
            nonmutating set { synth_engine_set_line_soloed(engine, index, newValue ? 1 : 0) }
        }

        public var decibels: Float {
            get { gain > 0 ? 20 * log10(gain) : -.infinity }
            nonmutating set { gain = newValue.isFinite ? pow(10, newValue / 20) : 0 }
        }
    }

    public func mixer(forLineAt index: Int) -> LineMixer? {
        guard let program, index >= 0, index < program.lineCount else { return nil }
        return LineMixer(engine: program.engine, index: Int32(index))
    }

    public func mixer(for id: ScoreLineID) -> LineMixer? {
        guard let program, let index = program.index(of: id) else { return nil }
        return LineMixer(engine: program.engine, index: Int32(index))
    }

    public var masterGain: Float {
        get { program.map { synth_engine_master_gain($0.engine) } ?? 1 }
        set { program.map { synth_engine_set_master_gain($0.engine, newValue) } }
    }

    // MARK: Telemetry

    /// What the render thread actually did, for a dropout claim that is
    /// measured rather than asserted.
    public struct RenderStatistics: Equatable, Sendable {
        public let renderedBlocks: Int64
        /// Blocks that took more than 85% of their real-time deadline.
        public let overloadBlocks: Int64
        /// Times sustained overload forced a clean pause.
        public let overloadPauses: Int64
        /// Largest absolute sample produced since the last reset.
        public let peakLevel: Float

        public var overloadRatio: Double {
            renderedBlocks > 0 ? Double(overloadBlocks) / Double(renderedBlocks) : 0
        }
    }

    public var statistics: RenderStatistics {
        guard let program else {
            return RenderStatistics(renderedBlocks: 0, overloadBlocks: 0, overloadPauses: 0, peakLevel: 0)
        }
        return RenderStatistics(
            renderedBlocks: synth_engine_rendered_blocks(program.engine),
            overloadBlocks: synth_engine_overload_blocks(program.engine),
            overloadPauses: synth_engine_overload_pauses(program.engine),
            peakLevel: synth_engine_peak_level(program.engine)
        )
    }

    public func resetStatistics() {
        guard let program else { return }
        synth_engine_reset_telemetry(program.engine)
    }

    // MARK: Offline rendering

    /// Deinterleaved stereo, as rendered.
    public struct RenderedAudio: Sendable {
        public let sampleRate: Double
        public let left: [Float]
        public let right: [Float]

        public var frameCount: Int { left.count }

        /// Root-mean-square of both channels together.
        public func rms() -> Double { Self.rms(left) / 2 + Self.rms(right) / 2 }
        public func rmsLeft() -> Double { Self.rms(left) }
        public func rmsRight() -> Double { Self.rms(right) }

        static func rms(_ samples: [Float]) -> Double {
            guard !samples.isEmpty else { return 0 }
            var total = 0.0
            for sample in samples { total += Double(sample) * Double(sample) }
            return (total / Double(samples.count)).squareRoot()
        }

        public func peak() -> Float {
            var peak: Float = 0
            for sample in left where abs(sample) > peak { peak = abs(sample) }
            for sample in right where abs(sample) > peak { peak = abs(sample) }
            return peak
        }

        /// Byte form of both channels, for a determinism claim that is a digest
        /// comparison rather than a tolerance.
        public func canonicalData() -> Data {
            var data = Data(capacity: (left.count + right.count) * 4)
            for sample in left { withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            for sample in right { withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            return data
        }
    }

    /// Render `frameCount` frames through the same graph live playback uses.
    ///
    /// Requires `setRenderMode(.offline(sampleRate:))`. Playback starts from
    /// wherever the transport currently is, so a seek followed by an offline
    /// render is exactly what a live listener would hear from that point.
    public func renderOffline(frameCount: Int64) throws -> RenderedAudio {
        guard case .offline(let rate) = mode else { throw EngineError.notInOfflineMode }
        guard program != nil else { throw EngineError.noProgramLoaded }

        if !avEngine.isRunning {
            avEngine.prepare()
            do {
                try avEngine.start()
            } catch {
                throw EngineError.couldNotStart(reason: (error as NSError).localizedDescription)
            }
        }

        let blockFrames = AVAudioFrameCount(RenderProgram.maximumFrameCount)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: avEngine.manualRenderingFormat,
            frameCapacity: blockFrames
        ) else {
            throw EngineError.manualRenderingFailed(status: -1)
        }

        var left = [Float]()
        var right = [Float]()
        left.reserveCapacity(Int(frameCount))
        right.reserveCapacity(Int(frameCount))

        var remaining = frameCount
        while remaining > 0 {
            let thisBlock = AVAudioFrameCount(min(Int64(blockFrames), remaining))
            let status = try avEngine.renderOffline(thisBlock, to: buffer)
            guard status == .success else {
                throw EngineError.manualRenderingFailed(status: status.rawValue)
            }
            let produced = Int(buffer.frameLength)
            guard produced > 0, let channels = buffer.floatChannelData else { break }
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: produced))
            if buffer.format.channelCount > 1 {
                right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: produced))
            } else {
                right.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: produced))
            }
            remaining -= Int64(produced)
        }

        return RenderedAudio(sampleRate: rate, left: left, right: right)
    }

    // MARK: Output devices (REQ-015)

    /// Every device the system can play through, live-queried.
    public var availableOutputDevices: [AudioOutputDevice] {
        AudioOutputDeviceCatalog.outputDevices()
    }

    /// The device the graph is currently rendering to.
    public var currentOutputDevice: AudioOutputDevice? {
        let id = avEngine.outputNode.auAudioUnit.deviceID
        return availableOutputDevices.first { $0.deviceID == id }
    }

    /// Choose an output. Passing `nil` returns to following the system default,
    /// which is also the initial behaviour.
    ///
    /// Playing across the switch is the point: the playhead and the transport
    /// state are carried over, so the listener hears the music continue on the
    /// new device rather than a restart.
    @discardableResult
    public func selectOutputDevice(uid: String?) throws -> Bool {
        preferredDeviceUID = uid

        guard let uid else {
            return try moveToDevice(AudioOutputDeviceCatalog.defaultOutputDevice())
        }
        guard let device = availableOutputDevices.first(where: { $0.uid == uid }) else {
            return false
        }
        return try moveToDevice(device)
    }

    /// Point the graph at `device`, rebuilding only what the change requires.
    private func moveToDevice(_ device: AudioOutputDevice?) throws -> Bool {
        guard case .realtime = mode else { throw EngineError.notInRealtimeMode }
        guard let device else { return false }

        let wasPlaying = transportState == .playing
        let wasRunning = avEngine.isRunning
        let previousRate = sampleRate

        isReconfiguring = true
        defer { isReconfiguring = false }

        avEngine.stop()
        do {
            try avEngine.outputNode.auAudioUnit.setDeviceID(device.deviceID)
        } catch {
            return false
        }

        // A device with a different clock changes the graph's sample rate, and
        // event positions are frames, so the program has to be rebuilt. Same
        // path offline rendering takes — which is why every offline test also
        // exercises this code.
        if abs(sampleRate - previousRate) > 0.5 {
            try rebuildProgramAndGraph()
        }

        if wasRunning { try startAVEngine() }
        if wasPlaying { play() }

        lastDeviceEvent = .switched(
            deviceUID: device.uid,
            deviceName: device.name,
            resumedPlaying: wasPlaying
        )
        return true
    }

    private func beginObservingDevices() {
        guard deviceObserver == nil else { return }

        let observer = AudioOutputDeviceObserver(
            onDefaultDeviceChanged: { [weak self] in self?.handleDefaultDeviceChanged() },
            onDeviceListChanged: { [weak self] in self?.handleDeviceListChanged() }
        )
        observer.start()
        deviceObserver = observer

        // AVAudioEngine tears its own graph down when the hardware changes
        // underneath it. Rebuilding here is what turns "the engine silently
        // stopped" into "playback continued".
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: avEngine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// The system default moved. Follow it only if the caller did not pin a
    /// device.
    private func handleDefaultDeviceChanged() {
        guard !isReconfiguring, preferredDeviceUID == nil else { return }
        _ = try? moveToDevice(AudioOutputDeviceCatalog.defaultOutputDevice())
    }

    /// A device appeared or disappeared. The disappearance of the pinned device
    /// is the case that matters: unplugging an interface, or a Bluetooth
    /// headset walking out of range.
    private func handleDeviceListChanged() {
        guard !isReconfiguring else { return }

        let devices = availableOutputDevices
        if let preferredDeviceUID {
            if devices.contains(where: { $0.uid == preferredDeviceUID }) { return }

            // The pinned device is gone. Fall back to the system default if one
            // is left; otherwise pause with the playhead intact, which is the
            // failure behaviour issue #15 asks for.
            if let fallback = AudioOutputDeviceCatalog.defaultOutputDevice() {
                self.preferredDeviceUID = nil
                _ = try? moveToDevice(fallback)
            } else {
                pauseForDeviceLoss(previousDeviceName: preferredDeviceUID)
            }
            return
        }

        if AudioOutputDeviceCatalog.defaultOutputDevice() == nil {
            pauseForDeviceLoss(previousDeviceName: "system default")
        }
    }

    private func handleConfigurationChange() {
        guard !isReconfiguring, case .realtime = mode else { return }

        isReconfiguring = true
        defer { isReconfiguring = false }

        let wasPlaying = transportState == .playing

        guard AudioOutputDeviceCatalog.defaultOutputDevice() != nil else {
            pauseForDeviceLoss(previousDeviceName: "previous output")
            return
        }

        // The graph's format may have moved with the hardware; rebuilding is
        // unconditional because comparing formats is more fragile than
        // rebuilding something this cheap.
        try? rebuildProgramAndGraph()
        try? startAVEngine()
        if wasPlaying { play() }

        let device = currentOutputDevice
        lastDeviceEvent = .switched(
            deviceUID: device?.uid,
            deviceName: device?.name ?? "unknown output",
            resumedPlaying: wasPlaying
        )
    }

    /// Pause because there is nowhere to play, keeping the position so that
    /// resuming on a new device continues where this left off.
    private func pauseForDeviceLoss(previousDeviceName: String) {
        if let program { synth_engine_pause_for_device_loss(program.engine) }
        avEngine.stop()
        lastDeviceEvent = .lostWithNoFallback(previousDeviceName: previousDeviceName)
    }

    /// Drive the device-loss path directly.
    ///
    /// Exposed because the notification that normally triggers it cannot be
    /// raised from a test: a real Bluetooth disconnection needs real hardware
    /// leaving the room. This is the same call the HAL listener makes, so a
    /// test of this exercises the production recovery path rather than a
    /// parallel one.
    public func simulateOutputDeviceLoss(deviceName: String = "test device") {
        pauseForDeviceLoss(previousDeviceName: deviceName)
    }

    /// Convenience: build an engine, render a whole timeline offline, tear it
    /// down. The graph is constructed by exactly the same code real-time
    /// playback uses.
    public static func renderTimelineOffline(
        _ timeline: PerformanceTimeline,
        sampleRate: Double = 48_000,
        voiceProvider: LineVoiceProvider = SynthPatchVoiceProvider(),
        configure: (PlaybackEngine) -> Void = { _ in }
    ) throws -> RenderedAudio {
        let engine = PlaybackEngine(voiceProvider: voiceProvider)
        try engine.setRenderMode(.offline(sampleRate: sampleRate))
        try engine.load(timeline: timeline)
        configure(engine)
        engine.play()
        let frames = engine.program?.totalFrames ?? 0
        return try engine.renderOffline(frameCount: frames)
    }
}
