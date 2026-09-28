import Foundation
import MediaPlayer
import Observation

/// The system's media controls, driving the open piece (#87).
///
/// The play/pause key, headphone controls and Control Center's Now Playing all
/// arrive through `MPRemoteCommandCenter`, and Control Center reads what is
/// playing from `MPNowPlayingInfoCenter`. This is the app's only use of either.
///
/// **Nothing here is a transport.** Every command calls the `PlaybackModel`
/// action the transport's own button calls — the same guards, the same status
/// line, the same clamp on a seek past the end — so a remote press behaves
/// exactly like a click, including during an export (which renders on its own
/// offline engine and is never touched by the transport) and during Sound
/// Studio play-through (P84-5).
///
/// **Published on events, not ticks.** Control Center extrapolates the elapsed
/// time from the published rate, so the info only has to be rewritten when that
/// extrapolation would go wrong: the piece opens, becomes ready or closes, the
/// transport starts or stops, the playhead jumps (seek, skip, stop, loop wrap),
/// or the tempo changes the clock. The rate is `1.0` while playing and `0`
/// otherwise, because the tempo is already baked into the timeline the elapsed
/// time and duration are read from (P84-1).
@MainActor
final class NowPlayingControl {
    private let centers: any NowPlayingCenters
    private let currentPlayback: @MainActor () -> PlaybackModel?
    private var isInstalled = false

    /// What the last publish was made from. A notification that changes none
    /// of it — the ticker rewrites the transport state every frame — publishes
    /// nothing.
    private var lastPublished: Trigger?

    /// The skip commands' interval, in seconds: the transport's own ±5 s.
    static let skipIntervalSeconds = Double(PlaybackModel.skipMicroseconds) / 1_000_000

    init(
        centers: any NowPlayingCenters,
        currentPlayback: @escaping @MainActor () -> PlaybackModel?
    ) {
        self.centers = centers
        self.currentPlayback = currentPlayback
    }

    /// Register the commands and start publishing. App-lifetime; idempotent.
    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        centers.registerCommands { [weak self] command in
            self?.handle(command) ?? .noActionableNowPlayingItem
        }
        observe()
    }

    // MARK: Commands

    /// Run one remote command against the open piece.
    ///
    /// No piece, or a piece still preparing, is `.noActionableNowPlayingItem` —
    /// the system's word for "there is nothing here to control".
    func handle(_ command: RemoteTransportCommand) -> MPRemoteCommandHandlerStatus {
        guard let playback = currentPlayback(), playback.isReady else {
            return .noActionableNowPlayingItem
        }
        switch command {
        case .play:
            playback.play()
        case .pause:
            playback.pause()
        case .togglePlayPause:
            playback.togglePlayPause()
        case .stop:
            playback.stop()
        case .skipForward:
            playback.skip(byMicroseconds: PlaybackModel.skipMicroseconds)
        case .skipBackward:
            playback.skip(byMicroseconds: -PlaybackModel.skipMicroseconds)
        case .changePlaybackPosition(let seconds):
            guard seconds.isFinite else { return .commandFailed }
            playback.seek(toMicroseconds: Int64((seconds * 1_000_000).rounded()))
        }
        // Answer the scrubber with where it landed now, rather than a tick later.
        refresh()
        return .success
    }

    // MARK: Now Playing

    /// What Control Center should show for `playback`, or nil for no piece.
    static func info(for playback: PlaybackModel?) -> NowPlayingInfo? {
        guard let playback else { return nil }
        return NowPlayingInfo(
            title: playback.piece.title,
            composer: playback.piece.composer,
            durationSeconds: Double(playback.totalMicroseconds) / 1_000_000,
            elapsedSeconds: Double(playback.positionMicroseconds) / 1_000_000,
            isPlaying: playback.isPlaying
        )
    }

    /// Publish if anything Control Center cannot extrapolate has changed.
    func refresh() {
        let playback = currentPlayback()
        let trigger = Trigger(playback)
        guard trigger != lastPublished else { return }
        lastPublished = trigger
        centers.publish(Self.info(for: playback))
    }

    /// Re-arms after every change, because Observation reports one change per
    /// registration. Only the trigger's properties are read inside the
    /// tracking closure, so the playhead advancing never wakes this.
    private func observe() {
        withObservationTracking {
            _ = Trigger(currentPlayback())
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
        refresh()
    }

    /// The events a publish follows. Deliberately excludes the position itself.
    private struct Trigger: Equatable {
        let playback: ObjectIdentifier?
        let pieceID: String?
        let isReady: Bool
        let isPlaying: Bool
        let totalMicroseconds: Int64
        let tempoPercent: Int
        let playheadJumpCount: Int

        @MainActor init(_ playback: PlaybackModel?) {
            self.playback = playback.map(ObjectIdentifier.init)
            pieceID = playback?.piece.id
            isReady = playback?.isReady ?? false
            isPlaying = playback?.isPlaying ?? false
            totalMicroseconds = playback?.totalMicroseconds ?? 0
            tempoPercent = playback?.tempoPercent ?? 0
            playheadJumpCount = playback?.playheadJumpCount ?? 0
        }
    }
}

/// A remote command, as the transport understands it.
enum RemoteTransportCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case stop
    case skipForward
    case skipBackward
    case changePlaybackPosition(seconds: Double)
}

/// What Control Center shows for the open piece.
struct NowPlayingInfo: Equatable, Sendable {
    let title: String
    let composer: String?
    let durationSeconds: Double
    let elapsedSeconds: Double
    let isPlaying: Bool

    /// P84-1: the timeline already runs at the chosen tempo.
    var rate: Double { isPlaying ? 1.0 : 0 }
}

/// The seam over the two MediaPlayer singletons, so `SynthAppTests` can drive
/// the commands and read what was published without touching the real ones.
@MainActor
protocol NowPlayingCenters: AnyObject {
    /// Route every supported command to `handler`. Called once.
    func registerCommands(
        _ handler: @escaping @MainActor (RemoteTransportCommand) -> MPRemoteCommandHandlerStatus
    )

    /// Replace what Now Playing shows; nil clears it.
    func publish(_ info: NowPlayingInfo?)
}

/// The real centers.
@MainActor
final class SystemNowPlayingCenters: NowPlayingCenters {
    private var isRegistered = false

    func registerCommands(
        _ handler: @escaping @MainActor (RemoteTransportCommand) -> MPRemoteCommandHandlerStatus
    ) {
        guard !isRegistered else { return }
        isRegistered = true
        let center = MPRemoteCommandCenter.shared()

        func route(
            _ command: MPRemoteCommand,
            _ translate: @escaping (MPRemoteCommandEvent) -> RemoteTransportCommand?
        ) {
            command.isEnabled = true
            command.addTarget { event in
                guard let transportCommand = translate(event) else { return .commandFailed }
                return Self.onMain { handler(transportCommand) }
            }
        }

        route(center.playCommand) { _ in .play }
        route(center.pauseCommand) { _ in .pause }
        route(center.togglePlayPauseCommand) { _ in .togglePlayPause }
        route(center.stopCommand) { _ in .stop }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: NowPlayingControl.skipIntervalSeconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: NowPlayingControl.skipIntervalSeconds)]
        route(center.skipForwardCommand) { _ in .skipForward }
        route(center.skipBackwardCommand) { _ in .skipBackward }
        route(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map {
                .changePlaybackPosition(seconds: $0.positionTime)
            }
        }
    }

    func publish(_ info: NowPlayingInfo?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var values: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyPlaybackDuration: info.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: info.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let composer = info.composer {
            values[MPMediaItemPropertyArtist] = composer
            values[MPMediaItemPropertyComposer] = composer
        }
        center.nowPlayingInfo = values
        // macOS picks the app the media keys go to by this, not by the info.
        // An open piece that is not playing is paused, never stopped, so the
        // play key can start it (the issue's "publish on open").
        center.playbackState = info.isPlaying ? .playing : .paused
    }

    /// MediaPlayer calls handlers on the main thread; this keeps that an
    /// assumption checked at runtime rather than a crash if it ever is not.
    nonisolated private static func onMain(
        _ body: @escaping @MainActor () -> MPRemoteCommandHandlerStatus
    ) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
