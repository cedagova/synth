import XCTest
@testable import SynthKit

/// On-demand diagnostic for "why does nothing sound at this part of the piece?"
///
/// Not a regression test: it runs only when `SYNTH_DIAGNOSE_PIECE` names a
/// MusicXML file, and its product is the report it prints. It separates the
/// three places silence can come from:
///
/// 1. **The importer dropped notation** — the timeline's `NotationReport`.
/// 2. **The timeline has a gap** — no event from any line is sounding, so the
///    silence is in the data the engine was given (import or realization).
/// 3. **The audio is silent where the timeline is not** — events are sounding
///    but the render produced nothing, so the fault is in the engine.
///
/// Run it against a piece from the app's own library:
///
///     TEST_RUNNER_SYNTH_DIAGNOSE_PIECE="$HOME/Library/Application Support/Synth/pieces/<id>.musicxml" \
///     xcodebuild test -project Synth.xcodeproj -scheme Synth \
///       -destination 'platform=macOS,arch=arm64' \
///       -only-testing:SynthKitTests/PieceDiagnosticHarness
///
/// (`xcodebuild` forwards `TEST_RUNNER_`-prefixed variables to the test
/// process with the prefix stripped.)
final class PieceDiagnosticHarness: XCTestCase {
    /// A hole shorter than this is musical (a breath, a staccato field), not a
    /// dropout worth a line in the report.
    private static let reportableGapMicroseconds: Int64 = 500_000

    func testDiagnosePiece() throws {
        guard let path = ProcessInfo.processInfo.environment["SYNTH_DIAGNOSE_PIECE"] else {
            throw XCTSkip("Set SYNTH_DIAGNOSE_PIECE to a MusicXML file to run the diagnostic.")
        }

        let musicXML = try Data(contentsOf: URL(fileURLWithPath: path))
        let score = try ScoreCompiler().compile(pieceID: "diagnostic", musicXML: musicXML)
        let timeline = PerformanceRealizer().realize(score, settings: .standard)

        var report = "\n===== PIECE DIAGNOSTIC: \(path) =====\n"

        report += "\n--- Importer notation report ---\n"
        if timeline.report.isEmpty {
            report += "clean: nothing was dropped or approximated\n"
        } else {
            for entry in timeline.report.entries {
                report += "\(entry.category.rawValue): \(entry.displayText)\n"
            }
            if timeline.report.truncatedKindCount > 0 {
                report += "(+\(timeline.report.truncatedKindCount) further kinds truncated)\n"
            }
        }

        report += "\n--- Lines ---\n"
        for line in timeline.lines {
            let velocities = line.events.map(\.velocity)
            let measures = line.events.map(\.playbackMeasureIndex)
            report += "\(line.name) [\(line.id)]: \(line.events.count) events"
            if let lo = measures.min(), let hi = measures.max(),
               let vLo = velocities.min(), let vHi = velocities.max() {
                report += ", playback measures \(lo + 1)–\(hi + 1), velocity \(vLo)–\(vHi)"
            }
            report += "\n"
        }

        let gaps = Self.soundingGaps(in: timeline)
        report += "\n--- Timeline gaps (no line sounding ≥ \(Self.reportableGapMicroseconds / 1000) ms) ---\n"
        if gaps.isEmpty {
            report += "none: some line is sounding through the whole piece\n"
        } else {
            for gap in gaps {
                report += String(
                    format: "%.2fs – %.2fs (%.2fs), after measure %d, before measure %d\n",
                    Double(gap.start) / 1_000_000, Double(gap.end) / 1_000_000,
                    Double(gap.end - gap.start) / 1_000_000,
                    gap.measureBefore + 1, gap.measureAfter + 1
                )
            }
        }

        // Render the whole mix offline (the graph playback uses) and look for
        // audio silence the timeline does not predict.
        let audio = try PlaybackEngine.renderTimelineOffline(timeline)
        let silentSpans = Self.silentAudioSpans(in: audio)
        report += "\n--- Audio-silent spans (offline render, RMS < 1e-4 for ≥ \(Self.reportableGapMicroseconds / 1000) ms) ---\n"
        if silentSpans.isEmpty {
            report += "none: the render carries energy end to end\n"
        } else {
            for span in silentSpans {
                let explained = gaps.contains {
                    span.start >= $0.start - 250_000 && span.end <= $0.end + 250_000
                }
                report += String(
                    format: "%.2fs – %.2fs (%.2fs) — %@\n",
                    Double(span.start) / 1_000_000, Double(span.end) / 1_000_000,
                    Double(span.end - span.start) / 1_000_000,
                    explained
                        ? "matches a timeline gap: the silence is in the score data"
                        : "NOT in the timeline: events are sounding here but the engine rendered silence"
                )
            }
        }

        // Optional stage 2: the same questions with the sounds the owner's
        // preset actually assigns, one shipped sound ID per line in timeline
        // order via SYNTH_DIAGNOSE_SOUNDS.
        if let soundList = ProcessInfo.processInfo.environment["SYNTH_DIAGNOSE_SOUNDS"] {
            report += try Self.diagnoseWithAssignedSounds(
                timeline: timeline,
                soundIDs: soundList.split(separator: ",").map(String.init)
            )
        }

        report += "\n===== END DIAGNOSTIC =====\n"
        print(report)
    }

    /// Renders the mix with the actually-assigned shipped sounds, then solos
    /// each line and reports every span where the line has sounding events but
    /// the render stays silent.
    private static func diagnoseWithAssignedSounds(
        timeline: PerformanceTimeline, soundIDs: [String]
    ) throws -> String {
        var report = "\n--- Assigned-sound render ---\n"
        guard soundIDs.count == timeline.lines.count else {
            return report + "SYNTH_DIAGNOSE_SOUNDS names \(soundIDs.count) sounds for \(timeline.lines.count) lines; skipped\n"
        }

        var providers: [ScoreLineID: any LineVoiceProvider] = [:]
        for (line, soundID) in zip(timeline.lines, soundIDs) {
            guard let entry = ShippedSoundCollection.standard.sound(withID: soundID),
                  case .synth(let patch) = entry.content else {
                return report + "\(soundID) is not a shipped synth sound; skipped\n"
            }
            providers[line.id] = SynthPatchVoiceProvider(patch: patch)
        }
        let voices = LineVoiceAssignment(providersByLine: providers)

        let mix = try PlaybackEngine.renderTimelineOffline(timeline, voices: voices)
        let mixSilence = silentAudioSpans(in: mix)
        if mixSilence.isEmpty {
            report += "full mix with assigned sounds: energy end to end\n"
        } else {
            for span in mixSilence {
                report += String(
                    format: "full mix SILENT %.2fs – %.2fs (%.2fs)\n",
                    Double(span.start) / 1_000_000, Double(span.end) / 1_000_000,
                    Double(span.end - span.start) / 1_000_000
                )
            }
        }

        for (line, soundID) in zip(timeline.lines, soundIDs) {
            let solo = try PlaybackEngine.renderTimelineOffline(timeline, voices: voices) { engine in
                engine.mixer(for: line.id)?.isSoloed = true
            }
            let silent = silentAudioSpans(in: solo)
            let unexplained = silent.filter { span in
                line.events.contains {
                    $0.onsetMicroseconds < span.end - 250_000 && $0.endMicroseconds > span.start + 250_000
                }
            }
            if unexplained.isEmpty {
                report += "\(line.name) (\(soundID)): every span with events carries energy\n"
            } else {
                for span in unexplained {
                    let measures = line.events
                        .filter { $0.onsetMicroseconds < span.end && $0.endMicroseconds > span.start }
                        .map(\.playbackMeasureIndex)
                    report += String(
                        format: "%@ (%@) SILENT while events sound: %.2fs – %.2fs, playback measures %d–%d\n",
                        line.name, soundID,
                        Double(span.start) / 1_000_000, Double(span.end) / 1_000_000,
                        (measures.min() ?? -1) + 1, (measures.max() ?? -1) + 1
                    )
                }
            }
        }
        return report
    }

    // MARK: - Analysis

    private struct Gap {
        let start: Int64
        let end: Int64
        let measureBefore: Int
        let measureAfter: Int
    }

    /// Intervals of the piece during which no event from any line is sounding.
    private static func soundingGaps(in timeline: PerformanceTimeline) -> [Gap] {
        let events = timeline.lines.flatMap(\.events).sorted { $0.onsetMicroseconds < $1.onsetMicroseconds }
        guard !events.isEmpty else { return [] }

        var gaps: [Gap] = []
        var coveredUntil = events[0].onsetMicroseconds
        var lastMeasure = events[0].playbackMeasureIndex

        for event in events {
            if event.onsetMicroseconds - coveredUntil >= reportableGapMicroseconds {
                gaps.append(Gap(
                    start: coveredUntil,
                    end: event.onsetMicroseconds,
                    measureBefore: lastMeasure,
                    measureAfter: event.playbackMeasureIndex
                ))
            }
            if event.endMicroseconds > coveredUntil {
                coveredUntil = event.endMicroseconds
                lastMeasure = event.playbackMeasureIndex
            }
        }
        return gaps
    }

    private struct Span { let start: Int64; let end: Int64 }

    /// Stretches of the rendered mix whose short-window RMS stays below the
    /// audibility floor.
    private static func silentAudioSpans(in audio: PlaybackEngine.RenderedAudio) -> [Span] {
        let windowFrames = Int(audio.sampleRate / 4)  // 250 ms
        guard windowFrames > 0, audio.frameCount > 0 else { return [] }

        var spans: [Span] = []
        var silentSince: Int? = nil
        var start = 0
        while start < audio.frameCount {
            let end = min(start + windowFrames, audio.frameCount)
            var total = 0.0
            for index in start..<end {
                let mono = Double(audio.left[index]) + Double(audio.right[index])
                total += mono * mono
            }
            let rms = (total / Double(end - start)).squareRoot()
            if rms < 1e-4 {
                if silentSince == nil { silentSince = start }
            } else if let began = silentSince {
                appendSpan(from: began, to: start, into: &spans, sampleRate: audio.sampleRate)
                silentSince = nil
            }
            start = end
        }
        if let began = silentSince {
            appendSpan(from: began, to: audio.frameCount, into: &spans, sampleRate: audio.sampleRate)
        }
        return spans
    }

    private static func appendSpan(
        from beginFrame: Int, to endFrame: Int, into spans: inout [Span], sampleRate: Double
    ) {
        let start = Int64(Double(beginFrame) * 1_000_000 / sampleRate)
        let end = Int64(Double(endFrame) * 1_000_000 / sampleRate)
        guard end - start >= reportableGapMicroseconds else { return }
        spans.append(Span(start: start, end: end))
    }
}
