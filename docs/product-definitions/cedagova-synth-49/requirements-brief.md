# Requirements Brief: Pro-grade playback sound — electronic Bach

## Problem and intended outcome

Playback is mechanically right but audibly a "MIDI demo": every line dry,
centred, equal level, with uniform jitter as the only expression. The
outcome: pressing Play on any piece produces a rendition the owner would
voluntarily listen to end to end — faithful to the score, unmistakably
electronic, produced like a record ("electronic Bach").

## Proposed behavior and main flows

A freshly imported piece opens already staged (each line seated left–right
with depth in a shared room), plays with deterministic score-derived
expression (phrase-shaped dynamics, cadence breathing, written-articulation
defaults, melody slightly above accompaniment), and sums through a produced
master (cohesion, consistent loudness, guaranteed headroom). Staging values
are ordinary per-line mixer values stored in the preset; expression and
tuning are preset-level settings beside humanization. Expression and
mastering each have an honest bypass for A/B. Export remains byte-identical
to live playback.

## Scope and non-goals

Included: default staging, deterministic expression, master cohesion, and
an optional per-preset historical tuning choice (≥1 well temperament,
A=440/415). Excluded: AI/ML interpretation, per-note editing surfaces,
score/timeline visualization, third-party plugin hosting, new sample
content production, streaming/sharing.

## Product outcomes

- ROOT #49 — pro-grade playback sound.
- OUT001 — Staged by default: seating, depth, and a shared room.
- OUT002 — Expressive interpretation: deterministic phrasing, articulation,
  and line balance.
- OUT003 — Produced master: cohesion, loudness, and headroom.
- OUT004 — Historical tuning color: well temperament and baroque pitch.

## Important constraints and success measures

Determinism is inviolable: same piece + preset + settings → identical
audio, and export equals live playback. The 12-line reference piece must
play without overload pauses with everything on. Success is the owner
choosing the new rendition over the pinned baseline in an A/B listen and
keeping the features on.

## Evidence, assumptions, and uncertainty

Evidence is pinned at `cedagova/synth@8d77ddc`: fresh presets are neutral
(dry/centred/unity), a per-line room send exists but defaults silent, the
master bus is gain-only, tuning is fixed equal temperament at A=440, and
expression is uniform seeded jitter. External practice (Switched-On Bach
production history; orchestral mockup guidance) identifies space and
phrasing — not patch quality — as the gap. Assumptions: current Apple
Silicon baseline; curated sampled libraries remain the top-quality sound
source; seating derivable from score order. Remaining uncertainty is taste
tuning (how wide/wet) and the concrete loudness measure, both bounded by
the requirements.

## Owner decisions

- 2026-09-05 — D4 revised: bounded deterministic score-derived expression
  is allowed; AI/ML interpretation stays excluded.
- 2026-09-05 — Clean slate: pre-release app; no preset migration promise.
- 2026-09-05 — OUT004 (historical tuning) is included.

## Links and next action

- Root issue: https://github.com/cedagova/synth/issues/49
- Definition PR: https://github.com/cedagova/synth/pull/50
- Next action: `plan https://github.com/cedagova/synth/issues/49`
