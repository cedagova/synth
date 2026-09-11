# Implementation Plan: Future sound improvements: expression, master, tuning

- Planning issue: https://github.com/cedagova/synth/issues/65
- Planning PR: https://github.com/cedagova/synth/pull/66
- Status: Ready for implementation
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

Preserved requirements, quoted in full from the definition:

- **REQ-003 (deterministic expression):** with expression on, dynamics vary
  over phrases and cadences beyond written dynamics; two renders of the
  same piece+preset are byte-identical; export equals live playback.
- **REQ-004 (honest bypass):** expression off + staging neutral + tuning
  at default + mastering off renders with only written notation plus
  uniform humanization — audibly free of phrase dynamics, room, and master
  processing — and deterministically (REQ-003). No bit-comparison against
  pre-delivery builds is promised.
- **REQ-005 (master headroom):** no export clips (true peak ≤ −1 dBFS) and
  quiet pieces are not exported inaudibly low; two different pieces export
  at comparable perceived loudness.
- **REQ-006 (tuning):** a preset can select equal temperament (default),
  at least one well temperament, and A=440 vs A=415; the choice audibly
  changes intonation color, is stored in the preset, and applies to
  export.
- **REQ-007 (performance):** the reference piece — the owner's 12-line
  Brandenburg Concerto No. 1 import (BWV 1046, MusicXML content SHA-256
  prefix `8c3c7097412b5cfc`) — plays start to end on the baseline machine
  without an overload pause with all features on.
- REQ-001 and REQ-002 (staging default, preset ownership) were delivered
  by #51/#57 (PR #62, merge 7189d2d) and are out of scope here, except for
  the two refinements deferred from #57 by recorded decision (PR #64
  reconciliation): register-aware placement, and gentle level shading.
  The definition's seating assumption stands: "bass-register lines nearer
  centre-right".

Owner decisions preserved verbatim from the definition (2026-09-05): D4
revised — bounded deterministic score-derived expression allowed, AI/ML and
per-performer emulation excluded; clean slate for stored presets — "new
defaults may apply to existing presets and no migration or upgrade
affordance is required"; OUT004 tuning included. Definition non-goals
preserved: no per-note editing surface, no visualization, no plugin
hosting, no new sample content, no microtonal score support, no
user-defined temperaments. Inviolable guardrails: same piece + preset +
settings → identical audio (AD5), and export byte-equals live playback.
Success measure preserved: the owner keeps expression/staging on for their
library and listens end to end.

### Owner decisions recorded in this planning run

| Date | Decision | Rationale | Affects |
| --- | --- | --- | --- |
| 2026-09-10 | **D65-1 Control surface.** Mechanisms are core; the owner-facing surface is small and preset-stored: expression on/off + one amount; one produced-master on/off (see D65-2); a temperament picker; a reference-pitch picker. The true-peak ceiling has no control. Articulation defaults and register-aware placement have no control (placement lands as ordinary staged mixer values the existing mixer overrides). Taste constants stay code-only and centralized. Owner reply to the lead's recommended split: "ok". | The app is a player, not a mixing console; every knob is a taste surface the owner would have to learn. Clipping safety is correctness, not taste. | EXP001, MST001, TUN001, STG003 |
| 2026-09-10 | **D65-2 Master surface versus REQ-004: option A.** One preset "Produced master" switch covers bus cohesion and loudness calibration together, on for fresh presets. The true-peak ceiling is always on and bit-transparent below −1 dBTP. REQ-004 is preserved literally for everything but the ceiling, which acts only when the raw sum would clip; the composed bypass check asserts bit-identity to the raw line sum whenever it is under the ceiling. Owner reply: "all as recommended" to the brief offering A (this), B (calibration always on, REQ-004 re-read as cohesion off) and C (ceiling switchable too, exports may clip). | Keeps the approved acceptance clause intact with one switch; REQ-005's clip guarantee holds in every state and its loudness guarantee in the default state; fully reversible. | MST001 acceptance; the composed bypass line on STG003, EXP002, MST001, TUN001; AD-P6 |
| 2026-09-10 | **D65-3 Existing library: option A.** Stored presets that lack the new fields decode with expression on (default amount) and produced master on. Existing staged mixer values are left untouched: register-aware seating applies to newly created presets and reconcile-added lines only; the owner re-creates a preset to get the new seating. Owner reply: "all as recommended" to the brief offering A (this), B (new pieces only) and C (also re-seat untouched strips). | Every existing piece gains expression and master on next open, meeting the success measure, while owner mixer edits are never overwritten; permitted by the clean-slate decision. | EXP001 and MST001 default lines; STG003 scope; migration section |

Planner decisions (ordinary, reversible, recorded for the reviewer):

- **P65-1 Increment order** inherited from the reviewed #49 plan (staging
  refinement → expression → master → tuning) for the same reasons: every
  later listening judgment happens on the final staged mix; master
  calibration must target real staged, expressive levels; tuning is the
  isolated, lowest-risk color. Splitting the ceiling out as an earlier
  safety leaf was offered to the owner in the thread and not taken.
- **P65-2 Level shading** is not a separate staging item: the PR #64
  reconciliation stands — per-passage balance belongs to expression
  (EXP002) and loudness to the master (MST001).
- **P65-3 Fresh successor issues** are published under #65; the closed
  `NOT_PLANNED` nodes #52–#54 and #58–#61 keep their `Planning root: #49`
  provenance and are cited, not rewritten. The published leaves inherit
  their closed predecessors' reviewed acceptance, constraint, and failure
  lines verbatim (EXP001 ← #58, EXP002 ← #59, MST001 ← #60, TUN001 ← #61)
  and carry only the deltas this plan states.
- **P65-4 Tuning composition.** The per-program tuning table is applied at
  note-on frequency derivation as a per-note ratio (pitch-class offset in
  cents plus the reference ratio 415/440) in both engines. It composes
  multiplicatively with the existing preset-stored per-instrument
  `InstrumentCustomization.tuningOffsetCents` (a block-level per-voice
  ratio), which is preserved unchanged: neither clamps or replaces the
  other, and no stored field changes shape. Instruments the capability
  model marks unpitched are exempt from the table exactly as they are
  exempt from the offset; REQ-006's "both engine kinds" is read as synth
  patches and pitched sampled instruments, and a mixed ensemble retunes
  its pitched lines only. Reference-pitch shifts are relative to the
  sampled library's recorded standard; libraries recorded at a
  non-440 standard are out of scope.
- **P65-5 Calibration cost bound.** The calibration pre-pass renders a
  bounded, deterministically chosen excerpt set (a fixed cap on analyzed
  program time, excerpts chosen by note density on the realized timeline)
  through the real graph with the resolved voices, so its cost does not
  grow with piece length. The gain is program state: it is recomputed on
  every program rebuild and therefore follows piece, preset, settings, and
  the resolved voice assignment, including a substitute being replaced by
  its downloaded library (which already rebuilds the program). If the
  analysis cannot run, the gain is unity and the existing status reporting
  says so; never silence.
- **P65-6 Settings surface.** EXP001 introduces one "Performance" settings
  group in the playback screen, replacing the single inline humanization
  row: humanization and expression first, with the produced-master row
  (MST001) and the two tuning picker rows (TUN001) added later. Each row keeps the
  humanization precedent (change → re-render → save to preset) and the
  app's accessibility standard. Later leaves add rows only; none
  redesigns the surface.

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

No increment is deferred: pinned evidence supports planning all four now.
The sequence is a strict total order (001→004); each later increment is
natively blocked by its immediate predecessor.

## Current-state evidence

Pinned at `cedagova/synth@d59e561`:

- Staging is a pure function of seat index, part count, and the named
  instrument family: `PresetStaging.mixer(lineIndex:lineCount:family:)`
  returns pan/roomSend/depth with volume 1 everywhere; `PresetAutoAssignment
  .initialContent` and `PresetLibrary.reconcile` take only the
  `LineInventory` (plus the sound palette), which
  carries ids, names, part name, staff, and voice — no pitch information —
  so register-aware placement needs a score-derived register summary
  reaching the derivation. Depth exists in the render core
  (`SYNTH_DEPTH_*`) and the document (`LineMixerState.depth`), and
  `LineMixerState` has five application surfaces that must move together
  (`PresetPerformance.applyMixer`, `PlaybackEngine` carry/restore,
  `AudioExport.applyMixer`, `AssignmentModel.writeStrip`, additive Codable
  decode).
- The PR #64 reconciliation for #57 recorded: the family map is the
  register proxy at that increment's altitude; per-passage line balance
  belongs to expression and loudness to the master, so level shading in
  staging would double-own those surfaces.
- Realization is a pure function of (piece, preset, settings):
  `PerformanceRealizer` + `RealizationSettings`; determinism is guarded by
  `PerformanceTimelinePurityTests` frozen digests and export equality by
  `OfflineRenderTests`/`AudioExportTests`. Expression today is uniform
  seeded jitter (`PerformanceHumanization`, `SeededJitter`) plus written
  notation; the compiled score carries slurs, rests, written dynamics and
  articulations (`ScoreLine.notes`, slur start/stop counts,
  `ScoreExpressionEvent`). Humanization is a preset-stored setting
  (`PresetContent.humanization`, additive decode) whose only UI is one
  inline row (`HumanizationBar`: a switch, a 150 pt slider, and a readout
  inside a 420 pt column in `PlaybackScreen`) — there is no room on that
  row for more controls, which is why P65-6 introduces a settings group.
- The master bus is gain-only (`masterGain` atomic in `SynthAudioCore.c`,
  `synth_engine_set_master_gain`); one render graph serves live and
  offline (`PlaybackEngine.renderTimelineOffline`); overload telemetry
  (`overloadBlocks`/`overloadPauses`) exists and is exercised by the
  env-gated REQ-007 guardrail in `RealtimePlaybackTests`
  (`SYNTH_REALTIME_GUARDRAIL=1` + `SYNTH_REFERENCE_PIECE=<path>`); the
  recorded guardrail run for the reference piece is 203.5 s of 12 lines.
- Tuning: the synth engine derives note frequency as equal temperament at
  A=440 (`SynthPatchEngine.c`). The sample engine has no absolute
  reference: playback rate is relative to the region's recorded key
  centre plus region tune plus the sample-rate ratio (`SampleVoiceEngine.c`),
  so a reference-pitch change there is a shift relative to the library's
  recorded standard. A preset-stored per-instrument offset already exists
  (`InstrumentCustomization.tuningOffsetCents`, ±100 cents, applied as one
  block-level per-voice ratio) and is capability-gated: unpitched
  instruments cannot be retuned and their offset is zeroed
  (`InstrumentCapability`).
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
   lines keep their score-order seat; lines with too few pitches to
   summarize get no bias (the family proxy alone). Values remain ordinary
   staged `LineMixerState` values written at preset creation and on
   reconcile for added lines, editable in the existing mixer, with no new
   control. Existing presets are not re-seated (D65-3).
2. **Expression (002).** Extend `RealizationSettings` with a preset-stored
   expression setting (enabled + amount). Inside the realizer — keeping
   realization a pure function — derive phrase segmentation from the score
   (slurs, rests, cadential motion), phrase-shaped dynamics, cadence/
   phrase-end breathing (bounded local timing that never breaks the
   transport readout's measure alignment), articulation defaults (legato
   under slurs, detaché otherwise, honoring written articulations; always
   on), and melody/accompaniment balance per passage (rides the amount;
   ambiguous melody detection falls back to no balancing). Off must
   satisfy REQ-004's bypass recipe exactly. EXP001 introduces the
   Performance settings group (P65-6) with the expression toggle and
   amount beside humanization. Expression is on for fresh presets and
   for stored presets that lack the field (D65-3).
3. **Master (003).** Add a master stage after the line sum in the render
   core: a true-peak-safe ceiling at ≤ −1 dBFS, a deterministic per-piece
   loudness calibration gain computed once per program from the bounded
   excerpt analysis of P65-5 (AD-P5; windowed-RMS integrated proxy with a
   fixed target), and a bus-cohesion block; all applied identically live
   and in export (one graph), with no allocation or locking on the render
   thread, and a silent piece calibrating to unity. One preset-stored
   "Produced master" switch (on for fresh and for stored presets lacking
   it, D65-3) covers cohesion and calibration together; the ceiling is
   always on and bit-transparent below −1 dBTP (D65-2). Master off is
   bit-identical to the raw line sum whenever that sum stays under the
   ceiling. Acceptance for REQ-005's "comparable
   loudness": two dissimilar library pieces export within ±2 dB of the
   fixed target on the proxy.
4. **Tuning (004).** Thread a per-program tuning table (12 pitch-class
   offsets + reference A frequency) through both voice engines at note-on
   under the composition rule P65-4; ship equal temperament (default),
   Werckmeister III, and A=440/415 as preset-stored settings with two
   picker rows in the Performance group, applied to live and export alike.
   Default tuning renders bit-identical to pre-feature output; an unknown
   stored temperament decodes to equal temperament with the standard
   failure reporting, never silence or a crash.

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
  build (P65-5 excerpt analysis of the realized program through the real
  graph), never a live adaptive process, so identical inputs keep
  producing identical audio, and its cost is capped independent of piece
  length.
- **AD-P6 — safety is core, color is optional.** The ceiling has no owner
  control; the produced master (cohesion + calibration), expression, and
  tuning do (D65-1, D65-2). Every optional setting is preset-stored with the humanization
  precedent's change → re-render → save behavior and app-standard
  accessibility, in the one Performance settings group (P65-6).
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
| 2 | 002 expression | EXP001 phrase dynamics/breathing + setting/bypass + settings group → EXP002 articulation + line balance |
| 3 | 003 master | MST001 ceiling + calibration + cohesion |
| 4 | 004 tuning | TUN001 temperament + reference pitch |

Order rationale: P65-1.

## Interfaces and ownership

Single repository (`cedagova/synth`); all interfaces are internal contracts:

- `PresetStaging` / `PresetAutoAssignment` (SynthKit) own staging
  derivation; the compiled score owns the register summary input; the
  `LineMixerState` five-surface rule applies to any additive strip field.
- `RealizationSettings` → `PerformanceRealizer` (SynthKit) own expression;
  the timeline remains the only carrier of expressive decisions.
- The app's playback screen owns the Performance settings group (P65-6):
  EXP001 introduces it (humanization + expression rows); MST001 adds the
  master row; TUN001 adds the temperament and reference-pitch rows.
- The C render core (`SynthAudioCore`) owns the master stage and the
  tuning-table application in both voice engines under P65-4; SynthKit
  owns the calibration pre-pass (P65-5), tuning tables, settings, and
  persistence.
- The A/B bypass contract (REQ-004, preserved under D65-2) spans
  increments: each increment's off state must compose so the full recipe
  renders notation + uniform humanization only — bit-identical to the raw
  line sum whenever it is under the ceiling — with the automated check
  stated in Validation.

## Risks and rabbit holes

- **Taste is unbounded.** Guard: defaults are constants in one place per
  feature, judged against observable acceptance and the owner's listening
  A/B; no parameter-surface expansion beyond D65-1.
- **DSP determinism.** New float paths (master, tuning) must render
  identically across runs and host buffer sizes, including after silence
  (per-sample denormal flush, state cleared on relocate); the existing
  purity/equality harnesses are the gate and get extended per increment,
  with frozen digests refrozen deliberately (two agreeing runs).
- **Calibration cost.** Guard: P65-5 caps analyzed time; acceptance pins
  added time-to-first-Play on the reference piece (Validation).
- **Overload headroom (REQ-007).** Each increment's completion includes a
  full playthrough of the pinned reference piece without overload pause;
  the added DSP must fit the existing real-time budget on Apple Silicon.
- **Loudness rabbit hole (plan's own guard, not a definition non-goal).**
  No standards-lab loudness implementation; the bounded windowed-RMS proxy
  with a fixed target and the ±2 dB tolerance satisfies REQ-005 without
  importing a metering suite.
- **Sampled-instrument interaction.** Tuning must apply to sample playback
  (rate adjustment) as well as synthesis; acceptance covers both engine
  kinds under P65-4; keyswitch and velocity-layer behavior is unchanged
  apart from pitch.

## Migration, rollout, recovery, and rollback

Pre-release clean slate (owner decision): no data migration; preset fields
are additive. Stored presets lacking the new fields decode with expression
on and produced master on; their mixer values are untouched (D65-3).
Rollout is per-increment on `main`, each leaving the app working
(increment completion rule). Recovery/rollback: every optional feature has
an off state that restores the REQ-004 bypass character (D65-2); the
ceiling is transparent for material under −1 dBTP; calibration is unity
on failure;
any increment can be reverted independently since later increments only
consume — never rewrite — earlier ones' stored values.

## Issue publication manifest

| Key | Kind | Parent | Repository | Title | Delivery | Blocked by | Issue |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ROOT | TRACKING | None | cedagova/synth | Future sound improvements: expression, master, tuning — reviewed research and development lessons | INCREMENTAL | None | https://github.com/cedagova/synth/issues/65 |
| INC001 | GROUP | ROOT | cedagova/synth | Register-aware seating: staging placement by line register | DIRECT | None | https://github.com/cedagova/synth/issues/67 |
| INC002 | GROUP | ROOT | cedagova/synth | Expressive interpretation: deterministic phrasing, articulation, and line balance | COLLECTOR | INC001 | https://github.com/cedagova/synth/issues/68 |
| INC003 | GROUP | ROOT | cedagova/synth | Produced master: ceiling, loudness calibration, and cohesion | DIRECT | INC002 | https://github.com/cedagova/synth/issues/69 |
| INC004 | GROUP | ROOT | cedagova/synth | Historical tuning color: well temperament and baroque pitch | DIRECT | INC003 | https://github.com/cedagova/synth/issues/70 |
| STG003 | LEAF | INC001 | cedagova/synth | Register-aware placement at preset creation | None | None | https://github.com/cedagova/synth/issues/71 |
| EXP001 | LEAF | INC002 | cedagova/synth | Deterministic phrase expression: shaped dynamics, cadence breathing, setting, bypass, and the Performance settings group | None | None | https://github.com/cedagova/synth/issues/72 |
| EXP002 | LEAF | INC002 | cedagova/synth | Articulation defaults and melody/accompaniment balance | None | EXP001 | https://github.com/cedagova/synth/issues/73 |
| MST001 | LEAF | INC003 | cedagova/synth | Master stage: true-peak ceiling, deterministic loudness calibration, bus cohesion | None | None | https://github.com/cedagova/synth/issues/74 |
| TUN001 | LEAF | INC004 | cedagova/synth | Temperament and reference pitch through both voice engines | None | None | https://github.com/cedagova/synth/issues/75 |

## Acceptance coverage

| Preserved requirement | Covered by |
| --- | --- |
| REQ-001 / REQ-002 | Delivered by #51/#57 (PR #62, merge 7189d2d); out of scope, not dropped |
| Register-aware placement (deferred from #57) | STG003. Acceptance: for a fresh ≥4-line piece whose lowest-register part is not last in score order, that line's staged pan is right of centre and its depth exceeds the treble lines'; a piece whose lines all share one register stages byte-identically to today's derivation; lines with too few pitches get the family-only result; derivation is deterministic (same score → same preset content) in the shape `PresetStagingTests` already uses |
| Gentle level shading (deferred from #57) | EXP002 per-passage balance and MST001 loudness, honoring both halves of the #64 decision; no separate static shading |
| REQ-003 deterministic expression | EXP001, EXP002 |
| REQ-004 honest bypass (preserved; ceiling excepted per D65-2) | EXP001 (recipe owner); the composed off-state check is an explicit acceptance line on the final leaf of every increment (STG003, EXP002, MST001, TUN001) and verbatim in each increment's completion rule |
| REQ-005 master headroom/loudness | MST001 (true peak ≤ −1 dBFS on every export in every state; with the produced master on — the default — ±2 dB proxy tolerance across two dissimilar pieces and a quiet piece not inaudibly low) |
| REQ-006 tuning choice | TUN001 under P65-4 |
| REQ-007 reference-piece performance | Explicit acceptance line on the final leaf of every increment (STG003, EXP002, MST001, TUN001): full playthrough of the pinned reference piece with all features delivered so far on, `overloadPauses == 0`; also verbatim in each increment's completion rule |
| Calibration cost (P65-5) | MST001: program build for the reference piece adds no more than 1.0 s of time-to-first-Play on the baseline machine, measured |
| D65-1 control surface | EXP001 (toggle + amount, settings group), MST001 (one master row; ceiling uncontrolled), TUN001 (two picker rows); STG003 adds no control |

No orphan or overlapping outcomes: each leaf maps to exactly one increment;
REQ-004/REQ-007 are cross-cutting guardrails bound to executable nodes.

## Validation and feedback

- Determinism: extend `PerformanceTimelinePurityTests` (expression) and the
  offline-render byte-equality suites (staging, master, tuning), including
  note-into-silence programs and two host buffer sizes; refreeze digests
  only from two agreeing runs.
- Export equality: `AudioExportTests`/`OfflineRenderTests` remain the gate
  that live and export stay identical with every feature on and off.
- Bypass: an automated render comparison proving the REQ-004 recipe is
  bit-identical to the raw line sum whenever that sum is under −1 dBTP
  (D65-2), with no room, phrase-dynamic, master, or tuning signature.
- Loudness/headroom: automated offline checks of true peak ≤ −1 dBFS and
  the ±2 dB proxy tolerance across at least two dissimilar library pieces;
  a silent program calibrates to unity.
- Calibration cost: measured time-to-first-Play delta on the reference
  piece, ≤ 1.0 s.
- Tuning: per-pitch-class frequency assertions on both engine kinds, with
  and without a per-instrument offset (P65-4 composition); default tuning
  bit-identical to pre-feature output.
- Performance: the existing env-gated REQ-007 guardrail on the pinned
  reference piece with all delivered features on, asserting
  `overloadPauses == 0`.
- Listening: the owner A/Bs each increment on delivery (the definition's
  success measure); taste adjustments stay within each feature's constants.

## Assumptions and open questions

Working assumptions: Apple Silicon baseline for REQ-007; exact DSP
constants, the register statistic, the excerpt-selection rule, and the
loudness proxy target are implementer-owned within the observable
acceptance above. If listening rejects a feature's character, that is a
constants adjustment or a new product conversation, not silent scope
growth.

None requiring owner decision. The Owner decision brief for D65-2
(master surface versus REQ-004) and D65-3 (existing library) was presented
in the owner thread on 2026-09-10 with options A/B/C each; the owner chose
both recommended options ("all as recommended"), recorded in the decision
table above.

## Satisfaction proof

Not applicable — implementation work remains across all four increments.

## Publication verification

- Published 2026-09-10 under `Planning root: #65` / `Planning plan: #66`:
  GROUP increments #67 (001, DIRECT), #68 (002, COLLECTOR), #69 (003,
  DIRECT), #70 (004, DIRECT); LEAF issues #71 (STG003), #72 (EXP001), #73
  (EXP002), #74 (MST001), #75 (TUN001). All `Pending` URLs replaced.
- Provenance carried into bodies: INC001/STG003 ← #57 and the PR #64
  reconciliation; INC002/EXP001/EXP002 ← #52/#58/#59; INC003/MST001 ←
  #53/#60; INC004/TUN001 ← #54/#61. Published leaves inherit the closed
  predecessors' reviewed lines verbatim (P65-3).
- TRACKING metadata (`Planning kind: TRACKING`, `Implementation execution:
  INCREMENTAL`, increment map, completion rule) appended to #65 without
  altering its research record.
- Native sub-issue tree and blocked-by chain (#68 ← #67, #69 ← #68,
  #70 ← #69, #73 ← #72) reconciled and verified via `plan reconcile-graph`
  / `plan verify-graph`; deterministic validation on the final head.
  Exact-head independent approval remains in the native PR review.
