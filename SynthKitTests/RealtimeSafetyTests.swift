import XCTest
@testable import SynthKit

/// Issue #15: "Real-time safety: no allocation/locks/objc-runtime on the render
/// thread ... CI-guarded where statically checkable."
///
/// **What these guards do and do not prove.** The first two are source scans.
/// They prove that no forbidden *call* is written in the code that runs on the
/// audio thread; they do not prove the compiler emitted none, and no source
/// scan could. That is exactly why the render path is C: a C file with no
/// allocator call in it cannot acquire one behind your back, whereas Swift can
/// allocate for a boxed closure or an array copy that never appears as a name
/// in the source. The third test is dynamic and covers the gap from the other
/// side, by measuring whether rendering ten times as much audio costs ten times
/// as many allocations.
///
/// Stated plainly rather than overclaimed: together these make an allocation on
/// the audio thread very hard to introduce unnoticed. They are not a proof of
/// its absence.
final class RealtimeSafetyTests: XCTestCase {
    private static func repositoryRoot() throws -> URL {
        var candidate = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = candidate.appending(path: "Synth.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        throw RepositoryRootNotFound(searchedUpwardsFrom: #filePath)
    }

    struct RepositoryRootNotFound: Error, CustomStringConvertible {
        let searchedUpwardsFrom: String
        var description: String {
            "Could not find the directory containing Synth.xcodeproj above \(searchedUpwardsFrom); "
                + "the real-time-safety guard cannot run."
        }
    }

    private static func source(named name: String) throws -> String {
        let url = try repositoryRoot().appending(path: "SynthKit").appending(path: name)
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else {
            throw RepositoryRootNotFound(searchedUpwardsFrom: url.path(percentEncoded: false))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Calls that must never appear in the render core.
    ///
    /// Each is here because it can block the audio thread: an allocator can take
    /// the malloc lock, a mutex can be held by a lower-priority thread, an
    /// Objective-C message can hit the runtime's lock on first dispatch, and
    /// logging can do all three.
    private static let forbiddenInRenderCore = [
        "malloc", "calloc", "realloc", "free(", "valloc", "strdup", "posix_memalign",
        "pthread_mutex", "pthread_rwlock", "pthread_cond", "os_unfair_lock", "dispatch_",
        "objc_", "NSLog", "printf", "fprintf", "fopen", "sleep", "usleep",
        "Block_copy", "CFRetain", "CFRelease", "abort(", "exit("
    ]

    /// Every file the audio thread executes, and the setup file each is split
    /// against.
    ///
    /// The synthesizer (SYN001) follows the same split as the engine, so it is
    /// covered by the same guard: adding a render core without adding it here
    /// would leave the real-time claim resting on a file nobody checks.
    ///
    /// The sampler (INS002) is the third. It is the one whose real-time claim
    /// is least obvious from the source, because reading a memory-mapped file
    /// can block without any forbidden symbol appearing anywhere — which is why
    /// `SampledInstrument` faults the samples' attacks in on the control thread
    /// and `RealtimePlaybackTests` measures what the rest costs.
    private static let renderCores = [
        "SynthAudioCore.c", "SynthPatchEngine.c", "SampleVoiceEngine.c"
    ]

    /// The render cores are written so that this scan is meaningful.
    ///
    /// Construction lives in `SynthAudioSetup.c` and `SynthPatchSetup.c`, which
    /// are allowed to allocate, so the boundary this checks is a whole file
    /// rather than a judgement about which function runs where.
    func testRenderCoresContainNoRealtimeUnsafeCall() throws {
        for name in Self.renderCores {
            let core = try Self.source(named: name)

            XCTAssertGreaterThan(
                core.count, 2_000, "\(name) is suspiciously small; the guard may be blind."
            )

            // Strip comments before scanning: these files explain what they must
            // not do, and a guard that read its own documentation as a violation
            // would be unusable.
            let code = Self.strippingComments(from: core)

            for symbol in Self.forbiddenInRenderCore {
                XCTAssertFalse(
                    code.contains(symbol),
                    "\(name) calls \(symbol), which is not real-time safe. If this belongs to "
                        + "setup rather than rendering, it goes in the matching *Setup.c."
                )
            }
        }
    }

    /// Setup is where allocation is allowed, and it must actually be there —
    /// otherwise the split above is decorative and the guard proves nothing.
    func testSetupIsWhereAllocationLives() throws {
        let setup = Self.strippingComments(from: try Self.source(named: "SynthAudioSetup.c"))
        XCTAssertTrue(
            setup.contains("calloc") && setup.contains("free("),
            "SynthAudioSetup.c neither allocates nor frees, so the render core's allocation-free "
                + "claim is not being made by a real split of responsibilities."
        )
    }

    /// The synthesizer allocates nothing at all, on either thread.
    ///
    /// Its voice state is one caller-owned block sized by
    /// `synth_patch_voice_state_size`, and its wavetables are static. That is
    /// a stronger position than the engine's — there is no allocator call to
    /// keep on the right side of a line — so the guard for it is that neither
    /// of its files allocates.
    func testTheSynthesizerNeverAllocates() throws {
        for name in ["SynthPatchEngine.c", "SynthPatchSetup.c"] {
            let code = Self.strippingComments(from: try Self.source(named: name))
            for symbol in ["malloc", "calloc", "realloc", "free(", "posix_memalign"] {
                XCTAssertFalse(
                    code.contains(symbol),
                    "\(name) calls \(symbol). The synthesizer's storage is owned by its caller; "
                        + "nothing here should be allocating."
                )
            }
        }
    }

    /// The sampler allocates exactly once per voice, and it does it in setup.
    ///
    /// The other half of the split above. `SampleVoiceEngine.c` is scanned for
    /// allocation with every other render core; this states that the allocation
    /// it does not do is actually happening somewhere, so the scan is a real
    /// division of responsibilities rather than a file that never needed to
    /// allocate in the first place.
    func testTheSamplersAllocationLivesInItsSetupFile() throws {
        let setup = Self.strippingComments(from: try Self.source(named: "SampleVoiceSetup.c"))
        XCTAssertTrue(
            setup.contains("calloc") && setup.contains("free("),
            "SampleVoiceSetup.c neither allocates nor frees, so the sampler's render core's "
                + "allocation-free claim is not being made by a real split."
        )
    }

    /// Rendering a full synthesizer patch does not allocate per block either.
    ///
    /// The same dynamic check as `testRenderingDoesNotAllocatePerBlock`, run
    /// against the heaviest patch rather than the default voice: three
    /// oscillators, a four-pole filter, six live modulation routes and all four
    /// effects. A source scan cannot see an allocation the compiler emitted,
    /// and the synthesizer is where one would hurt most.
    func testRenderingASynthPatchDoesNotAllocatePerBlock() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())

        let engine = PlaybackEngine(
            voiceProvider: SynthPatchVoiceProvider(
                patch: SynthEngineIntegrationTests.demandingPatch()))
        try engine.setRenderMode(.offline(sampleRate: 48_000))
        try engine.load(timeline: timeline)
        engine.play()

        _ = try engine.renderOffline(frameCount: 48_000)

        func allocationsRendering(frames: Int64) throws -> Int {
            let before = Self.liveAllocationCount()
            _ = try engine.renderOffline(frameCount: frames)
            return Self.liveAllocationCount() - before
        }

        let short = try allocationsRendering(frames: 48_000)
        let long = try allocationsRendering(frames: 480_000)

        let blocksShort = 48_000 / Int(RenderProgram.maximumFrameCount)
        let blocksLong = 480_000 / Int(RenderProgram.maximumFrameCount)
        let perBlock = Double(long - short) / Double(blocksLong - blocksShort)

        XCTAssertLessThan(
            perBlock, 0.25,
            "Rendering a synth patch cost \(perBlock) allocations per render block "
                + "(\(short) for \(blocksShort) blocks, \(long) for \(blocksLong))."
        )
    }

    /// The Swift the audio thread executes is one closure per engine, and each
    /// does nothing but call into C.
    ///
    /// Swift's presence on the render thread is a single trampoline, because
    /// anything richer risks ARC traffic on a captured reference. This reads the
    /// closure back out of the source and checks nothing else crept in.
    ///
    /// **There are two of these now.** SYN003's editor auditions a sound that
    /// belongs to no piece, so it has an engine of its own with no program, no
    /// transport and no mixer. That is a second audio thread running a second
    /// Swift closure, and a guard that only knew about the first would have
    /// stopped meaning what it says the day the second appeared.
    func testEverySwiftRenderTrampolineDoesNothingButCallIntoC() throws {
        for (file, entryPoint) in [
            ("PlaybackEngine.swift", "synth_audio_core_render("),
            ("SoundAuditionEngine.swift", "synth_patch_voice_render_stereo(")
        ] {
            let source = try Self.source(named: file)

            let marker = "AVAudioSourceNode(format: format)"
            XCTAssertEqual(
                source.components(separatedBy: marker).count - 1, 1,
                "Expected exactly one AVAudioSourceNode render block in \(file)."
            )

            guard let start = source.range(of: marker) else {
                return XCTFail("Render block not found in \(file).")
            }
            let remainder = source[start.upperBound...]
            guard let end = remainder.range(of: "\n        }\n") else {
                return XCTFail("Could not find the end of the render block in \(file).")
            }
            let body = Self.strippingComments(from: String(remainder[..<end.lowerBound]))

            XCTAssertTrue(
                body.contains(entryPoint),
                "\(file)'s render block does not call \(entryPoint)."
            )

            // Anything that allocates, retains, dispatches, or throws.
            let forbidden = [
                "Array", "String", "Dictionary", "Set(", ".append", ".map", ".filter", ".reduce",
                "print(", "DispatchQueue", "NSLock", "await", "try", "self.", "guard let", "if let",
                "for ", "while ", "?? ", "as!", "as?"
            ]
            for symbol in forbidden {
                XCTAssertFalse(
                    body.contains(symbol),
                    "\(file)'s audio-thread trampoline contains `\(symbol)`. It must do nothing "
                        + "but call \(entryPoint). Body was:\n\(body)"
                )
            }
        }
    }

    /// Live editing must not put a lock on the audio thread.
    ///
    /// The whole point of publishing a patch through a triple buffer rather
    /// than behind a mutex is that the render thread never waits for the
    /// control thread. `SynthPatchLiveVoices` does hold an `NSLock` — for
    /// registration, release and publication, all control-thread work — and the
    /// guard that matters is that none of it is reachable from `render`. That
    /// is already covered by the file scan above, since the render cores
    /// contain no lock of any kind; this states the other half, that the
    /// crossing itself is written as atomics.
    func testTheLiveParameterCrossingIsAtomicRatherThanLocked() throws {
        let engine = Self.strippingComments(from: try Self.source(named: "SynthPatchEngine.c"))

        XCTAssertTrue(
            engine.contains("atomic_exchange_explicit") && engine.contains("atomic_load_explicit"),
            "The render core no longer takes published patches through atomics."
        )
        XCTAssertTrue(
            engine.contains("synth_patch_voice_adopt") && engine.contains("synth_patch_voice_drain_events"),
            "The render core no longer adopts published patches or queued notes."
        )
    }

    /// Rendering ten times as much audio must not cost ten times as many
    /// allocations.
    ///
    /// The dynamic half of the guard, and the one that would catch an allocation
    /// the source scan cannot see. Manual rendering runs the render callback on
    /// this thread, so what is measured is the render path rather than the
    /// process at large. The assertion is about *scaling* rather than an
    /// absolute count, because the surrounding harness allocates for its own
    /// reasons and a fixed budget would be a flake waiting to happen.
    func testRenderingDoesNotAllocatePerBlock() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())

        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: 48_000))
        try engine.load(timeline: timeline)
        engine.play()

        // Warm up: first-touch page faults and lazy AVAudioEngine setup are
        // one-off costs and would otherwise be charged to the short run.
        _ = try engine.renderOffline(frameCount: 48_000)

        func allocationsRendering(frames: Int64) throws -> Int {
            let before = Self.liveAllocationCount()
            _ = try engine.renderOffline(frameCount: frames)
            return Self.liveAllocationCount() - before
        }

        let short = try allocationsRendering(frames: 48_000)
        let long = try allocationsRendering(frames: 480_000)

        // `renderOffline` itself grows two Swift arrays per call, so a couple of
        // allocations either way is the harness, not the render path. What
        // matters is the *marginal* cost: how many more allocations the extra
        // blocks cost. Allocation-free rendering makes that ~0 however long the
        // render is; one allocation per block makes it ~1.
        let blocksShort = 48_000 / Int(RenderProgram.maximumFrameCount)
        let blocksLong = 480_000 / Int(RenderProgram.maximumFrameCount)
        let perBlock = Double(long - short) / Double(blocksLong - blocksShort)

        // Measured on this code: ~-0.01 per block when the core is clean, and
        // ~0.99 when a single `malloc` is injected into the render function.
        // 0.25 sits an order of magnitude away from both.
        XCTAssertLessThan(
            perBlock, 0.25,
            "Rendering cost \(perBlock) allocations per render block "
                + "(\(short) for \(blocksShort) blocks, \(long) for \(blocksLong)). "
                + "The render path is allocating."
        )
    }

    /// Live allocation count for the default malloc zone.
    private static func liveAllocationCount() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &statistics)
        return Int(statistics.blocks_in_use)
    }

    /// Remove `//` and `/* */` comments so a scan reads code, not prose.
    private static func strippingComments(from source: String) -> String {
        var output = ""
        var index = source.startIndex
        var inLineComment = false
        var inBlockComment = false

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let following: Character? = next < source.endIndex ? source[next] : nil

            if inLineComment {
                if character == "\n" { inLineComment = false; output.append(character) }
            } else if inBlockComment {
                if character == "*", following == "/" {
                    inBlockComment = false
                    index = source.index(after: next)
                    continue
                }
            } else if character == "/", following == "/" {
                inLineComment = true
                index = source.index(after: next)
                continue
            } else if character == "/", following == "*" {
                inBlockComment = true
                index = source.index(after: next)
                continue
            } else {
                output.append(character)
            }
            index = next
        }
        return output
    }
}
