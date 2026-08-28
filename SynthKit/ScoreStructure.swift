import Foundation

/// The structural notation attached to one source measure: everything that
/// decides *what is played next* rather than what is sounded.
///
/// Collected as the union across all parts, because engravers put repeat
/// barlines and jump directions on whichever staff looked right on the page,
/// and the structure they describe belongs to the whole score.
struct MeasureStructure: Equatable, Sendable {
    /// `<repeat direction="forward"/>` on the left barline.
    var startsRepeat = false

    /// `<repeat direction="backward"/>` on the right barline.
    var endsRepeat = false

    /// `<repeat times="n"/>`: how many times the section is played in total.
    /// MusicXML's default, and notation's, is 2.
    var repeatTimes = 2

    /// Pass numbers this measure's ending (volta) is played on. Empty when
    /// the measure does not start an ending.
    var endingNumbers: [Int] = []

    /// `<ending type="stop"|"discontinue"/>`: this measure closes an ending.
    var endsEnding = false

    /// A segno sign is here.
    var hasSegno = false

    /// A coda sign is here.
    var hasCoda = false

    /// `D.C.` — go back to the beginning.
    var daCapo = false

    /// `D.S.` — go back to the segno.
    var dalSegno = false

    /// `To Coda` — on the pass after a jump, leave for the coda here.
    var toCoda = false

    /// `Fine` — on the pass after a jump, stop here.
    var fine = false

    var hasAnyJump: Bool { daCapo || dalSegno }
}

/// One measure of the expanded playback order.
struct ExpandedMeasure: Equatable, Sendable {
    let sourceMeasureIndex: Int
    let pass: Int
}

/// Turns notated structure into the linear order the piece is played in
/// (REQ-010).
///
/// The traversal is the one a player performs: walk forward; take a volta only
/// on its own pass; at a backward repeat go back to the matching forward
/// repeat until the section has been played its stated number of times; on a
/// `D.C.`/`D.S.` jump once and then respect `To Coda` and `Fine`.
///
/// Two invariants make it safe on files that contradict themselves:
///
/// - every decision consumes a play count, so no cycle can spin forever; and
/// - the whole walk is bounded by `measureBudget`, and hitting that bound
///   truncates the piece and files a report entry instead of hanging.
///
/// Contradictory notation therefore always yields *something playable*, which
/// is what the issue's failure clause requires.
struct ScoreStructureExpander {
    let structures: [MeasureStructure]

    /// Printed numbers, for report locations.
    let measureNumbers: [String]

    /// Hard ceiling on expanded length. Generous enough that no real score
    /// reaches it (a 400-measure score with heavy repeats lands near 900) and
    /// small enough that a pathological file fails fast.
    var measureBudget: Int {
        max(4_000, structures.count * 32)
    }

    /// Expands, appending any fallback it had to apply to `report`.
    func expand(report: inout NotationReportCollector) -> [ExpandedMeasure] {
        let count = structures.count
        guard count > 0 else { return [] }

        var order: [ExpandedMeasure] = []
        var playCount = [Int](repeating: 0, count: count)
        var repeatStack: [Int] = []
        var index = 0
        var hasJumped = false
        var repeatsHonored = true

        /// Forward repeats that some backward repeat has answered. A section
        /// whose backward repeat lives inside a first ending is closed even
        /// though the later pass skips over it, so the stack alone cannot tell
        /// a real orphan from an ordinary volta.
        var answeredStarts: Set<Int> = []

        let segnoIndex = structures.firstIndex { $0.hasSegno }
        let codaIndex = structures.firstIndex { $0.hasCoda }

        while index < count {
            guard order.count < measureBudget else {
                report.record(
                    .structuralFallback,
                    kind: "runaway repeat structure",
                    at: location(index),
                    detail: "expansion stopped after \(measureBudget) measures; "
                        + "the repeat and jump marks in this score do not resolve"
                )
                break
            }

            // A volta is entered only on its own pass. On any other pass, skip
            // to the ending that does claim this pass, or past the block.
            if !structures[index].endingNumbers.isEmpty {
                let pass = currentPass(repeatStack: repeatStack, playCount: playCount)
                if !structures[index].endingNumbers.contains(pass) {
                    let next = skipEndings(from: index, pass: pass)
                    if next <= index {
                        report.record(
                            .structuralFallback,
                            kind: "unresolvable ending",
                            at: location(index),
                            detail: "no ending covers pass \(pass); it is played as written"
                        )
                    } else {
                        index = next
                        continue
                    }
                }
            }

            playCount[index] += 1
            order.append(ExpandedMeasure(sourceMeasureIndex: index, pass: playCount[index]))

            let structure = structures[index]

            if structure.startsRepeat, repeatStack.last != index {
                repeatStack.append(index)
            }

            // `To Coda` and `Fine` are inert until a jump has been taken; that
            // is what makes "D.C. al Fine" stop at the Fine on the second pass
            // and play straight through it on the first.
            if hasJumped, structure.fine {
                break
            }
            if hasJumped, structure.toCoda {
                if let codaIndex {
                    index = codaIndex
                    continue
                }
                report.record(
                    .structuralFallback,
                    kind: "to coda without a coda sign",
                    at: location(index),
                    detail: "the jump to the coda is ignored and playback continues in order"
                )
            }

            if repeatsHonored, structure.endsRepeat {
                let target = repeatStack.last
                if let target { answeredStarts.insert(target) }
                if target == nil {
                    report.record(
                        .structuralFallback,
                        kind: "unmatched backward repeat",
                        at: location(index),
                        detail: "no forward repeat opens this section, so it repeats from the "
                            + "start of the piece, as notation convention prescribes"
                    )
                }
                if playCount[index] < max(2, structure.repeatTimes) {
                    index = target ?? 0
                    continue
                }
                if !repeatStack.isEmpty {
                    repeatStack.removeLast()
                }
            }

            if !hasJumped, structure.daCapo {
                hasJumped = true
                repeatsHonored = false
                repeatStack.removeAll()
                index = 0
                continue
            }
            if !hasJumped, structure.dalSegno {
                if let segnoIndex {
                    hasJumped = true
                    repeatsHonored = false
                    repeatStack.removeAll()
                    index = segnoIndex
                    continue
                }
                report.record(
                    .structuralFallback,
                    kind: "dal segno without a segno sign",
                    at: location(index),
                    detail: "the jump is ignored and playback continues in order"
                )
            }

            index += 1
        }

        reportUnclosedRepeats(
            repeatStack.filter { !answeredStarts.contains($0) },
            report: &report
        )
        return order
    }

    /// Which time through the enclosing repeated section we are on.
    ///
    /// The forward-repeat measure is entered exactly once per pass, so its own
    /// play count *is* the pass number. Outside any repeat, everything is
    /// pass 1.
    private func currentPass(repeatStack: [Int], playCount: [Int]) -> Int {
        guard let start = repeatStack.last else { return 1 }
        return max(1, playCount[start])
    }

    /// From an ending that does not claim `pass`, the next measure to play.
    ///
    /// Walks whole ending blocks: an ending runs from the measure that starts
    /// it to the one that stops it. Returns the start of the ending that does
    /// claim `pass`, or the first measure after the last ending in the chain.
    private func skipEndings(from start: Int, pass: Int) -> Int {
        var index = start
        while index < structures.count, !structures[index].endingNumbers.isEmpty {
            if structures[index].endingNumbers.contains(pass) { return index }

            var scan = index
            while scan < structures.count, !structures[scan].endsEnding {
                scan += 1
            }
            index = scan < structures.count ? scan + 1 : structures.count
        }
        return index
    }

    private func reportUnclosedRepeats(
        _ orphans: [Int],
        report: inout NotationReportCollector
    ) {
        for index in orphans {
            report.record(
                .structuralFallback,
                kind: "unclosed forward repeat",
                at: location(index),
                detail: "no backward repeat closes this section, so it is played once"
            )
        }
    }

    private func location(_ index: Int) -> ScoreLocation {
        ScoreLocation(
            sourceMeasureIndex: index,
            measureNumber: measureNumbers.indices.contains(index) ? measureNumbers[index] : nil
        )
    }
}
