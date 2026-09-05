# Product Definition: Pro-grade playback sound — electronic Bach

- Product definition issue: https://github.com/cedagova/synth/issues/49
- Product definition PR: https://github.com/cedagova/synth/pull/50
- Requirements brief: Pending
- Status: Under review
- Classification: DECOMPOSE
- Definition lead: Claude (product-definition-lead)
- Started: 2026-09-05

## Pinned evidence baselines

| Repository | Baseline |
| --- | --- |
| `cedagova/synth` | `8d77ddc84a0189016f0f675c32f7182f03adfdea` |

## Objective

Playback already works well mechanically, but a rendition still sounds like
"nice digital sounds" rather than a produced performance the owner would
enjoy listening to for its own sake. The supplied reference feeling is an
"electronic Bach": faithful to the score, unmistakably electronic, and yet
musical enough to be listened to as a record. Define the product outcome
that closes that gap.

## User or operator need

The owner imports their own MusicXML scores and listens to them — not to
check that notes are right, but to enjoy the piece. Today the first play of
a fresh piece is every line dry, centred, at equal level, with uniform
timing/velocity jitter as the only expression. That is audibly a "MIDI
demo", not a performance. The need: pressing Play should produce something
the owner would voluntarily listen to end to end, and export should produce
something they would keep.

## Actors and context

- **The owner** (solo user): imports pieces, assigns sounds, presses Play,
  exports WAV/AIFF. No other actors. All local, offline; no telemetry.
- **Trigger:** opening any piece — especially a freshly imported one whose
  preset was auto-created — and exporting a finished mix.

## Desired outcomes

Four independently meaningful product outcomes (see graph):

1. **OUT001 — Staged by default.** A piece opens sounding like an ensemble
   placed in a shared space: each line has a position (left–right seating),
   depth, and a common room, instead of dry centred mono lines. The staging
   is a starting point the owner can override per line, exactly like
   today's mixer values, and it is stored in the preset like any other
   custom value.
2. **OUT002 — Expressive interpretation.** Deterministic, score-derived
   expression beyond uniform jitter: phrases have dynamic shape, cadences
   and phrase ends breathe, lines articulate (legato/detaché) according to
   what is written, and the musically leading line reads slightly above the
   accompaniment. Same piece + same settings still always renders the same
   audio.
3. **OUT003 — Produced master.** The summed output holds together like a
   produced track: consistent perceived loudness across pieces, gentle
   cohesion on the mix bus, guaranteed headroom (no clipping, no
   inaudible-quiet exports), identical between live playback and export.
4. **OUT004 — Historical tuning color.** An optional per-preset tuning
   choice: equal temperament (default), at least one Bach-appropriate well
   temperament (e.g. Werckmeister III), and baroque pitch A=415 as a
   reference-pitch option — the key-color dimension listeners of baroque
   repertoire recognize.

## Product behavior and flows

- **First open of a new piece:** the auto-created preset arrives staged
  (OUT001) and plays with expression (OUT002) and mastering (OUT003) without any
  owner action. The owner hears a produced rendition on the first Play.
- **Existing presets:** no migration promise. The app is pre-release and
  the owner has declared a clean slate acceptable: new defaults may apply
  to all presets, and no upgrade affordance is required.
- **Override flow:** every staged value (pan, depth/room, level) remains an
  ordinary per-line mixer value — visible, editable, and saved in the
  preset. Expression and tuning are preset-level settings alongside
  humanization, with the same "changes re-render, then save to the preset"
  behavior humanization has today.
- **Export flow:** unchanged surface; the exported file equals live
  playback byte-for-byte, including all of the above.
- **A/B flow:** the owner can turn each of expression (OUT002) and mastering
  (OUT003) off to hear the difference — an off state is honest (bypassed, not
  merely reduced).

## States and failure behavior

- **Missing instrument:** unchanged (existing silent-line flagging and
  substitution acknowledgment flows are untouched).
- **Engine overload:** the added processing must not push the reference
  piece (the 12-line BWV 1046) into the existing overload-pause behavior on
  the supported hardware baseline; if a piece does overload, the existing
  visible pause-with-reason behavior remains the failure mode.
- **Off states:** with expression off, staging neutral, tuning at its
  default, and mastering off, rendering uses only written notation plus
  uniform humanization — no phrase dynamics, room, or master processing —
  and remains deterministic per REQ-003. No bit-comparison against
  pre-delivery builds is promised.

## Requirements and acceptance

- **REQ-001 (staging default):** a freshly imported multi-line piece plays
  with audibly distinct line positions and a shared room on first Play.
  *Acceptance:* open a new ≥4-line piece; lines are not all centred; muting
  the room audibly dries the sound; the values show in the mixer.
- **REQ-002 (preset ownership):** staging values live in the preset;
  editing and saving behaves exactly like today's volume/pan edits. No
  compatibility or migration behavior is required for presets saved before
  delivery (owner decision, 2026-09-05).
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
- **REQ-006 (tuning):** a preset can select equal temperament (default), at
  least one well temperament, and A=440 vs A=415; the choice audibly
  changes intonation color, is stored in the preset, and applies to export.
- **REQ-007 (performance):** the reference piece — the owner's 12-line
  Brandenburg Concerto No. 1 import (BWV 1046, MusicXML content SHA-256
  prefix `8c3c7097412b5cfc`) — plays start to end on the baseline machine
  without an overload pause with all features on.

## Accessibility and content

New controls follow the app's existing standard: every control focusable,
labeled, and hinted; state changes announced via the existing status
mechanisms. No new content types.

## Privacy, security, and policy

No change: everything renders locally; no network use beyond the existing
explicit instrument downloads; no telemetry. Third-party audio material
(e.g. impulse responses, if any are shipped) must carry licenses compatible
with the app's existing open-license policy for bundled assets.

## Success measures and guardrails

- **Success:** the owner, A/B-ing a familiar piece at the pinned baseline
  vs. the delivered outcome, chooses the new rendition for listening — and
  keeps expression/staging on for their library.
- **Guardrails:** determinism (REQ-003) and export-equals-playback are never
  traded away; performance headroom per REQ-007; bypass honesty per REQ-004.

## Constraints and non-goals

- **Constraints:** deterministic rendering (AD5: timeline is a pure
  function of piece + preset + settings) is preserved; local-only; the
  existing one-writer preset model and mixer surface remain the editing
  home for staged values.
- **Non-goals:** no AI/ML interpretation or per-performer emulation; no
  per-note manual editing surface (this is not a DAW); no score or timeline
  visualization; no streaming/sharing features; no new instrument-library
  content production (curated libraries continue as the sample source); no
  real-time effects racks or third-party plugin hosting.

## Evidence

Pinned at `cedagova/synth@8d77ddc`:

- Fresh presets are dry/centred/unity: `PresetAutoAssignment.initialContent`
  uses `LineMixerState.neutral` (pan 0, roomSend 0, volume 1).
- A room bus exists and is per-line sendable but defaults silent:
  `SynthAudioCoreInternal.h` (`SYNTH_ROOM_*`, Schroeder comb/allpass),
  `PlaybackEngine.LineMixer.roomSend` ("Zero — completely dry — until
  something asks otherwise").
- Expression today is uniform seeded jitter plus written notation:
  `PerformanceHumanization`, `SeededJitter`, `PerformanceOrnaments`,
  articulation velocity deltas in `PerformanceLineRealization`. The prior
  definition's D4 scoped the *product surface* to on/off + amount and
  excluded deep interpretation modelling; the implemented behavior is the
  narrower uniform jitter.
- Master bus is gain-only (`synth_engine_master_gain`); no EQ, dynamics, or
  loudness management; export is byte-identical to live playback
  (`OfflineRenderTests`, REQ-026).
- Tuning is fixed equal temperament at A=440 (`440 * pow(2, (n-69)/12)` in
  the engines and `AudioRenderFixtures.frequency`).
- Sampled libraries with velocity layers and round-robin already ship as
  downloads (`SampleVoiceEngine`, curated catalog: 3 libraries, 25
  instruments).

External practice (retrieved 2026-09-05):

- Space (seating pan + shared room with per-line sends + depth) is the
  consistently named first gap between "MIDI demo" and "produced":
  [Sweetwater](https://www.sweetwater.com/insync/how-to-get-realistic-orchestra-sounds-at-home/),
  [MIDI Film Scoring](http://www.midifilmscoring.com/orchestral-reverb/),
  [ModWheel](https://modwheel.net/guides/basics-of-mixing-cinematic-music),
  [KVR panning thread](https://www.kvraudio.com/forum/viewtopic.php?t=326440).
- Expression/phrasing — not patch quality — is what made the canonical
  "electronic Bach" (Carlos, *Switched-On Bach*) musical: contrapuntal
  clarity, per-line phrasing and articulation, varied per-voice timbres:
  [Library of Congress essay](https://www.loc.gov/static/programs/national-recording-preservation-board/documents/Switched-OnBach-Niebur.pdf),
  [wendycarlos.com](https://www.wendycarlos.com/+sob.html).
- Gentle mix-bus cohesion and restraint (one good room, proper panning,
  light glue) over heavy processing:
  [VI-Control master bus thread](https://vi-control.net/community/threads/whats-on-your-master-bus-for-orchestral-cinematic-mockups.95750/),
  [Cinematic Composing](https://www.cinematiccomposing.com/blog/mastering-orchestral-mockups).
- Well temperament (e.g. Werckmeister III) and A=415 are recognized
  authenticity color for Bach keyboard/ensemble repertoire:
  [Kyle Gann, historical tunings](https://www.kylegann.com/histune.html),
  [Tunable: Werckmeister III](https://tunableapp.com/temperaments/werckmeister-iii/).

## Assumptions

- The owner's baseline machine is the current Apple Silicon Mac; REQ-007 is
  judged there.
- The curated sampled libraries remain the intended top-quality sound
  source; this definition does not require new sample content.
- Seating defaults can be derived from score order (first part leftmost →
  last part rightmost, bass-register lines nearer centre-right), matching
  common ensemble layouts, without per-piece owner input.

## Owner decisions

| Date | Decision | Rationale | Affects |
| --- | --- | --- | --- |
| 2026-09-05 | **D4 revised**: deterministic, score-derived expression (phrase dynamics, cadence timing, articulation defaults, line balance) is allowed beyond on/off+amount humanization. AI/ML or per-performer emulation stays excluded. | The prior D4 excluded interpretive modelling; the owner explicitly relaxes it in this bounded, deterministic form because expression is the identified core gap. | OUT002, REQ-003/P4 |
| 2026-09-05 | **Clean slate for stored presets**: the app is pre-release; new defaults may apply to existing presets and no migration or upgrade affordance is required. | Owner: "irrelevant, app is in development, clean slate is fine." | OUT001, REQ-002 |
| 2026-09-05 | **OUT004 included**: historical tuning (≥1 well temperament, A=440/415) ships in this definition as an optional per-preset choice defaulting to equal temperament. | Smallest outcome, distinct authenticity value for the Bach repertoire. | OUT004, REQ-006 |

## Remaining uncertainty

- Exact staging layout taste (how wide, how wet) is a tuning matter for
  implementation listening tests within REQ-001's observable bounds.
- Loudness comparability target (REQ-005) tolerates a range; the planner
  picks a concrete measure (e.g. integrated loudness window) during
  planning.

## Requirement-to-outcome mapping

| Requirement | Outcome |
| --- | --- |
| REQ-001, REQ-002 | OUT001 |
| REQ-003, REQ-004 | OUT002 (REQ-004's off-state recipe also binds OUT001/OUT003/OUT004 bypass behavior) |
| REQ-005 | OUT003 |
| REQ-006 | OUT004 |
| REQ-007 | Cross-cutting guardrail across OUT001–OUT004 |

## Product issue graph

| Key | Kind | Parent | Title | Issue |
| --- | --- | --- | --- | --- |
| ROOT | ROOT | None | Pro-grade playback sound — electronic Bach | https://github.com/cedagova/synth/issues/49 |
| OUT001 | OUTCOME | ROOT | Staged by default: seating, depth, and a shared room | https://github.com/cedagova/synth/issues/51 |
| OUT002 | OUTCOME | ROOT | Expressive interpretation: deterministic phrasing, articulation, and line balance | https://github.com/cedagova/synth/issues/52 |
| OUT003 | OUTCOME | ROOT | Produced master: cohesion, loudness, and headroom | https://github.com/cedagova/synth/issues/53 |
| OUT004 | OUTCOME | ROOT | Historical tuning color: well temperament and baroque pitch | https://github.com/cedagova/synth/issues/54 |

## Publication verification

Pending: brief publication, graph verification, and exact-head review are
recorded here at publication time.
