# Implementation Plan: Everyday conveniences

- Planning issue: https://github.com/cedagova/synth/issues/84
- Planning PR: https://github.com/cedagova/synth/pull/102
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

Root #84 (created 2026-09-28 from an app-wide review of main at `cd7f1d5`)
asks for three small, high-leverage conveniences in everyday use of the
Synth macOS app. Each is independently shippable:

- **#87** — control playback from the system: media keys, AirPods, Control
  Center's Now Playing.
- **#88** — open `.musicxml` / `.mxl` scores from Finder (double-click,
  Open With), including on cold launch.
- **#89** — take back a mistaken mix or preset change with Undo / Redo.

Boundary preserved from the root: nothing touching the product definition's
non-goals — no score display, no editing of the score, no cloud. Each
child's own Problem, Proposal and Acceptance text is the owner-approved WHAT
and is preserved verbatim in the refined issue bodies; this plan adds only
system-level HOW and closes the one choice #89 explicitly left to scoping.

There is no product-definition or audit handoff marker on the root or the
children; nothing further to preserve.

## Classification

- **ROOT #84: `EFFORT`.** It already owns a native sub-issue tree of three
  children with no blocked-by edges. Each child is one owner-visible outcome
  that is independently acceptable, mergeable and observable, so the tree is
  kept as is; no child is split and none is added.
- **NPL001 #87: `LEAF`.** One integration unit: system remote commands plus
  Now Playing metadata, bound to the open piece's transport.
- **FND001 #88: `LEAF`.** One integration unit: declared document types plus
  an open-URL route into the existing import path. Declaring the types
  without the route (or the reverse) is not independently useful, so they
  stay together.
- **UND001 #89: `LEAF`.** One integration unit: undo registration in the
  mixer/preset model, the window's Edit menu wiring, and the required
  `SynthAppTests` coverage.

No research node is needed: every direction below is supported by pinned
source and standard platform APIs. No owner decision is needed (see
Assumptions and open questions).

## Current-state evidence

All citations are `cedagova/synth@cd7f1d55af204315ff40238cc844b102670d9af4`.

**Playback / system control (#87)**

- No `MediaPlayer` usage anywhere in `Synth/` or `SynthKit/` (grep for
  `MPNowPlaying`, `MPRemoteCommand`: no hits).
- `Synth/PlaybackModel.swift` owns the only live transport and already has
  the actions the remote commands need: `togglePlayPause`, `play`, `pause`,
  `stop`, `skip(byMicroseconds:)`, `seek(toMicroseconds:)`. Each already
  refuses to act when `isReady` is false.
- A `PlaybackModel` exists only while a piece is open
  (`AppModel.playback`, set in `openPlayback(for:)`, cleared in
  `closePlayback()`).
- Tempo is baked into the compiled timeline: `source.scalingTempo(toPercent:)`
  rebuilds the score and `totalMicroseconds` comes from the navigator of that
  rebuilt score. The playhead therefore advances at wall-clock rate at every
  tempo.
- Export renders on its own offline engine (`SynthKit/AudioExport.swift`,
  `PlaybackEngine` in `.offline` mode); the live transport stays usable while
  an export runs.
- `Synth/KeyboardControl.swift` handles Space etc. through a local
  `NSEvent` monitor; it never sees system media keys, so there is no
  conflict to reconcile.

**Finder open (#88)**

- Info.plist is generated (`GENERATE_INFOPLIST_FILE = YES`,
  `Synth.xcodeproj/project.pbxproj:523`/`:548`) and declares no document or
  imported types; no `onOpenURL` / `application(_:open:)` handler exists.
- `LibraryModel.importPieces(from:)` is the one import path used by both the
  file picker and drag-and-drop. It opens a security-scoped resource per
  URL, imports every file, reports one named failure per rejected file, and
  selects the first imported or duplicate piece. It returns early while
  `isWorking` is true.
- `MusicXMLImporter.importPiece(from:)` already de-duplicates by SHA-256 of
  the score content and returns `.alreadyInLibrary(existing)`; the library
  is unchanged whenever it throws.
- Accepted extensions are `musicxml`, `xml`, `mxl`
  (`MusicXMLImporter.acceptedFileExtensions`).
- The app is sandboxed with `files.user-selected.read-write`
  (`Synth/Synth.entitlements`, pinned by `AudioExportEntitlementTests`).
  Files the system hands to the app through Finder open carry their own
  sandbox extension; no entitlement change is needed.
- `AppModel.bootstrap()` is asynchronous; the library is only usable once
  it reaches the ready state, so a cold-launch open arrives before there is
  a `LibraryModel` to receive it.
- The app is one `WindowGroup` sharing one `AppModel`.

**Undo (#89)**

- No `UndoManager` use in `Synth/`.
- `Synth/AssignmentModel.swift` already splits every continuous control
  into `preview…` (engine only, per drag value) and `set…` /
  `commitMixer(forLine:describedAs:)` (one store write, only when the strip
  differs from `activePreset`). Volume, pan, mute, solo, room send and depth
  all funnel through `commitMixer`.
- Preset rename (`commitPresetRename`), switch (`activate(presetID:)`,
  `activateNextPreset`) and delete (`confirmPresetDeletion`, behind a
  confirmation dialog) all go through `write(_:_:)` and the store.
- `Synth/PlaybackCommands.swift` records why `Commands` bodies must not
  hold model-dependent state (they latch at launch); the standard Edit menu's
  Undo/Redo reach the key window's undo manager through the responder chain
  and do not have that problem.
- `SynthAppTests/` exists with model-level wiring tests
  (`AppModelWiringTests`, `PerformanceSettingsWiringTests`).
- Related but separately rooted: #96 (serialize preset adoption, under #86)
  addresses a race when presets switch in quick succession.

## Selected implementation direction

**NPL001 — Now Playing and remote commands.** Use the MediaPlayer
framework's shared remote command center and Now Playing info center from
the app layer. Registration happens once for the app's lifetime and every
handler forwards to whichever `PlaybackModel` is currently open; with none
open, or with the open one not ready, the handler returns
`.noActionableNowPlayingItem`. Now Playing info is published from the open
piece and refreshed on transport-state changes, seeks, loop wraps, tempo
changes and piece open/close — never on the UI ticker. Elapsed time and
duration are in the same timeline the transport readout uses. Because tempo
is already baked into that timeline, the published playback rate is `1.0`
while playing and `0` otherwise (see P84-1). Closing the piece clears the
info and the published playback state.

**FND001 — Open from Finder.** Declare imported type identifiers for
uncompressed and compressed MusicXML through the generated Info.plist
build settings, with the app as a Viewer at Alternate rank, using the
identifiers, extensions and conformances published by the MusicXML
specification (P84-3). Receive opened URLs at the scene/app level and queue
them in `AppModel` until the library is ready; then deliver each batch
through `LibraryModel.importPieces(from:)`, serialized behind any import in
progress so no opened file is dropped by the `isWorking` guard. Selection,
de-duplication, named failure alerts and the unchanged-library guarantee all
come from the existing path. Opening a file must not spawn a second window
(P84-4).

**UND001 — Undo and redo.** Register undo steps on the key window's undo
manager from `AssignmentModel`, at the points where a change is actually
written to the store: `commitMixer` (covers volume, pan, mute, solo, room
send, depth — one step per committed gesture, which is the existing
preview/commit split and gives drag coalescing for free), preset rename and
preset switch. Each step records the preset and line it changed and the
before/after values, and applies through the same model setters so the live
engine, the row, and the auto-saved preset stay consistent. Action names
follow the existing `describedAs:` vocabulary ("Undo Volume Change"). Undo
history is in-memory, scoped to the open piece, and discarded when the piece
closes. Preset deletion keeps its existing confirmation and is not undoable
(P84-2).

## Architecture decisions

Planner decisions (ordinary, reversible, recorded for the reviewer):

- **P84-1 Now Playing rate is `1.0`, not the tempo percentage.** #87's
  proposal lists "playback rate (tempo %)". The system extrapolates elapsed
  time as `elapsed + rate × wall-clock`, and Synth's timeline already runs
  at the chosen tempo, so publishing e.g. `0.8` would make Control Center's
  scrubber drift away from the real playhead. The owner-visible intent —
  Control Center shows the piece and its true position — is met by rate
  `1.0`/`0` plus republishing duration when tempo changes. This corrects a
  mechanism, not the acceptance.
- **P84-2 Preset deletion keeps its confirmation; it is not undoable.**
  #89 delegated this choice to scoping. Deletion is already guarded by a
  confirmation dialog, undoing it would need a store-level restore of a
  deleted preset (and of the auto-created successor when it was the last
  one), and nothing in #89's acceptance requires it. Piece removal lives in
  the library, outside the mixer/preset scope, and keeps its confirmation
  too. Preset creation and deletion clear the open piece's undo history,
  because they change which presets exist and a surviving step could
  otherwise target a preset that is gone or silently rewrite a different one.
- **P84-3 MusicXML identifiers come from the MusicXML specification.**
  #88's proposal names `org.musicxml.xml` and `org.musicxml.musicxml` in a
  way that does not cleanly map uncompressed vs compressed. The leaf uses
  the specification's published UTIs, extensions and conformance (XML for
  uncompressed, zip-archive/data for `.mxl`) and records the source it used.
  Declaring them as *imported* (not exported) keeps Synth from claiming
  ownership of a public format.
- **P84-4 Finder open stays in the one existing window and never
  interrupts.** An open received while the playback screen, Sound Studio or
  instrument catalog is showing imports and sets the library selection, and
  the status line says what happened; it does not navigate away, stop
  playback, cancel an export, or discard unsaved sound edits. The selected
  piece is visible on return to the library. A cold-launch open lands in the
  library, which is the first screen after bootstrap.
- **P84-5 Remote commands only drive the live transport.** They never
  start, cancel or reconfigure an export, and they are ignored while the
  owner is auditioning through Sound Studio's play-through suspension the
  same way the transport's own controls are.
- **P84-6 Undo target discipline.** A step always applies to the preset
  and line it recorded. Because preset switch is itself a step, ordinary
  LIFO unwinding re-activates the right preset before any older mixer step
  is applied. If a step's preset no longer exists or the store write fails,
  the step reports the failure through the existing alert path and the
  history is cleared rather than applied to the wrong target.

## Execution graph and waves

One wave, three independent leaves, no internal blocked-by edges:

| Wave | Leaves | Notes |
| --- | --- | --- |
| 1 | NPL001 (#87), FND001 (#88), UND001 (#89) | Any order; each leaves `main` working. |

The three leaves touch mostly disjoint surfaces (`PlaybackModel`/app
lifecycle; build settings/`AppModel`/`LibraryModel`; `AssignmentModel`/Edit
menu). The only shared file likely touched by more than one is
`Synth/SynthApp.swift` (scene modifiers); a later leaf rebases over an
earlier one's small addition there.

## Interfaces and ownership

All in `cedagova/synth`; one repository, one owner.

- **NPL001** owns the app's only use of the system remote command center and
  Now Playing info center. Contract: handlers delegate to the current
  `PlaybackModel`'s existing public actions; no transport behavior is
  duplicated. Registration is app-lifetime and idempotent.
- **FND001** owns the Info.plist document/imported-type declarations and the
  open-URL entry point. Contract: every opened URL reaches
  `LibraryModel.importPieces(from:)`; the importer's validation,
  de-duplication and error naming are unchanged and not forked.
- **UND001** owns undo registration for mixer strip and preset rename/switch
  in `AssignmentModel`, and hands `AssignmentModel` the window's undo
  manager. Contract: undo and redo apply through the model's own setters
  (engine first, store second, alert on failure), so there is exactly one
  write path.

## Risks and rabbit holes

- **Media keys on macOS need the app to be the Now Playing app.** Remote
  commands only route to Synth after it has published Now Playing info and a
  playing/paused state. Publish on piece open, not only on first play, or the
  play key won't start a paused piece.
- **SwiftUI `WindowGroup` may open a new window for an external URL.**
  Guard with the scene's external-event handling so the existing window
  handles opens; verify with the app already running and with it quit.
- **Cold-launch ordering.** The open URL can arrive before bootstrap
  finishes; it must be queued, not dropped, and delivered once.
- **LaunchServices caching.** A dev build's new document types may not show
  in Open With until LaunchServices re-registers the app; validate with the
  built `.app` and `lsregister` if needed. This is a test-setup issue, not a
  product defect.
- **⌘Z inside text fields.** The search and rename fields keep their own
  text undo via the field editor; mixer undo steps must not be registered
  while a rename is only drafted, only when it commits.
- **Rapid undo/redo of preset switch** exercises the preset-adoption race
  tracked in #96 (separate root). UND001 does not fix that race and must not
  make it worse; its tests assert final state after awaiting adoption. No
  cross-root dependency edge is added because #96 is not a prerequisite for
  the undo outcome.
- **Scope creep.** Undo for sound assignment, tempo, expression, tuning,
  line rename, substitutions, preset creation, or Sound Studio edits is out
  of scope; Sound Studio already has Revert Sound.

## Migration, rollout, recovery, and rollback

- No stored data changes shape in any leaf; no schema migration.
- NPL001 and UND001 are pure app-layer behavior; rollback is reverting the
  PR.
- FND001 adds Info.plist type declarations. Rolling back removes them;
  LaunchServices drops Synth from Open With after re-registration. Imported
  pieces remain ordinary library entries either way.
- Undo history is in-memory only; nothing to migrate or clean up.

## Leaf contracts

These are the refined bodies published to each existing issue. Each keeps
the issue's original Problem, Proposal and Acceptance text verbatim at the
top and adds the planning metadata and the sections below.

### NPL001 — #87 Now Playing and media-key control of playback

- **Desired outcome:** the system's play/pause key, headphone controls and
  Control Center's Now Playing control the open piece and show where it is.
- **In scope:** remote commands play, pause, toggle, stop, skip ±5 s,
  change playback position; Now Playing title, composer, duration, elapsed
  time, playback rate/state; clearing on piece close.
- **Out of scope:** next/previous piece, artwork, rating/like commands,
  any change to export, keyboard shortcuts, or `KeyboardControl`.
- **Acceptance (from #87):** the play/pause media key toggles playback with
  the app in the background; Control Center shows the piece and its
  position, and its scrubber seeks; with an export in progress, remote
  commands don't disturb the export.
- **Constraints:** handlers reuse `PlaybackModel` actions; no piece or a
  not-ready piece → `.noActionableNowPlayingItem`; info updated on
  transport/seek/loop/tempo/open/close events, not per tick; rate `1.0`
  playing, `0` otherwise (P84-1); remote commands never touch an export
  (P84-5).
- **Failure and edge behavior:** seek beyond duration clamps as the existing
  seek does; a tempo change mid-play republishes duration and elapsed;
  closing the piece while playing clears Now Playing; reopening another piece
  replaces it.
- **Validation:** unit tests in `SynthAppTests` for handler → action
  mapping, the no-piece status, and Now Playing dictionary contents
  (including rate and duration after a tempo change), through a seam over
  the MediaPlayer centers; manual smoke with the built app in the
  background: play key, Control Center scrub, and both during an export.
- **Migration and rollback:** none; revert the PR.

### FND001 — #88 Open MusicXML files from Finder (Open With / double-click)

- **Desired outcome:** Finder offers Synth for MusicXML files, and opening
  one imports it and selects it in the library.
- **In scope:** imported UTI declarations (Viewer, Alternate) for
  uncompressed and compressed MusicXML (P84-3); receiving opened URLs;
  queueing them across cold launch; routing through the existing import.
- **Out of scope:** exporting or writing MusicXML, becoming the default
  handler, plain `.xml` claims (too generic to declare), entitlement
  changes, Quick Look previews.
- **Acceptance (from #88):** double-click / Open With imports and selects the
  piece, including on cold launch; opening content already in the library
  selects the existing piece rather than duplicating it; an invalid file
  produces the same named-file failure as the import picker and the library
  is unchanged.
- **Constraints:** one import path (`LibraryModel.importPieces(from:)`),
  no fork of validation; no second window (P84-4); an open during another
  import is queued, not dropped; never interrupts playback, export or Sound
  Studio (P84-4).
- **Failure and edge behavior:** several files opened at once import as one
  batch with one report; an open while bootstrap failed is delivered after a
  successful Try Again or reported as not imported — never silently lost.
- **Validation:** unit tests in `SynthAppTests` for the pending-open queue
  (before ready, during an import, duplicate content, invalid file) against
  a temporary library; manual smoke with the built `.app`: Open With listing,
  double-click with the app running and quit, duplicate, and a damaged file.
- **Migration and rollback:** Info.plist keys only; revert the PR and
  re-register with LaunchServices.

### UND001 — #89 Undo and redo for mixer and preset changes

- **Desired outcome:** ⌘Z takes back the last mix or preset change, audibly
  and in the saved preset; ⇧⌘Z puts it back.
- **In scope:** undo/redo for per-line volume, pan, mute, solo, room send,
  depth; preset rename; preset switch; action names; Edit menu Undo/Redo via
  the window's undo manager.
- **Out of scope:** undo for preset or piece deletion (keep confirmation,
  P84-2), preset creation, sound assignment, tempo, expression, tuning,
  humanization, line rename, substitutions, Sound Studio; persisting undo
  history.
- **Acceptance (from #89):** drag a fader, ⌘Z restores the prior value
  audibly and in the saved preset; tests in `SynthAppTests` cover undo/redo
  of at least volume, mute and preset switch.
- **Constraints:** one step per committed gesture (drag coalesced by the
  existing preview/commit split); undo applies through the model setters so
  engine, row and auto-save stay in sync; target discipline and clearing
  rules (P84-2, P84-6); history scoped to the open piece and discarded on
  close.
- **Failure and edge behavior:** a failed undo write shows the existing
  "Could not save" alert, leaves the strip at the persisted value, and
  clears history; undo in a focused text field undoes text, not the mix.
- **Validation:** `SynthAppTests` cover undo and redo of volume (including a
  multi-value drag as one step), mute, preset switch and rename, and the
  clear-on-create/delete rule, asserting both the model's lines/engine strip
  and the stored preset; manual smoke: drag a fader during playback, ⌘Z,
  hear it, reopen the piece and see the restored value.
- **Migration and rollback:** none; revert the PR.

## Issue publication manifest

| Key | Kind | Parent | Repository | Title | Delivery | Blocked by | Issue |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ROOT | GROUP | None | cedagova/synth | Everyday conveniences: system playback controls, Finder open, undo | DIRECT | None | https://github.com/cedagova/synth/issues/84 |
| NPL001 | LEAF | ROOT | cedagova/synth | Now Playing and media-key control of playback | None | None | https://github.com/cedagova/synth/issues/87 |
| FND001 | LEAF | ROOT | cedagova/synth | Open MusicXML files from Finder (Open With / double-click) | None | None | https://github.com/cedagova/synth/issues/88 |
| UND001 | LEAF | ROOT | cedagova/synth | Undo and redo for mixer and preset changes | None | None | https://github.com/cedagova/synth/issues/89 |

## Acceptance coverage

| Acceptance condition | Source | Covered by |
| --- | --- | --- |
| Play/pause media key toggles playback with the app in the background | #87 | NPL001 |
| Control Center shows the piece and its position; its scrubber seeks | #87 | NPL001 |
| Remote commands don't disturb an export in progress | #87 | NPL001 |
| Double-click / Open With imports and selects the piece, including cold launch | #88 | FND001 |
| Content already in the library selects the existing piece, no duplicate | #88 (proposal) | FND001 |
| Invalid file → same named-file failure as the picker; library unchanged | #88 | FND001 |
| Drag a fader, ⌘Z restores the prior value audibly and in the saved preset | #89 | UND001 |
| `SynthAppTests` cover undo/redo of volume, mute and preset switch | #89 | UND001 |
| Nothing touches the non-goals (score display, editing, cloud) | #84 | all leaves (out-of-scope lines) |

No orphan or overlapping outcome: each condition maps to exactly one leaf.

## Validation and feedback

- Per leaf: the repository's CI (`xcodebuild build` and `xcodebuild test`
  per `.github/workflows/ci.yml`) plus the leaf's own tests and manual smoke
  listed in its contract.
- Root done when #87, #88 and #89 are each merged to `main` and closed.
- Feedback that would re-open planning: a leaf discovering that the system
  cannot route media keys to a sandboxed SwiftUI app without a new
  entitlement, or that Finder open cannot avoid a second window — either is
  reported on the leaf and brought back as a decision rather than widened
  in place.

## Assumptions and open questions

None. The one choice left to scoping (#89 deletion undo) is decided as
P84-2; the other planner decisions P84-1, P84-3 to P84-6 are ordinary and
reversible. Assumption: the system-provided sandbox extension for files
opened through Finder is sufficient to read them (standard macOS behavior;
FND001's cold-launch smoke test proves it).

## Satisfaction proof

Not applicable: implementation work remains for all three leaves.

## Publication verification

Pending until content approval: refine #84, #87, #88 and #89 bodies with
planning metadata and the leaf contracts above, then run `plan
reconcile-graph` and `plan verify-graph`.
