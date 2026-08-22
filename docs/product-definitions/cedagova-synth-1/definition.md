# Product Definition: Synth: native macOS high-quality MusicXML player with per-line synth/instrument sound assignment

- Product definition issue: https://github.com/cedagova/synth/issues/1
- Product definition PR: https://github.com/cedagova/synth/pull/2
- Requirements brief: Pending
- Status: Needs input
- Classification: REFINE
- Definition lead: product-definition-lead (Claude Opus 5, claude-opus-5-high)
- Started: 2026-08-22

## Pinned evidence baselines

| Repository | Baseline |
| --- | --- |
| `cedagova/synth` | `63f1313b767a0cefdccae7a91daf1e86bfede1d9` |

## Objective

A macOS native app whose main purpose is to play MusicXML files with high quality, focused exclusively on classical instrumental music (no chorus, vocals, or lyrics).

The user selects a MusicXML piece (e.g. a Bach work) and assigns a sound to every musical line. Per line the choice is mutually exclusive: either a synthesized sound or an instrument sound.

- The app ships from the start with a high-quality library of synth sounds and instruments.
- Synthesized sounds are completely customizable; the app includes a high-quality synthesizer able to define a sound from scratch or modify existing sounds.
- Instrument sounds are customizable to a reasonable degree; less than synths is accepted.
- The UI lets the user choose the piece, use the synthesizer, customize sounds, store sounds, and store presets for specific MusicXML files.
- Playback must honor all the musical information contained in the MusicXML — the details that produce a high-quality musical experience, explicitly not a "simple MIDI-sounding reproduction" or a "digital XML player".
- As a native app it outputs audio through the Mac's speakers, Bluetooth outputs, and similar system audio destinations.

## User or operator need

The owner (a solo user) wants to hear classical instrumental works from MusicXML scores exactly as they choose to hear them — selecting and shaping the timbre of every musical line — at a musical quality that general-purpose MusicXML/MIDI players do not provide.

## Actors and context

- Single actor: the app user on their own Mac. No accounts, collaboration, or sharing implied by the objective.
- Context: local MusicXML files owned by the user; playback through system audio output devices (built-in speakers, Bluetooth, etc.).
- PRODUCT-TODO: confirm remaining context in owner rounds (distribution, macOS targets, offline expectations).

## Desired outcomes

PRODUCT-TODO: Describe observable outcomes rather than a code solution.

## Product behavior and flows

PRODUCT-TODO: Cover entry, main path, completion, and recovery flows.

## States and failure behavior

PRODUCT-TODO: Cover applicable empty, loading, unavailable, permission, error, and recovery states.

## Requirements and acceptance

PRODUCT-TODO: Use stable requirement IDs and observable acceptance examples.

## Accessibility and content

PRODUCT-TODO: State applicable interaction, assistive-technology, language, and content requirements.

## Privacy, security, and policy

PRODUCT-TODO: State consent, retention, exposure, authorization, and policy boundaries, or explain why none apply.

## Success measures and guardrails

PRODUCT-TODO: Define how the owner will recognize success and unacceptable regressions.

## Constraints and non-goals

Constraints (stable so far):

- macOS native app; audio through system output devices (built-in speakers, Bluetooth, etc.).
- Classical instrumental music only; vocal/choral content and lyrics are out of scope.
- Instrument sample content must be free and legally redistributable/downloadable, at high quality (D3).

Non-goals (stable so far):

- No score display of any kind — no engraved notation, no piano-roll/timeline visualization (D2).
- No score editing or composition features; MusicXML files are consumed read-only.
- Not a general-purpose MIDI player or DAW.

PRODUCT-TODO: complete after remaining owner rounds (export, distribution, targets).

## Evidence

PRODUCT-TODO: Separate pinned evidence from inference.

## Assumptions

PRODUCT-TODO: List assumptions that planning may rely on.

## Owner decisions

| ID | Date | Decision | Rationale | Affects |
| --- | --- | --- | --- | --- |
| D1 | 2026-08-22 | Sound assignment happens at the level of **every independent line the score encodes** (voice level). A part with one voice is the trivial case. | The core use case (e.g. Bach polyphony) needs per-voice timbre; part-level would collapse a keyboard fugue into one line. | Assignment model, line inventory UI, presets |
| D2 | 2026-08-22 | **No score display of any kind** — no engraved notation and no visual timeline. Lines are presented as a named list for assignment; the product is for listening, not reading. | Owner: "user wants to listen to music, not read it." Removes the largest optional scope block. | UI scope, non-goals |
| D3 | 2026-08-22 | Instrument sounds come from **free, legal, high-quality openly licensed sample libraries**, **downloaded** (not bundled), keeping the app lean and fully usable offline after download. | No recurring cost, legal redistribution, high quality from the start. | Sound library, first-run experience, storage |
| D4 | 2026-08-22 | Playback honors **all notated structure** (pitches, rhythms, tempo, repeats/D.C./D.S., fermatas) and **all expressive notation** (dynamics incl. gradual, articulations, slurs, pedal, grace notes, realized ornaments such as trills/mordents/turns), plus **user-controllable subtle humanization, on by default** (micro-timing and phrase-shaped dynamics). Deep interpretation modeling (rubato styles, period-performance conventions) is out of scope. | Tiers 1+2 make the score audible; controllable tier-3 humanization is the difference between "MIDI-sounding" and musical. | Playback engine requirements, acceptance criteria |
| D5 | 2026-08-22 | The app supports **exporting the current piece with its active preset to an audio file** (WAV/AIFF) in addition to live playback. | Modest scope add, high value: listen elsewhere, archive an interpretation. | Flows, requirements |
| D6 | 2026-08-22 | The synthesizer uses a **fixed-but-rich architecture**: multiple oscillators with several synthesis types (analog-style, wavetable, FM), filters, envelopes, LFOs, a modulation matrix, and per-sound effects (reverb, delay, chorus, EQ). Every parameter is user-editable. Fully modular patching is out of scope. | "Completely customizable" with a learnable, classic-polysynth-style UI; modular would multiply UI complexity for the same musical results. | Synthesizer requirements, sound library, UI |

## Remaining uncertainty

PRODUCT-TODO: State remaining non-material uncertainty, or `None`.

## Product issue graph

| Key | Kind | Parent | Title | Issue |
| --- | --- | --- | --- | --- |
| ROOT | ROOT | None | Synth: native macOS high-quality MusicXML player with per-line synth/instrument sound assignment | https://github.com/cedagova/synth/issues/1 |

## Publication verification

PRODUCT-TODO: Record brief publication, graph verification, exact-head review, and next action.
