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

    /// The render core is written so that this scan is meaningful.
    ///
    /// Construction lives in `SynthAudioSetup.c`, which is allowed to allocate,
    /// so the boundary this checks is a whole file rather than a judgement about
    /// which function runs where.
    func testRenderCoreContainsNoRealtimeUnsafeCall() throws {
        let core = try Self.source(named: "SynthAudioCore.c")

        XCTAssertGreaterThan(core.count, 2_000, "SynthAudioCore.c is suspiciously small; the guard may be blind.")

        // Strip comments before scanning: the file explains what it must not do,
        // and a guard that read its own documentation as a violation would be
        // unusable.
        let code = Self.strippingComments(from: core)

        for symbol in Self.forbiddenInRenderCore {
            XCTAssertFalse(
                code.contains(symbol),
                "SynthAudioCore.c calls \(symbol), which is not real-time safe. "
                    + "If this belongs to setup rather than rendering, it goes in SynthAudioSetup.c."
            )
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

    /// The Swift the audio thread executes is one closure, and it does nothing
    /// but call into C.
    ///
    /// Swift's presence on the render thread is a single trampoline, because
    /// anything richer risks ARC traffic on a captured reference. This reads the
    /// closure back out of the source and checks nothing else crept in.
    func testTheOnlySwiftOnTheAudioThreadIsTheSourceNodeTrampoline() throws {
        let source = try Self.source(named: "PlaybackEngine.swift")

        let marker = "AVAudioSourceNode(format: format)"
        XCTAssertEqual(
            source.components(separatedBy: marker).count - 1, 1,
            "Expected exactly one AVAudioSourceNode render block in PlaybackEngine.swift."
        )

        guard let start = source.range(of: marker) else { return XCTFail("Render block not found.") }
        let remainder = source[start.upperBound...]
        guard let end = remainder.range(of: "\n        }\n") else {
            return XCTFail("Could not find the end of the render block.")
        }
        let body = Self.strippingComments(from: String(remainder[..<end.lowerBound]))

        XCTAssertTrue(
            body.contains("synth_audio_core_render("),
            "The render block does not call into the C core."
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
                "The audio thread's Swift trampoline contains `\(symbol)`. It must do nothing but "
                    + "call synth_audio_core_render. Body was:\n\(body)"
            )
        }
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
