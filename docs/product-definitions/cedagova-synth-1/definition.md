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

PRODUCT-TODO: Make scope boundaries explicit without prescribing implementation.

## Evidence

PRODUCT-TODO: Separate pinned evidence from inference.

## Assumptions

PRODUCT-TODO: List assumptions that planning may rely on.

## Owner decisions

PRODUCT-TODO: Record dated material decisions and rationale, or `None`.

## Remaining uncertainty

PRODUCT-TODO: State remaining non-material uncertainty, or `None`.

## Product issue graph

| Key | Kind | Parent | Title | Issue |
| --- | --- | --- | --- | --- |
| ROOT | ROOT | None | Synth: native macOS high-quality MusicXML player with per-line synth/instrument sound assignment | https://github.com/cedagova/synth/issues/1 |

## Publication verification

PRODUCT-TODO: Record brief publication, graph verification, exact-head review, and next action.
