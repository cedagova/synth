# Implementation Plan: Listening and export features: stems, loop-range export, preset compare, rehearsal marks, composer filter

- Planning issue: https://github.com/cedagova/synth/issues/85
- Planning PR: https://github.com/cedagova/synth/pull/101
- Status: In progress
- Root classification: EFFORT
- Delivery topology: DIRECT
- Planner: Claude (implementation-planning-lead)
- Started: 2026-09-28

## Pinned baselines

| Repository | Baseline |
| --- | --- |
| `cedagova/synth` | `cd7f1d55af204315ff40238cc844b102670d9af4` |

## Preserved objective and boundaries

Root #85 is an umbrella of listening and export features that extend what
the app already does, filed from the 2026-09-28 app-wide review. Its five
native sub-issues are the approved WHAT; this plan adds only system-level
HOW and settles the "decide during scoping" points each child left open.

| Child | Approved outcome (from the issue) | Approved acceptance |
| --- | --- | --- |
| #90 Export per-line stems | "Export Stems…" writes one file per line through the same offline graph as the mix, named by piece and line, into a chosen folder atomically; progress and Cancel cover the batch. | Summing the stems (master bypassed) reproduces the mix within a stated tolerance; Cancel leaves no partial files. |
| #91 Export only the loop range | An export option "Loop range only", enabled when a loop is set, renders exactly the looped measures with the last notes' tail allowed to ring out; the filename notes the range. | The exported range is byte-identical to the same span of a full export's rendering (up to the ring-out tail). |
| #92 Hold-to-compare against a reference preset | Pick a reference preset, then hold or toggle to hear it; release returns to the active preset; playback position kept; comparing never changes the active or saved preset; switching glitch-free enough mid-playback (reuse adoption path; measure). | While playing, toggling between two presets keeps the playhead and doesn't change the active preset on disk. |
| #93 Go to rehearsal mark | Compile `<rehearsal>` into the score model with its measure; "Go to Rehearsal Mark…" in the Playback menu next to Go to Measure, marks in score order; usable as loop start/end; mapped through repeat expansion. | A fixture with rehearsal marks lists them in order and choosing one seeks to that measure; scores without marks disable the menu item. |
| #94 Filter the library by composer | A composer filter built from the stored composer field, with counts; pieces with no composer grouped as "Unknown composer". Blocked on #30 (surname vs full-name convention). | Choosing a composer shows only their pieces; clearing restores the full list; the filter combines with text search. |

Boundaries preserved from the product definition
(`docs/product-definitions/cedagova-synth-1/definition.md` non-goals and
D1–D11): no score display of any kind (D2) — rehearsal marks appear only as
menu and field entries, never as drawn notation or a timeline; no score
editing (MusicXML stays read-only); not a DAW or sampler workstation (D6);
export stays WAV/AIFF of the current piece and its active preset (D5) and
keeps matching live playback; no compressed formats.

## Classification

- **ROOT #85 — `EFFORT`.** It already owns a native tree of five children;
  each child is an independent owner-visible feature with its own
  acceptance. No child is itself a multi-delivery effort, so `INCREMENTAL`
  is not warranted.
- **#90, #91, #92, #93 — `LEAF`.** Each is one coherent outcome in
  `cedagova/synth`, one PR, independently acceptable and releasable. Their
  model, engine, UI, and test work jointly produce one result each and are
  not split by layer.
- **#94 — `LEAF`, pending one owner decision** (see Owner decision brief).
  Its delivery shape is one PR either way; only its ordering rule, and
  whether it also closes #30, depends on the answer.
- No research node: every open technical question has a pinned-evidence
  answer or is an ordinary reversible choice recorded below.

## Current-state evidence

All paths at the pinned baseline.

- **Export is the playback engine offline.** `SynthKit/AudioExport.swift`
  runs `PlaybackEngine` in `.offline` mode; live and offline share
  `PlaybackEngine.rebuildGraph` (`SynthKit/PlaybackEngine.swift:307-365`).
  `AudioExportRequest` already carries a per-line mixer keyed by
  `ScoreLineID` and applies `isMuted`/`isSoloed` per strip
  (`AudioExport.swift:224-309`). Cancel is polled every 16,384-frame block
  and before publish; `AudioExportStaging` stages one file in the system
  item-replacement directory and publishes with replace/move
  (`AudioExport.swift:572-715`). It publishes a single file only.
- **Master stage is nonlinear and calibrated per program.**
  `ProducedMasterSettings` switches cohesion and loudness calibration; the
  true-peak ceiling is always on (`SynthKit/MasterStage.swift:3-31`, `:492`).
  Calibration is measured per rendered program and dropped on every rebuild
  (`PlaybackEngine.swift:353`, `:596-608`); calibration excerpts cover the
  whole piece (`MasterStage.swift:284`).
- **Lines** are part + staff + voice with `partName`/default `name`
  (`SynthKit/ScoreModel.swift:208-248`); user renames apply through
  `SynthKit/LineInventory.swift`. Solo/mute rule: mute wins; while any line
  is soloed only soloed lines play (`SynthKit/AssignmentDisplay.swift:179-198`).
- **Loops** are `LoopRange` in microseconds plus printed measure numbers,
  resolved to performed-measure indices so a loop across a repeat stays on
  the heard pass (`SynthKit/PlaybackNavigator.swift:9-62`, `:209-227`); only
  the app enforces them by seeking (`Synth/PlaybackModel.swift:790-817`).
  Export always renders frame 0 to `program.totalFrames`
  (`AudioExport.swift:123-150`); the only ring-out is the capped release
  tail at the piece end (`SynthKit/RenderProgram.swift:67-73`, `:215-223`).
  Filenames come from `AudioExportNaming.suggestedFileName`, "Title —
  Preset.ext" (`SynthKit/AudioExportSettings.swift:156-172`).
- **Presets** are per-piece SQLite documents (sounds, mixer, humanization,
  expression, master, tuning, tempo) with one active per piece enforced by a
  partial unique index (`SynthKit/SchemaMigrator.swift:163-178`);
  `PresetLibrary.activate` writes the flag (`SynthKit/PresetLibrary.swift:397-409`).
  Next Preset is ⌃⌘V (`Synth/MixCommands.swift:148-152`); it activates and
  then `reloadPresetAndApply` (`Synth/AssignmentModel.swift:946-958`,
  `:1024-1047`). A mid-playback switch stops the engine, rebuilds, and
  restarts with the playhead kept and no crossfade
  (`PlaybackEngine.swift:163-185`); timeline-affecting settings can cause a
  second asynchronous rebuild (`Synth/PlaybackModel.swift:236-258`,
  `:1037-1080`). A short fade exists only for seeks (`PlaybackEngine.swift:457`).
  `SynthKitTests/PresetMixerLiveTests.swift:252` covers switching without
  stopping; nothing measures a click at a preset switch.
- **Rehearsal marks are dropped** as visual-only
  (`SynthKit/ScoreCompiler.swift:1163`). `CompiledScore`
  (`ScoreModel.swift:356-390`) holds no direction text; it is compiled from
  the stored MusicXML bytes, not persisted. Performed measures carry
  `sourceMeasureIndex` and `pass` (`ScoreModel.swift:278-345`). Go to
  Measure (⌘G) seeks to the first performed measure with the printed
  number (`Synth/PlaybackModel.swift:627-652`,
  `PlaybackNavigator.swift:136-150`). The loop UI is A–B capture plus
  from/to fields (`Synth/PlaybackScreen.swift:588-645`). Fixtures are inline
  Swift MusicXML.
- **Composer** is `pieces.composer TEXT` / `PieceRecord.composer`, imported
  from `creator[@type=composer]` (`SynthKit/MusicXMLImporter.swift:110`).
  Search is in-memory, case- and diacritic-insensitive
  (`SynthKit/LibraryQuery.swift:68-90`); composer sort is the full string
  via `localizedStandardCompare`, missing last (`LibraryQuery.swift:128-175`).
  The library is a single `List` with no sidebar
  (`Synth/LibraryScreen.swift:113-118`). No surname logic exists; #30 is
  open and undecided.
- **Tests:** `SynthKitTests` (offline render via
  `setRenderMode(.offline)` + `renderOffline(frameCount:)`,
  `AudioExportTests`, `AudioExportConcurrencyTests`) and `SynthAppTests`
  (`ExportWiringTests`, `AppModelWiringTests`). CI runs `xcodebuild test`.

## Selected implementation direction

All work is in `cedagova/synth`, split between `SynthKit` (model, compiler,
engine, export, query) and the `Synth` app (menus, sheets, models).

- **#90 stems** reuse the export request: one offline render per audible
  line with only that line soloed, all through the same engine graph as the
  mix. Stems are pre-master (master stage bypassed). The batch is staged
  together and published only when every stem succeeded.
- **#91 loop range** adds a render window to the export request. The render
  still runs the whole program from its start and writes only the window,
  so the output is bit-identical to the full export's span. After the
  window ends no new notes start, and sounding notes ring out using the
  existing release-tail rule.
- **#92 compare** adds an in-memory "audition" of a reference preset that
  goes through the same adoption path as activation. It never calls
  `PresetLibrary.activate` or writes a preset. The switch is de-clicked with
  the same short fade used for seeks, and the switch gap is measured in a
  test.
- **#93 rehearsal marks** compile into a non-visual `CompiledScore` field
  (text + source measure, in score order, deduplicated across parts), plus a
  navigator lookup to the first performed measure. The app shows them in a
  Playback submenu and as loop start/end choices.
- **#94 composer filter** derives a composer facet (entries + counts +
  "Unknown composer") from the loaded pieces in `LibraryQuery`. It combines
  with text search and is shown as a filter control in the library. Its
  ordering rule depends on the owner decision below.

## Architecture decisions

These settle the children's "decide during scoping" points. Each is
reversible, changes no persistent or public contract, and follows from the
issue text or pinned evidence.

1. **Stems bypass the whole master stage** (cohesion, calibration, and
   true-peak ceiling). The ceiling and cohesion are nonlinear and
   calibration is measured per program, so a soloed render through the
   master would neither match its share of the mix nor sum back to it.
   #90's acceptance already defines summation "master bypassed".
2. **Stems cover the lines audible in the current mix.** Muted lines (and,
   while solos are active, unsoloed lines) get no stem, so the stems sum to
   what the mix plays. Each stem keeps its line's fader and pan.
3. **Stems never silently clip.** Without the ceiling a pre-master stem can
   exceed full scale. The leaf either writes a format that holds such
   values, or tells the user before publishing. The mechanism is the
   implementer's choice.
4. **Stems never overwrite unrelated files.** The batch is published as a
   unit into a destination whose name collisions are resolved without
   overwriting existing files, unless the user confirms.
5. **Loop-range export is exact by pre-roll.** It renders from the program
   start and writes only the window, keeping the full-piece calibration and
   reverb/voice state. A faster start is allowed only if the same
   byte-identity test still passes. The window is the performed span the
   loop plays, so a loop inside a repeat exports the heard pass.
6. **Ring-out** = no note starts after the window end; sounding notes and
   effects release for the existing capped release-tail length. Bit
   identity is required from window start to window end, except any final
   stretch the master's look-ahead makes depend on later notes. The test
   states that stretch.
7. **The loop-range option is per export, off by default, not persisted,**
   and only enabled when a loop is set. The filename appends the printed
   range (`… mm. 12–24`). Stems ignore the loop range in this effort.
8. **Compare is a latched toggle with a menu command and shortcut.** A
   macOS menu shortcut cannot reliably report key-up, so no hold gesture is
   used. The issue allows "(or toggle)".
9. **The reference preset is session-only.** It is per open piece and not
   persisted. Compare is unavailable when no reference is chosen, when the
   reference is the active preset, or when the reference is deleted.
10. **Compare keeps musical position.** When the two presets' tempos differ,
    the playhead stays at the same score position (measure and beat), not
    the same microsecond. Any preset edit, activation, or export first ends
    compare, and export always uses the active preset (D5).
11. **A rehearsal mark maps to its first performance,** the same rule as Go
    to Measure (`PlaybackNavigator.swift:136-150`). Per-pass entries are
    out of scope.
12. **Marks as loop bounds.** A mark chosen as loop start starts at its
    measure. A mark chosen as loop end ends the loop just before that mark,
    so "A to B" loops section A. The piece end is offered as a final end.
    Loop resolution then follows the existing heard-pass rule.
13. **Rehearsal marks stay non-visual (D2).** They show only as text
    entries in menus and fields. Scores without marks disable the menu
    item.

## Execution graph and waves

- **Topology `DIRECT`:** five independent leaves with no blocked-by edges;
  each merges to `main` on its own.
- **Wave 1 (ready now):** #90, #91, #92, #93 in any order. #90 and #91 both
  touch the export request, sheet, and naming. Whichever lands second
  rebases onto the first; that is a merge-conflict concern, not a
  dependency.
- **#94:** ready once the owner decision below is recorded; no edge to the
  other leaves.

## Interfaces and ownership

All sides are owned by `cedagova/synth`.

- **Export request (SynthKit) ↔ Export UI (app):** #90 adds a batch/stem
  mode and #91 adds an optional render window. Each keeps the single-file
  full-mix path unchanged by default.
- **Export staging (SynthKit):** #90 extends staging from one file to an
  all-or-nothing batch; the single-file path keeps its current guarantees.
- **Preset adoption (app `AssignmentModel`/`PlaybackModel` ↔ engine):**
  #92 adds a non-persisting audition entry point beside activation. The
  persisted active-preset contract (one active per piece) is untouched.
- **`CompiledScore` (SynthKit):** #93 adds a rehearsal-marks field.
  `CompiledScore` is `Codable`, so the field decodes as empty when absent.
  Compiling it must not change any existing compiled output (timeline,
  structure, tempo).
- **`LibraryQuery` (SynthKit) ↔ library screen (app):** #94 adds a composer
  facet and filter predicate; the text search contract is unchanged.

## Risks and rabbit holes

- **Stem export time scales with line count** (N full renders). This is
  acceptable; progress must reflect the whole batch. Do not build a
  multi-bus single-pass renderer in this effort.
- **Summation tolerance.** Per-line humanization and expression must be
  identical between the stem renders and the mix render (deterministic
  seeds per line). If they diverge, that is a bug to fix, not a reason to
  widen the tolerance. The tolerance is stated in the test.
- **Pre-roll cost for late loop ranges.** Pre-roll costs one full render
  up to the window end; accepted for exactness.
- **Compare glitch budget.** A stop/rebuild/start with a fade is the
  baseline. Keeping two programs resident or crossfading engines is out of
  scope unless the measured switch is clearly audible. If it is, record the
  number and stop; do not expand the engine.
- **Second async rebuild on compare** (timeline settings differ). The
  audition must settle to one consistent state before sound resumes, or at
  worst fade across both rebuilds.
- **Duplicate or odd rehearsal marks** (same text twice, per-part copies,
  marks mid-measure). Deduplicate per measure and text, keep duplicates at
  different measures, and show the measure number next to each.

## Migration, rollout, recovery, and rollback

- **No schema or data migration.** No new persisted fields. The reference
  preset and the loop-range option are session state. The composer facet
  and any sort key are derived at query time. Rehearsal marks are
  recompiled from stored MusicXML.
- **Rollout:** each leaf ships on merge to `main`; there are no flags.
- **Rollback:** revert the leaf's merge commit. No data needs repair. A
  failed or cancelled stem batch leaves the destination untouched by
  construction.

## Issue publication manifest

| Key | Kind | Parent | Repository | Title | Delivery | Blocked by | Issue |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ROOT | GROUP | None | cedagova/synth | Listening and export features: stems, loop-range export, preset compare, rehearsal marks, composer filter | DIRECT | None | https://github.com/cedagova/synth/issues/85 |
| STEM090 | LEAF | ROOT | cedagova/synth | Export per-line stems | None | None | https://github.com/cedagova/synth/issues/90 |
| LOOP091 | LEAF | ROOT | cedagova/synth | Export only the loop range | None | None | https://github.com/cedagova/synth/issues/91 |
| CMPR092 | LEAF | ROOT | cedagova/synth | Hold-to-compare against a reference preset | None | None | https://github.com/cedagova/synth/issues/92 |
| MARK093 | LEAF | ROOT | cedagova/synth | Go to rehearsal mark | None | None | https://github.com/cedagova/synth/issues/93 |
| COMP094 | LEAF | ROOT | cedagova/synth | Filter the library by composer | None | None | https://github.com/cedagova/synth/issues/94 |

## Acceptance coverage

| Acceptance | Leaf |
| --- | --- |
| #90 stems sum (master bypassed) to the mix within a stated tolerance | STEM090 |
| #90 Cancel leaves no partial files | STEM090 |
| #91 range export byte-identical to the full export's span (up to ring-out) | LOOP091 |
| #92 toggling while playing keeps the playhead and leaves the on-disk active preset unchanged | CMPR092 |
| #93 fixture marks listed in order; choosing one seeks to its measure | MARK093 |
| #93 no marks → menu item disabled | MARK093 |
| #94 choose composer → only their pieces; clear → full list; combines with text search | COMP094 |

No gaps or overlaps. Combining stems with the loop range is out of scope,
not an orphan; no child asked for it.

## Validation and feedback

- **Every leaf:** `xcodebuild build` + `xcodebuild test` (Synth scheme)
  green in CI, and the leaf's acceptance proved by automated tests in
  `SynthKitTests`/`SynthAppTests`.
- **STEM090:** an offline test that sums the stems of a multi-line fixture and
  compares with the master-bypassed mix at a stated tolerance; a cancel
  test proving the destination is unchanged; a staging test for collisions.
- **LOOP091:** a byte comparison of the window against the same frames of a
  full export (including a loop inside a repeat), plus a ring-out check
  that no note starts after the window end.
- **CMPR092:** a model test that toggles during playback and asserts the
  score position is kept and the stored active preset is unchanged; a
  measured switch gap / peak discontinuity recorded in the test output.
- **MARK093:** compiler tests for an inline fixture with marks (order,
  dedupe, repeat mapping), a regression proving existing compiled output is
  unchanged, and a navigator/menu-state test for a mark-less score.
- **COMP094:** `LibraryQuery` tests for facet counts, Unknown composer,
  the chosen ordering, and filter + search combination.
- **Owner listening check** (optional, not a gate): try stems in a DAW and
  A/B compare by ear.

## Assumptions and open questions

Assumption: the owner's "decide during scoping" notes on #90 (master
stage), #92 (hold vs toggle), and #93 (first pass vs each pass) let the
planner settle them. They are recorded as Architecture decisions 1, 8, and
11 and are reversible. #94's block on #30 is different: the owner recorded
it as a blocking decision, so it is escalated below.

### Owner decision brief — composer ordering for #94 (and #30)

**Problem.** #94's filter lists composers, and #30 (still open) asks
whether composers sort by surname or by the full stored name. Today
"Antonín Dvořák" files under A. The filter list's order, and whether #94
also changes the library's composer sort, depend on the answer.

**Facts.** The composer is one free-text field (`pieces.composer`) taken
from MusicXML `creator`. The sort is `localizedStandardCompare` on the full
string. No surname logic exists anywhere. Grouping in the filter is by the
stored name, compared case- and diacritic-insensitively, under either
option. **Assumption:** most library files store "First Last", but some
may store "Last, First" or initials.

**Options.**

- **A — Surname convention now (recommended).** A derived surname sort key
  is used by both the library composer sort and the filter list. Rule: text
  before a comma if present, otherwise the last word; the full name breaks
  ties. #94 delivers it and closes #30. Benefit: classical ordering
  everywhere, decided once. Cost: a heuristic that misfiles compound
  surnames written "First Last" (e.g. "Ralph Vaughan Williams" files under
  W). Nothing is stored, so it is fully reversible. The execution path
  stays one leaf.
- **B — Decouple.** The filter uses the library's current full-name order;
  #30 stays open, and deciding it later changes both places together. This
  is the smallest change. Dvořák stays under A until #30 is decided.
  Reversible; one leaf.
- **C — Defer #94.** Plan and ship #90–#93 now and leave #94 blocked on
  #30. No composer work lands until #30 is decided separately.

**Recommendation: A.** It resolves a question already raised twice, costs
one derived key and no migration, and is easy to undo.

**Blocks:** COMP094 (#94) acceptance and ordering; nothing else.

**Reply to unblock:** `Choose A`, `Choose B`, or `Choose C` (or a named
change to A's surname rule).

## Satisfaction proof

Implementation work remains; this is not an `ALREADY_SATISFIED` plan.

## Publication verification

Pending: validation and native graph verification run after review.
