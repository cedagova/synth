# Implementation Plan: Pro-grade playback sound — electronic Bach

- Planning issue: https://github.com/cedagova/synth/issues/49
- Planning PR: https://github.com/cedagova/synth/pull/55
- Status: Ready for implementation
- Root classification: INCREMENTAL
- Delivery topology: INCREMENTAL
- Planner: Claude (implementation-planning-lead)
- Started: 2026-09-06
- Product definition: https://github.com/cedagova/synth/pull/50
- Product definition head: 32e8ce63445e6492cf75b88b35803bb56d92703b
- Requirements brief: https://github.com/cedagova/synth/issues/49#issuecomment-5555006339

## Pinned baselines

| Repository | Baseline |
| --- | --- |
| `cedagova/synth` | `0f22fcd4959148d50720b319d96ffb58964a6084` |

## Preserved objective and boundaries

From the reviewed definition (PR #50 @ 32e8ce6): pressing Play produces a
rendition the owner would voluntarily listen to end to end — staged in a
shared space (REQ-001/002), expressively phrased by deterministic
score-derived rules (REQ-003/004), summed through a produced master
(REQ-005), with an optional historical tuning choice (REQ-006), all without
overload pauses on the pinned reference piece (REQ-007, BWV 1046 import,
content SHA-256 prefix `8c3c7097412b5cfc`).

Owner decisions preserved verbatim: D4 revised — bounded deterministic
score-derived expression allowed, AI/ML excluded; pre-release clean slate —
no preset migration promises; tuning outcome included. Non-goals preserved:
no per-note editing surface, no visualization, no plugin hosting, no new
sample content. Inviolable guardrails: same piece + preset + settings →
identical audio (AD5), and export byte-equals live playback (REQ-026
lineage).

## Classification

- ROOT #49: `INCREMENTAL`. The four native product outcomes are each a real,
  independently deliverable listening improvement with its own bypass and
  acceptance; flattening them into one run would erase those delivery
  boundaries, and later increments consume listening evidence from earlier
  ones (the definition's declared taste uncertainty: how wide/wet staging
  should be calibrates expression and master defaults). The root becomes
  tracking-only.
- #51 Staged by default: `GROUP`, increment 001, two ordered leaves.
- #52 Expressive interpretation: `GROUP`, increment 002, two ordered leaves.
- #53 Produced master: `GROUP`, increment 003, one leaf.
- #54 Historical tuning color: `GROUP`, increment 004, one leaf.

No increment is deferred: pinned evidence supports planning all four now.
The sequence is a strict total order (001→004); each later increment is
natively blocked by its immediate predecessor.

## Current-state evidence

Pinned at `cedagova/synth@0f22fcd`:

- Fresh presets are dry/centred/unity: `PresetAutoAssignment.initialContent`
  emits `LineMixerState.neutral` (volume 1, pan 0, roomSend 0).
- A shared stereo Schroeder room (`SYNTH_ROOM_*` combs/allpasses in
  `SynthAudioCore.c`) exists with a per-line `roomSend` that defaults to 0;
  per-line gain/pan/mute/solo are atomic live-settable (`LineMixer`).
- Realization is a pure function of (piece, preset id, humanization):
  `PerformanceRealizer` + `RealizationSettings`; determinism is enforced by
  `PerformanceTimelinePurityTests` frozen digests and export equality by
  `OfflineRenderTests`/`AudioExportTests`.
- Expression today: uniform seeded jitter (`SeededJitter`,
  `PerformanceHumanization`) + written notation (dynamics, articulation
  velocity deltas, ornaments, fermatas). Humanization is a preset-stored
  setting with an established additive-document precedent
  (`PresetContent.humanization`, decode-if-present at version 1).
- Master bus is gain-only (`synth_engine_master_gain`); the render core
  already counts overload blocks/pauses (`overloadBlocks`,
  `overloadPauses`) for REQ-007 measurement.
- Tuning is fixed equal temperament A=440 in both voice engines
  (`SynthPatchEngine.c`, `SampleVoiceEngine.c` frequency derivation).
- The engine renders offline and live through one graph
  (`PlaybackEngine.renderTimelineOffline`), which is what makes
  "live == export by construction" available to the master and calibration
  work.

## Selected implementation direction

System-level HOW, per increment:

1. **Staging (001).** Give the render core a per-line *depth* dimension
   (room send plus a bounded near/far cue such as per-line room pre-delay /
   early-reflection balance — exact DSP the implementer's choice within the
   room's existing architecture), then derive staging defaults at preset
   auto-creation from score order: a seating pan curve across parts,
   register-aware placement, non-zero room sends, gentle level shading.
   Staged values are ordinary `LineMixerState` values (additive fields where
   needed) — visible and editable in the existing mixer, stored in the
   preset like any other custom value.
2. **Expression (002).** Extend `RealizationSettings` with a preset-stored
   expression setting (on for fresh presets). Inside the realizer — keeping
   realization a pure function — derive: phrase segmentation from the score
   (slurs, rests, cadential motion), phrase-shaped dynamics, cadence/phrase-
   end breathing (bounded local timing), articulation defaults
   (legato under slurs, detaché otherwise, honoring written articulations),
   and melody/accompaniment balance per passage. Off must satisfy REQ-004's
   bypass recipe exactly.
3. **Master (003).** Add a bypassable master stage after the line sum in the
   render core: gentle bus cohesion plus a true-peak-safe limiter with
   ≤ −1 dBFS ceiling, and a deterministic per-piece loudness calibration
   computed once per program from a bounded offline analysis pass at load,
   applied identically live and in export (one graph). The loudness proxy is
   a windowed-RMS integrated measure with a fixed target; exact constants
   are the implementer's within REQ-005's observable bounds.
4. **Tuning (004).** Thread a per-program tuning table (12 pitch-class
   offsets + reference A frequency) through both voice engines; ship equal
   temperament (default), Werckmeister III, and A=440/415 as a preset-stored
   setting beside humanization/expression, applied to live and export alike.

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
- **AD-P4 — no new bundled audio assets.** The staging room builds on the
  existing algorithmic reverb (no impulse responses), keeping the
  definition's licensing/privacy posture untouched.
- **AD-P5 — calibration is a bounded, deterministic pre-pass** at program
  build (offline analysis of the realized timeline), never a live adaptive
  process, so identical inputs keep producing identical audio.

## Execution graph and waves

Strict increment order — each wave is one increment, merged, verified, and
closed before the next starts:

| Wave | Increment | Leaves (ordered) |
| --- | --- | --- |
| 1 | 001 #51 staging | STG001 engine depth → STG002 staging defaults + preset/mixer |
| 2 | 002 #52 expression | EXP001 phrase dynamics/breathing + setting/bypass → EXP002 articulation + line balance |
| 3 | 003 #53 master | MST001 master stage + calibration |
| 4 | 004 #54 tuning | TUN001 temperament + reference pitch |

Rationale for the order: staging first because every later listening
judgment happens on a staged mix; expression second as the core musical
gap; master third so its calibration targets real (staged, expressive)
levels; tuning last as an isolated, lowest-risk color feature.

## Interfaces and ownership

Single repository (`cedagova/synth`); all interfaces are internal contracts:

- `LineMixerState`/`PresetContent` (SynthKit) own staged and setting
  storage; additive Codable fields.
- `RealizationSettings` → `PerformanceRealizer` (SynthKit) own expression;
  the timeline remains the only carrier of expressive decisions.
- The C render core (`SynthAudioCore`) owns depth, master stage, and tuning
  table application; Swift owns their configuration and persistence.
- The A/B bypass contract (REQ-004) spans increments: each increment's off
  state must compose so the full bypass recipe renders notation + uniform
  humanization only.

## Risks and rabbit holes

- **Taste is unbounded.** Guard: defaults are constants in one place per
  feature, judged against the definition's observable acceptance; no
  parameter-surface expansion beyond the defined settings (D4 boundary).
- **DSP determinism.** New float paths (depth, master, tuning) must render
  identically across runs and buffer sizes; the existing purity/equality
  harnesses are the gate and get extended per increment, with frozen
  digests refrozen deliberately (two agreeing runs) when realization
  changes.
- **Overload headroom (REQ-007).** Each increment's completion includes a
  full playthrough of the pinned reference piece without overload pause;
  the added DSP must fit the existing real-time budget on Apple Silicon.
- **Loudness rabbit hole.** No standards-lab loudness implementation; the
  bounded windowed-RMS proxy with a fixed target satisfies REQ-005's
  "comparable loudness" without importing a metering suite.
- **Sampled-instrument interaction.** Tuning must apply to sample playback
  (rate adjustment) as well as synthesis; acceptance covers both engine
  kinds.

## Migration, rollout, recovery, and rollback

Pre-release clean slate (owner decision): no data migration; preset fields
are additive with defaults. Rollout is per-increment on `main`, each leaving
the app working (increment completion rule). Recovery/rollback: every
feature has an off state that restores REQ-004's bypass character, and any
increment can be reverted independently since later increments only consume
— never rewrite — earlier ones' stored values.

## Issue publication manifest

| Key | Kind | Parent | Repository | Title | Delivery | Blocked by | Issue |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ROOT | TRACKING | None | cedagova/synth | Pro-grade playback sound — electronic Bach | INCREMENTAL | None | https://github.com/cedagova/synth/issues/49 |
| INC001 | GROUP | ROOT | cedagova/synth | Staged by default: seating, depth, and a shared room | COLLECTOR | None | https://github.com/cedagova/synth/issues/51 |
| INC002 | GROUP | ROOT | cedagova/synth | Expressive interpretation: deterministic phrasing, articulation, and line balance | COLLECTOR | INC001 | https://github.com/cedagova/synth/issues/52 |
| INC003 | GROUP | ROOT | cedagova/synth | Produced master: cohesion, loudness, and headroom | DIRECT | INC002 | https://github.com/cedagova/synth/issues/53 |
| INC004 | GROUP | ROOT | cedagova/synth | Historical tuning color: well temperament and baroque pitch | DIRECT | INC003 | https://github.com/cedagova/synth/issues/54 |
| STG001 | LEAF | INC001 | cedagova/synth | Per-line depth in the render core: near/far placement into the shared room | None | None | https://github.com/cedagova/synth/issues/56 |
| STG002 | LEAF | INC001 | cedagova/synth | Staging defaults at preset creation: seating, sends, and mixer exposure | None | STG001 | https://github.com/cedagova/synth/issues/57 |
| EXP001 | LEAF | INC002 | cedagova/synth | Deterministic phrase expression: shaped dynamics, cadence breathing, setting and bypass | None | None | https://github.com/cedagova/synth/issues/58 |
| EXP002 | LEAF | INC002 | cedagova/synth | Articulation defaults and melody/accompaniment balance | None | EXP001 | https://github.com/cedagova/synth/issues/59 |
| MST001 | LEAF | INC003 | cedagova/synth | Master stage: bus cohesion, true-peak ceiling, deterministic loudness calibration | None | None | https://github.com/cedagova/synth/issues/60 |
| TUN001 | LEAF | INC004 | cedagova/synth | Temperament and reference pitch through both voice engines | None | None | https://github.com/cedagova/synth/issues/61 |

## Acceptance coverage

| Definition requirement | Covered by |
| --- | --- |
| REQ-001 staging default | STG001, STG002 |
| REQ-002 preset ownership of staging | STG002 |
| REQ-003 deterministic expression | EXP001, EXP002 |
| REQ-004 honest bypass | EXP001 (recipe owner); the composed off-state check is an explicit acceptance line on the final leaf of every increment (STG002, EXP002, MST001, TUN001) and verbatim in each increment's completion rule |
| REQ-005 master headroom/loudness | MST001 |
| REQ-006 tuning choice | TUN001 |
| REQ-007 reference-piece performance | Explicit acceptance line on the final leaf of every increment (STG002, EXP002, MST001, TUN001): full playthrough of the pinned reference piece with all features delivered so far on, `overloadPauses == 0`; also verbatim in each increment's completion rule |

No orphan or overlapping outcomes: each leaf maps to exactly one increment;
REQ-004/REQ-007 are cross-cutting guardrails bound to executable nodes —
the final leaf of each increment carries their automated checks, and each
increment GROUP states them verbatim in its completion rule.

## Validation and feedback

- Determinism: extend `PerformanceTimelinePurityTests` (expression) and the
  offline-render byte-equality suites (staging/master/tuning); refreeze
  digests only from two agreeing runs.
- Export equality: `AudioExportTests`/`OfflineRenderTests` remain the gate
  that live and export stay identical with every feature on and off.
- Bypass: an automated render comparison proving the REQ-004 recipe
  contains no room, master, or phrase-dynamic energy signatures.
- Loudness/headroom: automated offline checks of true peak ≤ −1 dBFS and
  the loudness proxy across at least two dissimilar library pieces.
- Performance: scripted full playthrough of the pinned reference piece with
  all features on, asserting `overloadPauses == 0` via the engine's
  existing telemetry.
- Listening: the owner A/Bs each increment on delivery (the definition's
  success measure); taste adjustments stay within each feature's constants.

## Assumptions and open questions

None requiring owner decision. Working assumptions: Apple Silicon baseline
for REQ-007; the algorithmic room is a sufficient space (AD-P4) — if
listening rejects it, that is a new product conversation, not silent scope
growth; exact DSP constants are implementer-owned within observable
acceptance.

## Satisfaction proof

Not applicable — implementation work remains across all four increments.

## Publication verification

- Leaves published: #56 (STG001), #57 (STG002), #58 (EXP001), #59
  (EXP002), #60 (MST001), #61 (TUN001); all `Pending` URLs replaced.
- Increment GROUP metadata (sequence 001–004, delivery, completion rules
  binding REQ-004/REQ-007) on #51–#54; TRACKING metadata on #49.
- Native sub-issue tree and blocked-by chain reconciled and verified via
  `plan reconcile-graph` / `plan verify-graph`.
- Deterministic validation on the final head; exact-head independent
  approval in the native PR review.
