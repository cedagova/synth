# Requirements Brief: Synth: native macOS high-quality MusicXML player with per-line synth/instrument sound assignment

## Problem and intended outcome

General MusicXML/MIDI players render classical scores mechanically. The owner wants a macOS-native app that plays their own MusicXML files of classical instrumental music with real musical quality, letting them choose and shape the sound of every musical line — so each piece is heard exactly as they want to hear it.

## Proposed behavior and main flows

- Import MusicXML files into a permanent personal library (independent of the original files) and browse/search by title and composer.
- Open a piece to see every independent musical line the score encodes (down to individual fugue voices); assign each line either a fully customizable synthesized sound or a reasonably customizable sampled instrument — mutually exclusive per line — with per-line volume, pan, mute, and solo. No score notation is displayed.
- Play with full transport (play/pause/stop/seek/loop). Playback honors all notated structure and expressive notation — dynamics, articulations, slurs, pedal, grace notes, realized ornaments, repeats, fermatas — plus subtle, user-controllable humanization (on by default). Unhonored notation is reported, never silently dropped.
- Design synth sounds from scratch or modify existing ones with a fixed-but-rich synthesizer (multi-type oscillators, filters, envelopes, LFOs, modulation matrix, per-sound effects); audition live during playback; keep an organized personal sound library.
- Download curated free, legal, high-quality instrument sample libraries on demand; customize instruments (tone, dynamics response, envelope, vibrato, tuning, space) as far as each asset supports.
- Save multiple named per-piece presets capturing complete assignment, customization, and mixer state; auto-saved, instantly switchable, persistent forever.
- Export any configured piece to WAV/AIFF, faithful to live playback.
- Audio to any system output device (speakers, Bluetooth) with graceful device switching.

## Scope and non-goals

Included: library, voice-level assignment, high-fidelity interpretation engine, synthesizer and sound design, instrument download and customization, presets, export, macOS-native UI.

Non-goals: score display of any kind, score editing/composition, general MIDI player/DAW/sampler ambitions, modular synthesis, deep interpretation modeling (rubato styles), vocal/choral works, accounts/cloud/collaboration, public release (deferred).

## Product outcomes

Root plus six product outcomes: (1) music library and import; (2) high-fidelity playback and audio output; (3) per-line assignment, mixer, and presets; (4) synthesizer and sound design studio; (5) instrument libraries download and customization; (6) audio export.

## Important constraints and success measures

Constraints: Apple Silicon Macs, recent macOS, direct distribution; instrument content must be free, legal, high quality, downloaded; app ships no music.

Success: a reference set (keyboard fugue, string quartet movement, orchestral excerpt) plays with all notated detail audible and clearly outperforms a General-MIDI-style rendering, with no dropouts; export matches live playback; library and presets are never lost.

## Evidence, assumptions, and uncertainty

Evidence: blank-slate repository pinned at `63f1313`; MusicXML is a documented stable interchange format; the owner supplied the objective and all decisions on 2026-08-22.

Assumptions: suitable free, legal, high-quality sample libraries exist with enough depth to support the promised instrument customization (planning validates sources early; shortfalls return to the owner); user files are well-formed exports encoding usable part/voice information.

Uncertainty: concrete curated sample libraries and their per-instrument customization depth; humanization control details; temperaments (not requested); future publishing (deferred).

## Owner decisions

Nine decisions (D1-D9) recorded in the definition: voice-level lines; no score display; downloaded open sample libraries; interpretation depth with default-on subtle humanization; audio export; fixed-but-rich synth architecture; concrete instrument-customization set bounded by asset feasibility; Apple-Silicon-only direct distribution; user-owned music with permanent library storage.

## Links and next action

- Root issue: https://github.com/cedagova/synth/issues/1
- Definition PR: https://github.com/cedagova/synth/pull/2
- Next action: `plan https://github.com/cedagova/synth/issues/1`
