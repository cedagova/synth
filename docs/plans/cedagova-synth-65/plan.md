# Implementation Plan: Future sound improvements: expression, master, tuning

- Planning issue: https://github.com/cedagova/synth/issues/65
- Planning PR: https://github.com/cedagova/synth/pull/66
- Status: Review
- Root classification: INCREMENTAL
- Delivery topology: INCREMENTAL
- Planner: Claude (implementation-planning-lead)
- Started: 2026-09-10
- Preserved product contract (on main, not a live definition PR):
  `docs/product-definitions/cedagova-synth-49/definition.md` (reviewed head
  32e8ce6 of closed PR #50) and the prior reviewed plan
  `docs/plans/cedagova-synth-49/plan.md` (reviewed head cdcf3a8 of closed
  PR #55).

## Pinned baselines

| Repository | Baseline |
| --- | --- |
| `cedagova/synth` | `d59e56137d0c7d56e3f7af7fd3c70a81ed7bd3b0` |

## Preserved objective and boundaries

Issue #65 is the durable shelf for the outcomes of the pro-grade-sound
effort (#49) that were fully specified, independently reviewed, and then
closed as not planned when increment 001 (staging, #51) delivered the
listening improvement the owner wanted. This plan turns that shelf into an
executable path without changing the product contract it preserves.

Preserved requirements (definition REQ numbers, verbatim intent):

- REQ-003 deterministic expression: with expression on, dynamics vary over
  phrases and cadences beyond written dynamics; two renders of the same
  piece + preset are byte-identical; export equals live playback.
- REQ-004 honest bypass: expression off + staging neutral + tuning at
  default + mastering off renders with only written notation plus uniform
  humanization, deterministically. No bit-comparison against pre-delivery
  builds is promised.
- REQ-005 master headroom: no export clips (true peak ≤ −1 dBFS); quiet
  pieces are not exported inaudibly low; two different pieces export at
  comparable perceived loudness.
- REQ-006 tuning: a preset can select equal temperament (default), at least
  one well temperament, and A=440 vs A=415; the choice audibly changes
  intonation color, is stored in the preset, and applies to export.
- REQ-007 performance: the pinned reference piece (BWV 1046 import, content
  SHA-256 prefix `8c3c7097412b5cfc`) plays start to end on the baseline
  Apple Silicon machine without an overload pause with all features on.
- The two staging refinements deferred from #57 by recorded decision (PR
  #64 reconciliation): register-aware placement, and gentle level shading.

Owner decisions preserved verbatim from the definition: D4 revised (bounded
deterministic score-derived expression allowed; AI/ML and per-performer
emulation excluded); pre-release clean slate (no preset migration
promises); tuning outcome included. Non-goals preserved: no per-note
editing surface, no visualization, no plugin hosting, no new sample
content, no standards-lab loudness metering. Inviolable guardrails: same
piece + preset + settings → identical audio (AD5), and export byte-equals
live playback.

Owner decisions recorded in this planning run (chat thread, 2026-09-10):

- **D65-1 Control surface.** Mechanisms are core; the owner-facing surface
  is small and preset-stored: expression on/off + one amount (on for fresh
  presets); bus cohesion on/off; temperament picker; reference-pitch
  picker. The true-peak limiter and per-piece loudness calibration are
  always on with no control. Articulation defaults are always on.
  Register-aware placement lands as ordinary staged mixer values (the
  existing per-line mixer is the override surface). Taste constants stay
  code-only and centralized (`PresetStaging`, `SYNTH_DEPTH_*`, and the new
  per-feature constant homes).
- **D65-2 Reading of REQ-004 under D65-1.** "Mastering off" means cohesion
  off. The bypass recipe still passes through the always-on ceiling and the
  static per-piece calibration gain; the automated bypass check therefore
  asserts that the recipe's render equals the raw line sum scaled by one
  static gain (bit-identical while under the ceiling), with no room, phrase
  dynamics, or cohesion signature. This is the only reinterpretation of
  the preserved contract and it follows directly from D65-1.
- **D65-3 Increment order** kept from the reviewed #49 plan: staging
  refinement → expression → master → tuning.

## Classification

- ROOT #65: `INCREMENTAL`. The shelf holds three real efforts (expression,
  master, tuning), each an independently deliverable listening improvement
  with its own bypass and acceptance, plus one small staging refinement.
  Flattening them into one run would erase those delivery boundaries, and
  later increments consume listening evidence from earlier ones (master
  calibration must target the levels a staged, expressive mix actually
  produces). The root becomes tracking-only. #65 keeps its research-record
  body and gains tracking metadata.
- INC001 Register-aware seating: `GROUP`, increment 001, one leaf. A
  staging (OUT001) concern with its own REQ-004 composition boundary;
  folding it into the expression increment would blur which off-state
  each feature owns.
- INC002 Expressive interpretation: `GROUP`, increment 002, two ordered
  leaves (successor of closed #52).
- INC003 Produced master: `GROUP`, increment 003, one leaf (successor of
  closed #53).
- INC004 Historical tuning color: `GROUP`, increment 004, one leaf
  (successor of closed #54).

The previously published nodes #52–#54 and #58–#61 are closed as not
planned and carry `Planning root: #49` / `Planning plan: #55`. Overwriting
that provenance would be a publication conflict, so this plan publishes
fresh successor issues under #65 and cites the closed issues as provenance
in each body. No increment is deferred: pinned evidence supports planning
all four now. The sequence is a strict total order (001→004); each later
increment is natively blocked by its immediate predecessor.

## Current-state evidence

Pinned at `cedagova/synth@d59e561`:

- Staging is a pure function of seat index, part count, and the named
  instrument family: `PresetStaging.mixer(lineIndex:lineCount:family:)`
  returns pan/roomSend/depth with volume 1 everywhere; `PresetAutoAssignment
  .initialContent` calls it per `LineInventory` entry. The inventory carries
  ids, names, part name, staff, and voice — no pitch information — so
  register-aware placement needs a score-derived register summary reaching
  the derivation. Depth exists in the render core (`SYNTH_DEPTH_*`) and the
  document (`LineMixerState.depth`), and `LineMixerState` has five
  application surfaces that must move together (`PresetPerformance
  .applyMixer`, `PlaybackEngine` carry/restore, `AudioExport.applyMixer`,
  `AssignmentModel.writeStrip`, additive Codable decode).
- The PR #64 reconciliation for #57 recorded: the family map is the
  register proxy at that increment's altitude; per-passage line balance
  belongs to expression and loudness to the master, so level shading in
  staging would double-own those surfaces.
- Realization is a pure function of (piece, preset, settings):
  `PerformanceRealizer` + `RealizationSettings`; determinism is guarded by
  `PerformanceTimelinePurityTests` frozen digests and export equality by
  `OfflineRenderTests`/`AudioExportTests`. Expression today is uniform
  seeded jitter (`PerformanceHumanization`, `SeededJitter`) plus written
  notation; the compiled score already carries slurs, rests, written
  dynamics and articulations (`ScoreExpressionEvent`,
  `ScoreLineRealization`). Humanization is a preset-stored setting
  (`PresetContent.humanization`, additive decode) with an app toggle
  (`HumanizationBar` in `PlaybackScreen`) whose change → re-render → save
  behavior is the precedent for every new setting.
- The master bus is gain-only (`masterGain` atomic in `SynthAudioCore.c`,
  `synth_engine_set_master_gain`); one render graph serves live and
  offline (`PlaybackEngine.renderTimelineOffline`); overload telemetry
  (`overloadBlocks`/`overloadPauses`) exists and is exercised by the
  env-gated REQ-007 guardrail in `RealtimePlaybackTests`
  (`SYNTH_REALTIME_GUARDRAIL=1` + `SYNTH_REFERENCE_PIECE=<path>`).
- Tuning is fixed equal temperament at A=440 in both voice engines
  (`SynthPatchEngine.c` note-frequency derivation; `SampleVoiceEngine.c`
  playback-rate derivation).
- Increment 001 lessons that bind here: per-line DSP state flushes
  denormals per sample and clears on relocate; byte-equality fixtures must
  include note-into-silence programs; fresh presets are staged, not
  neutral, so tests wanting a neutral baseline flatten strips explicitly.

## Selected implementation direction

System-level HOW, per increment:

1. **Register-aware seating (001).** Give the staging derivation a
   per-line register summary computed from the compiled score (a bounded,
   deterministic statistic of the line's sounding pitches, implementer's
   choice) alongside the existing seat/family inputs, and bias pan and
   depth by register: bass-register lines sit nearer centre-right and
   further back, per the definition's stated seating convention; treble
   lines keep their score-order seat. Values remain ordinary staged
   `LineMixerState` values written at preset creation and on reconcile for
   added lines, editable in the existing mixer, with no new control and no
   change to stored presets. Level shading is deliberately not added as a
   static strip value: the recorded #64 decision stands, and EXP002's
   per-passage balance is the owner of that effect.
2. **Expression (002).** Extend `RealizationSettings` with a preset-stored
   expression setting (enabled + amount; on for fresh presets). Inside the
   realizer — keeping realization a pure function — derive phrase
   segmentation from the score (slurs, rests, cadential motion),
   phrase-shaped dynamics, cadence/phrase-end breathing (bounded local
   timing), articulation defaults (legato under slurs, detaché otherwise,
   honoring written articulations; always on), and melody/accompaniment
   balance per passage (rides the amount). Off must satisfy REQ-004's
   bypass recipe exactly. UI: one toggle and one amount beside
   humanization with the same re-render-and-save behavior.
3. **Master (003).** Add a master stage after the line sum in the render
   core: an always-on true-peak-safe ceiling at ≤ −1 dBFS, a deterministic
   per-piece loudness calibration gain computed once per program from a
   bounded offline analysis of the realized program at build (AD-P5;
   windowed-RMS integrated proxy with a fixed target, constants
   implementer's), and a bypassable bus-cohesion block with one
   preset-stored on/off. All applied identically live and in export (one
   graph). Cohesion off is bit-identical to the calibrated, ceiling-guarded
   sum.
4. **Tuning (004).** Thread a per-program tuning table (12 pitch-class
   offsets + reference A frequency) through both voice engines including
   sample playback-rate adjustment; ship equal temperament (default),
   Werckmeister III, and A=440/415 as preset-stored settings beside
   humanization/expression with two pickers, applied to live and export
   alike.

## Architecture decisions

- **AD-P1 — expression lives in the realizer, not the engines.** All
  expressive shaping lands in the timeline (pure function), so determinism,
  export equality, and the frozen-digest harness keep guarding it; the C
  engines stay expression-agnostic.
- **AD-P2 — one render graph carries everything.** Staging, master, and
  tuning are program/engine state applied identically to live and offline
  rendering; no export-only or live-only processing is permitted.
- **AD-P3 — preset document grows additively at version 1**, following the
  `humanization` precedent (decode-if-present with defaults); clean slate
  per owner decision, no migration code.
- **AD-P4 — no new bundled audio assets.** Nothing here adds impulse
  responses or sample content.
- **AD-P5 — calibration is a bounded, deterministic pre-pass** at program
  build (offline analysis of the realized program), never a live adaptive
  process, so identical inputs keep producing identical audio.
- **AD-P6 — safety is core, color is optional.** The ceiling and
  calibration have no owner control; cohesion, expression, and tuning do.
  Every optional setting is preset-stored with the humanization
  precedent's change → re-render → save behavior and app-standard
  accessibility.
- **AD-P7 — staging derivation stays a pure function of score-derived
  inputs.** Register summaries are computed from the compiled score, never
  from rendered audio, so preset creation remains deterministic and
  reconcile-safe.

## Execution graph and waves

Strict increment order — each wave is one increment, merged, verified, and
closed before the next starts:

| Wave | Increment | Leaves (ordered) |
| --- | --- | --- |
| 1 | 001 register-aware seating | STG003 |
| 2 | 002 expression | EXP001 phrase dynamics/breathing + setting/bypass → EXP002 articulation + line balance |
| 3 | 003 master | MST001 ceiling + calibration + cohesion |
| 4 | 004 tuning | TUN001 temperament + reference pitch |

Rationale for the order: the seating refinement first because it is small
and every later listening judgment happens on the final staged mix;
expression second as the core musical gap; master third so its
calibration targets real (staged, expressive) levels; tuning last as an
isolated, lowest-risk color feature. Splitting the ceiling out as an
earlier safety leaf was offered to the owner and not taken (D65-3).

## Interfaces and ownership

Single repository (`cedagova/synth`); all interfaces are internal contracts:

- `PresetStaging` / `PresetAutoAssignment` (SynthKit) own staging
  derivation; the compiled score owns the register summary input;
  `LineMixerState` five-surface rule applies to any additive strip field.
- `RealizationSettings` → `PerformanceRealizer` (SynthKit) own expression;
  the timeline remains the only carrier of expressive decisions. The app
  owns the toggle/amount UI beside humanization.
- The C render core (`SynthAudioCore`) owns the master stage and the
  tuning-table application in both voice engines; SynthKit owns the
  calibration pre-pass, tuning tables, settings, and persistence; the app
  owns the cohesion toggle and tuning pickers.
- The A/B bypass contract (REQ-004 as read by D65-2) spans increments: each
  increment's off state must compose so the full recipe renders notation +
  uniform humanization through the static calibration gain and ceiling
  only.

## Risks and rabbit holes

- **Taste is unbounded.** Guard: defaults are constants in one place per
  feature, judged against observable acceptance and the owner's listening
  A/B; no parameter-surface expansion beyond D65-1.
- **Register heuristics on ambiguous lines.** Guard: the register summary
  is a bounded statistic with a neutral fallback (no bias) for lines with
  few or no pitches; the family proxy remains the base.
- **DSP determinism.** New float paths (master, tuning) must render
  identically across runs and host buffer sizes, including after silence
  (per-sample denormal flush, state cleared on relocate); the existing
  purity/equality harnesses are the gate and get extended per increment,
  with frozen digests refrozen deliberately (two agreeing runs).
- **Always-on calibration versus REQ-004.** Guard: D65-2 makes the bypass
  assertion explicit (raw sum × one static gain, bit-identical under the
  ceiling); a silent or near-silent piece calibrates to unity so the gain
  can never explode.
- **Overload headroom (REQ-007).** Each increment's completion includes a
  full playthrough of the pinned reference piece without overload pause;
  the added DSP must fit the existing real-time budget on Apple Silicon.
- **Loudness rabbit hole.** No standards-lab loudness implementation; the
  bounded windowed-RMS proxy with a fixed target satisfies REQ-005's
  "comparable loudness" without importing a metering suite.
- **Sampled-instrument interaction.** Tuning must apply to sample playback
  (rate adjustment) as well as synthesis; acceptance covers both engine
  kinds; keyswitch and velocity-layer behavior is unchanged apart from
  pitch.

## Migration, rollout, recovery, and rollback

Pre-release clean slate (owner decision): no data migration; preset fields
are additive with defaults that reproduce today's behavior (expression
default applies only to freshly created presets; stored presets decode
with expression off unless the implementer records otherwise in the leaf
and the reviewer accepts it — the definition's clean-slate decision permits
either). Rollout is per-increment on `main`, each leaving the app working
(increment completion rule). Recovery/rollback: every optional feature has
an off state that restores the D65-2 bypass character; the always-on
ceiling and calibration are transparent for material under the ceiling and
unity-calibrated for silence; any increment can be reverted independently
since later increments only consume — never rewrite — earlier ones' stored
values.

## Issue publication manifest

| Key | Kind | Parent | Repository | Title | Delivery | Blocked by | Issue |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ROOT | TRACKING | None | cedagova/synth | Future sound improvements: expression, master, tuning — reviewed research and development lessons | INCREMENTAL | None | https://github.com/cedagova/synth/issues/65 |
| INC001 | GROUP | ROOT | cedagova/synth | Register-aware seating: staging placement by line register | DIRECT | None | Pending |
| INC002 | GROUP | ROOT | cedagova/synth | Expressive interpretation: deterministic phrasing, articulation, and line balance | COLLECTOR | INC001 | Pending |
| INC003 | GROUP | ROOT | cedagova/synth | Produced master: ceiling, loudness calibration, and cohesion | DIRECT | INC002 | Pending |
| INC004 | GROUP | ROOT | cedagova/synth | Historical tuning color: well temperament and baroque pitch | DIRECT | INC003 | Pending |
| STG003 | LEAF | INC001 | cedagova/synth | Register-aware placement at preset creation | None | None | Pending |
| EXP001 | LEAF | INC002 | cedagova/synth | Deterministic phrase expression: shaped dynamics, cadence breathing, setting and bypass | None | None | Pending |
| EXP002 | LEAF | INC002 | cedagova/synth | Articulation defaults and melody/accompaniment balance | None | EXP001 | Pending |
| MST001 | LEAF | INC003 | cedagova/synth | Master stage: true-peak ceiling, deterministic loudness calibration, bypassable cohesion | None | None | Pending |
| TUN001 | LEAF | INC004 | cedagova/synth | Temperament and reference pitch through both voice engines | None | None | Pending |

## Acceptance coverage

| Preserved requirement | Covered by |
| --- | --- |
| Register-aware placement (deferred from #57) | STG003 |
| Gentle level shading (deferred from #57) | EXP002 per-passage balance, honoring the #64 decision that balance belongs to expression; no separate static shading |
| REQ-003 deterministic expression | EXP001, EXP002 |
| REQ-004 honest bypass (as read by D65-2) | EXP001 (recipe owner); the composed off-state check is an explicit acceptance line on the final leaf of every increment (STG003, EXP002, MST001, TUN001) and verbatim in each increment's completion rule |
| REQ-005 master headroom/loudness | MST001 |
| REQ-006 tuning choice | TUN001 |
| REQ-007 reference-piece performance | Explicit acceptance line on the final leaf of every increment (STG003, EXP002, MST001, TUN001): full playthrough of the pinned reference piece with all features delivered so far on, `overloadPauses == 0`; also verbatim in each increment's completion rule |
| D65-1 control surface | EXP001 (toggle + amount), MST001 (cohesion toggle only; ceiling and calibration uncontrolled), TUN001 (two pickers); STG003 adds no control |

No orphan or overlapping outcomes: each leaf maps to exactly one increment;
REQ-004/REQ-007 are cross-cutting guardrails bound to executable nodes.

## Validation and feedback

- Determinism: extend `PerformanceTimelinePurityTests` (expression) and the
  offline-render byte-equality suites (staging, master, tuning), including
  note-into-silence programs and two host buffer sizes; refreeze digests
  only from two agreeing runs.
- Export equality: `AudioExportTests`/`OfflineRenderTests` remain the gate
  that live and export stay identical with every feature on and off.
- Bypass: an automated render comparison proving the D65-2 recipe equals
  the raw line sum scaled by one static gain, with no room, phrase-dynamic,
  or cohesion energy signature.
- Loudness/headroom: automated offline checks of true peak ≤ −1 dBFS and
  the loudness proxy across at least two dissimilar library pieces.
- Performance: the existing env-gated REQ-007 guardrail on the pinned
  reference piece with all delivered features on, asserting
  `overloadPauses == 0`.
- Listening: the owner A/Bs each increment on delivery (the definition's
  success measure); taste adjustments stay within each feature's constants.

## Assumptions and open questions

None requiring owner decision. Working assumptions: Apple Silicon baseline
for REQ-007; exact DSP constants, the register statistic, and the loudness
proxy constants are implementer-owned within observable acceptance; the
fresh-preset expression default and stored-preset decode default are
recorded in EXP001 under the clean-slate decision. If listening rejects a
feature's character, that is a constants adjustment or a new product
conversation, not silent scope growth.

## Satisfaction proof

Not applicable — implementation work remains across all four increments.

## Publication verification

Pending publication: after content review, the four GROUP and five LEAF
issues are created from the shared templates with `Planning root: #65` and
`Planning plan: #66`, every `Pending` URL is replaced, TRACKING metadata is
added to #65, and the native sub-issue tree and blocked-by chain are
reconciled and verified via `plan reconcile-graph` / `plan verify-graph`.
