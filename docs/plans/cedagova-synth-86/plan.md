# Implementation Plan: Engineering health

- Planning issue: https://github.com/cedagova/synth/issues/86
- Planning PR: https://github.com/cedagova/synth/pull/103
- Status: Review
- Root classification: EFFORT
- Delivery topology: DIRECT
- Planner: Claude (implementation-planning-lead)
- Started: 2026-09-28

## Pinned baselines

| Repository | Baseline |
| --- | --- |
| `cedagova/synth` | `cd7f1d55af204315ff40238cc844b102670d9af4` |

## Preserved objective and boundaries

Issue #86 is an umbrella from the 2026-09-28 app-wide review. Its objective
is engineering fixes that reduce concrete risk: silent failures, a known
task-ordering race, data safety around migrations, CI speed and
determinism, app-layer test coverage, and moving data out of Swift source.

Its six native sub-issues carry the approved requirements, preserved as
written:

- #95 — an unreadable saved preset is surfaced, not silently replaced by
  defaults; same no-silent-failure rule at the sibling `try?` sites.
- #96 — preset adoption is serialized: one stored task per load, fixed
  order, one re-realization, cancellation by a newer load, owner edits win.
- #97 — the library is backed up (`VACUUM INTO`) before pending schema
  migrations; migration refuses if the backup fails; last N kept; a
  rollback failure is an error, not only a log line.
- #98 — CI builds once, pins Xcode, caches, and keeps the `.xcresult`.
- #99 — direct tests for the app-layer models that own persisted state.
- #100 — the VSCO2 file index moves from a Swift literal to a bundled,
  hash-pinned resource.

Boundaries preserved from the root:

- "Already solid (no action)": realtime-safe render callbacks, off-main
  compile/realize/export, memory-mapped samples, and single-transaction
  migrations are not reworked.
- #36 (migration rollback mechanism) stays a standalone, parentless issue.
  #97 is its cheapest first step and does not decide #36.
- No new product features, UI surfaces beyond the #95 message, or changes
  to the release workflow.

## Classification

- ROOT #86: `EFFORT`. It already owns a native tree of six sub-issues, each
  an independently acceptable, mergeable, and observable outcome. No new
  children are needed and none of the six should be split or merged. It
  becomes a `GROUP` with `Implementation delivery: DIRECT`.
- #95 surface unreadable presets: `LEAF`.
- #96 serialize preset adoption: `LEAF`.
- #97 back up before migrations: `LEAF`.
- #98 CI build-once/pin/cache/results: `LEAF`.
- #99 app-layer model tests: `LEAF`. One outcome ("each named model has a
  direct test file"); splitting per model would add review and CI surfaces
  without an independently valuable result.
- #100 VSCO2 index as a resource: `LEAF`.

Not `INCREMENTAL`: no child is itself an effort, and no child's plan depends
on evidence another child produces.

## Current-state evidence

All at `cd7f1d5`.

- #95: `PlaybackModel` reads the active preset with `try?`
  (`Synth/PlaybackModel.swift:386`), so a throwing read and "no preset
  yet" both fall through to standard settings. `PresetLibrary
  .activePreset(forPieceID:)` already distinguishes them (throws vs `nil`,
  `SynthKit/PresetLibrary.swift:166`). `AssignmentModel.load` reads the
  same preset with `try` and already raises "Could not read this piece's
  presets" (`Synth/AssignmentModel.swift:207-236`); the silent path is the
  playback side. Siblings: `SoundEditorModel.swift:133` (based-on lookup)
  and `InstrumentCatalogModel.swift:99,116` (first-run-offer preference
  read and write).
- #96: five unstored `Task { await adoptPreset… }` closures fire from the
  `AssignmentModel.on…Loaded` callbacks (`PlaybackModel.swift:240-258`);
  those callbacks fire on every `load` and `reloadPresetAndApply`
  (`AssignmentModel.swift:224-228`, `1038-1042`). The equality guard is
  evaluated at enqueue time only.
- #97: `LibraryStore.open` runs `SchemaMigrator.migrate` right after the
  pragmas (`SynthKit/LibraryStore.swift:156`); `migrate` computes
  `pending` from the stored version (`SchemaMigrator.swift:318-337`) and
  runs it in one transaction. `SQLiteDatabase.withTransaction` only
  `NSLog`s a rollback failure (`SQLiteDatabase.swift:238-244`). The store
  lives in the one Application Support container (`AppContainer`, layout
  AD3).
- #98: `ci.yml` runs `xcodebuild build` then `xcodebuild test` (a second
  build), selects the newest installed Xcode, caches nothing, and keeps no
  result bundle. The runner currently selects Xcode 26.3 (run
  36449654066). Recent green main runs take about 9 minutes (run
  34653660275: 22:21:48 → 22:30:52).
- #99: `SynthAppTests` holds only `AppModelWiringTests`,
  `ExportWiringTests`, `PerformanceSettingsWiringTests`. They build a real
  `AppModel` over a temp-directory `AppContainer` and run on CI today, so
  the same harness works without new infrastructure. `AssignmentModel`
  (1072 lines), `LibraryModel` (442), `SoundStudioModel` (515),
  `InstrumentEditorModel` (404), `SoundEditorModel` (449) have no direct
  tests.
- #100: `vsco2Index` is a tab-separated raw string literal
  (`SynthKit/CuratedInstrumentLibraries.swift:446-2986`) of git-blob
  digest, size, and path. SynthKit is a framework target using
  file-system-synchronized groups, and bundles no resource yet.

## Selected implementation direction

Six independent leaves in one repository, each one PR.

- #95: the playback-side read distinguishes "no preset" from "read
  failed"; a failure opens the piece under standard settings, shows a
  non-blocking owner-visible message naming the piece and the error, and
  performs no automatic write to that piece's stored preset. Sibling sites
  route failures to their model's existing alert or status surface.
- #96: preset adoption becomes one stored, cancellable unit per load that
  applies the five settings in a fixed order and triggers at most one
  re-realization. A newer load cancels the pending one; owner edits made
  during adoption are not overwritten (serial path or generation check —
  implementer's choice).
- #97: before running a non-empty pending chain on an existing store, the
  open path writes a `VACUUM INTO` copy under the container's `backups/`
  folder, named with the from-version and a timestamp, and refuses to
  migrate if that fails. It then keeps the newest three backups. A
  rollback failure is thrown alongside the original error.
- #98: CI does `build-for-testing` once and `test-without-building`, pins
  Xcode 26.3 in one place and fails loud if absent, caches DerivedData
  keyed on Xcode version and project file, and always uploads the
  `.xcresult`.
- #99: one direct test file per named model in `SynthAppTests`, on the
  existing temp-directory harness.
- #100: the index becomes a TSV resource inside the SynthKit framework,
  loaded once through the framework bundle, hash-pinned by a test; a load
  failure is a hard error, never an empty catalog.

## Architecture decisions

| ID | Decision | Why |
| --- | --- | --- |
| P86-1 | Topology `DIRECT`, no internal blocked-by edges. | Every leaf is independently releasable. #95 and #96 both touch the preset-load path in `PlaybackModel`; whichever merges second rebases. That is a routine conflict, not a dependency. |
| P86-2 | #99 covers the five models its Problem names with no direct tests (`AssignmentModel`, `LibraryModel`, `SoundStudioModel`, `InstrumentEditorModel`, `SoundEditorModel`). `PlaybackModel`'s direct coverage comes from the #95 and #96 acceptance tests. | The acceptance says "each named model"; "start with" in the Proposal is an order, not a limit. Avoids duplicating #95/#96 tests. |
| P86-3 | #97 keeps the newest 3 backups and skips the backup when the store has no schema yet (a brand-new library, stored version 0). | The issue's "e.g. 3" is reversible; a fresh library holds nothing to protect, and backing it up would leave a file on every first launch. |
| P86-4 | #98 pins Xcode 26.3, the version CI already uses. | Removes drift without changing today's toolchain. `release.yml`'s own Xcode selection (it excludes 26.3 for Release) is out of scope. |
| P86-5 | #100 keeps the literal's existing tab-separated format as the resource, byte-for-byte. | The parser and the "identical catalog" acceptance stay trivial; no format conversion to review. |

## Execution graph and waves

One wave; all six leaves are independent.

| Wave | Leaves |
| --- | --- |
| 1 | #98, #97, #96, #95, #100, #99 |

Recommended (not enforced) order, listed above: #98 first so every later
PR runs on the faster CI, then the data-safety and correctness fixes, then
#100 and #99. Do not run #95 and #96 concurrently.

## Interfaces and ownership

All in `cedagova/synth`.

- `PresetLibrary` (SynthKit) keeps its throwing read API unchanged; #95
  changes only how app models consume it.
- `AssignmentModel`'s `on…Loaded` callbacks are the seam #96 reshapes. The
  callbacks may be consolidated into one "preset loaded" signal; that is
  internal to the app target.
- `LibraryStore.open` / `SchemaMigrator` (SynthKit) own the backup step
  (#97). `AppContainer` gains a `backups` location and its layout doc
  (AD3) is updated. `SQLiteDatabase.withTransaction`'s error contract
  changes: a failed rollback is reported in the thrown error.
- `CuratedInstrumentLibraries` (SynthKit) owns loading the bundled
  resource (#100); callers see the same catalog values.
- `.github/workflows/ci.yml` is the only CI file touched (#98).

## Risks and rabbit holes

- #96: "one realization" needs an observable realization count or seam in
  tests; add the smallest seam, do not restructure the realizer. The
  cancelled load must not leave half its settings applied.
- #95: `AssignmentModel` already alerts on the same failure; the owner
  should see one coherent message, not two contradictory states. The
  stored preset must stay byte-identical — including not being replaced by
  `activePreset(for:palette:)`'s auto-create path.
- #97: `VACUUM INTO` needs free disk roughly the size of the store;
  running out is a backup failure and must refuse the migration with a
  clear error, leaving the store unmigrated. Pruning may delete only files
  matching the backup naming pattern inside `backups/`.
- #98: a DerivedData cache can mask a clean-build break. The key must
  include the pinned Xcode version and project file hash so a toolchain or
  project change rebuilds from scratch.
- #100: the resource must land inside the SynthKit framework bundle in both
  Debug and Release products; a test loading it through the framework
  bundle is the proof. Keep the hand-written catalog descriptions
  (lines 41–430) in Swift.
- Out of scope, recorded: main CI at `cd7f1d5` is red because
  `MasterStageRenderTests.testTurningTheProducedMasterOnCostsLessThanASecondOfProgramBuild`
  measured 1.183 s against its 1.0 s bound on the runner (run
  36449654066). #98's leaf does not fix timing-test flakiness; a red
  baseline makes #98's before/after timing use the last green run.

## Migration, rollout, recovery, and rollback

- Only #97 touches persisted data, and only additively: it writes backup
  files and changes no schema. Rollback is `git revert`; leftover backup
  files are inert.
- #95, #96, #99, #100 change no persisted format. Rollback is `git revert`.
- #98 is CI-only. Rollback is `git revert` of the workflow.
- No feature flags, no staged rollout; each leaf ships on merge to `main`.

## Leaf contracts

These are published into each child issue after content approval, below
the issue's existing Problem / Proposal / Acceptance text, which stays.

### #95 — Surface unreadable saved presets

- In scope: the playback-side preset read; `SoundEditorModel` based-on
  lookup; `InstrumentCatalogModel` first-run-offer preference read/write.
- Out of scope: other `try?` uses (`Task.sleep`, `AppModel` fixture lookup);
  repairing a corrupt preset.
- Acceptance: with a library whose active preset for a piece cannot be
  read (for example its stored content is undecodable), opening the piece
  plays under standard settings, shows a non-blocking message naming the
  piece and the error, and the stored preset row is byte-identical after
  open and playback with no owner edit. A piece with no preset still opens
  silently under standard settings. Each sibling failure reaches the
  owner through that model's existing alert or status surface.
- Constraints: no automatic write to an unreadable preset; the message
  does not block playback.
- Dependencies: None.
- Rollback: `git revert`; no data change.

### #96 — Serialize preset adoption

- In scope: how `PlaybackModel` adopts the five preset settings on load
  and reload.
- Out of scope: undo/redo (#89); changing what a preset stores.
- Acceptance: switching presets twice in quick succession ends with every
  playback setting equal to the second preset and exactly one
  re-realization for that adoption; an owner edit made while an adoption
  is pending is not undone by it.
- Constraints: fixed application order; a cancelled adoption applies
  nothing further; realization stays off the main actor.
- Dependencies: None (rebase against #95 if it merges first).
- Rollback: `git revert`.

### #97 — Back up the library before schema migrations

- In scope: backup step in the open path, retention, rollback-failure
  reporting, `AppContainer` layout doc.
- Out of scope: down-migrations or backward-tolerant open (#36); a restore
  UI.
- Acceptance: migrating a v(n-1) fixture produces
  `backups/library-v<n-1>-<timestamp>.sqlite` that opens at v(n-1) with
  identical rows in every table; a backup failure leaves the store at
  v(n-1) and the open fails with an error naming the backup; a fourth
  backup prunes the oldest; a brand-new library creates no backup; a
  failed rollback surfaces in the thrown error.
- Constraints: backup completes before the migration transaction begins;
  pruning touches only backup-named files in `backups/`.
- Dependencies: None.
- Rollback: `git revert`; backup files are inert.

### #98 — CI: build once, pin Xcode, cache, keep results

- In scope: `.github/workflows/ci.yml` only.
- Out of scope: `release.yml`; fixing flaky timing tests.
- Acceptance: one build per run (`build-for-testing` +
  `test-without-building`); Xcode 26.3 pinned in one place, and a missing
  pin fails the run naming the version; DerivedData cache keyed on Xcode
  version and project file; `.xcresult` uploaded on every run, including
  failure, and downloadable from a failing run; before/after wall clock
  recorded in the PR against the last green main run; the arm64-only
  `lipo` check still runs.
- Dependencies: None.
- Rollback: `git revert`.

### #99 — Direct tests for app-layer models

- In scope: one test file each for `AssignmentModel` (mix, preset CRUD,
  auto-save), `LibraryModel` (import, rename, remove), `SoundStudioModel`,
  `InstrumentEditorModel`, `SoundEditorModel`.
- Out of scope: `PlaybackModel` (covered by #95/#96); `AppModel` wiring
  (already covered).
- Acceptance: each file covers the model's state-changing actions and at
  least one failure path, on a temp-directory store, with no dependency on
  audio hardware beyond what the existing wiring tests use.
- Constraints: production changes limited to behavior-preserving test
  seams.
- Dependencies: None.
- Rollback: `git revert`.

### #100 — VSCO2 file index as a bundled resource

- In scope: moving `vsco2Index` to a TSV resource in SynthKit, loading it
  once, the hash-pin test, removing the literal.
- Out of scope: the hand-written catalog descriptions; other curated
  libraries' data.
- Acceptance: the catalog built from the resource is identical to the one
  built from the literal (compared before the literal is deleted); a test
  pins the resource's SHA-256; a missing or unreadable resource is a hard
  error, never an empty catalog; the resource loads through the framework
  bundle.
- Dependencies: None.
- Rollback: `git revert`.

## Issue publication manifest

| Key | Kind | Parent | Repository | Title | Delivery | Blocked by | Issue |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ROOT | GROUP | None | cedagova/synth | Engineering health: silent failures, preset race, migration backup, CI, app tests, catalog data | DIRECT | None | https://github.com/cedagova/synth/issues/86 |
| L095 | LEAF | ROOT | cedagova/synth | Tell the owner when a saved preset can't be read instead of silently playing defaults | None | None | https://github.com/cedagova/synth/issues/95 |
| L096 | LEAF | ROOT | cedagova/synth | Serialize preset adoption so loads can't race each other | None | None | https://github.com/cedagova/synth/issues/96 |
| L097 | LEAF | ROOT | cedagova/synth | Back up the library before running schema migrations | None | None | https://github.com/cedagova/synth/issues/97 |
| L098 | LEAF | ROOT | cedagova/synth | CI: build once, pin Xcode, cache, keep test results | None | None | https://github.com/cedagova/synth/issues/98 |
| L099 | LEAF | ROOT | cedagova/synth | Direct tests for the app-layer models | None | None | https://github.com/cedagova/synth/issues/99 |
| L100 | LEAF | ROOT | cedagova/synth | Move the VSCO2 file index out of Swift source into a bundled resource | None | None | https://github.com/cedagova/synth/issues/100 |

## Acceptance coverage

| Root outcome | Covered by |
| --- | --- |
| Silent failures (unreadable preset and siblings) | L095 |
| Known task-ordering race (preset adoption) | L096 |
| Data safety around migrations | L097 (backup, retention, rollback-failure reporting); #36 stays standalone |
| CI speed and determinism | L098 |
| App-layer test coverage | L099 (five models), L095/L096 (PlaybackModel) |
| Data out of Swift source | L100 |

No orphan or overlapping outcome: each child owns exactly one root outcome.
L095 and L096 share a file but not an outcome.

## Validation and feedback

- Every leaf: full `xcodebuild test` green on CI, plus its own acceptance
  tests above.
- L095/L096/L099: `SynthAppTests` on the temp-directory harness.
- L097/L100: `SynthKitTests` (migration fixture, row equality, hash pin,
  catalog equality).
- L098: evidence is the workflow run itself — before/after timing and a
  downloadable `.xcresult` from a failing run — recorded in the PR.
- The pre-existing red timing test on main is not a leaf's failure; a leaf
  PR notes it if it is still red rather than weakening the bound.

## Assumptions and open questions

None requiring owner decision. Planner choices P86-1 to P86-5 are ordinary
and reversible, recorded above. The timing-test flake on main is recorded
as an out-of-scope observation, not planned here.

## Satisfaction proof

Not applicable — implementation work remains in all six leaves.

## Publication verification

Pending publication: the six child bodies and the root body gain their
planning metadata and leaf contracts after content approval; the native
tree already matches the manifest.
