# Product Definition: Synth: native macOS high-quality MusicXML player with per-line synth/instrument sound assignment

- Product definition issue: https://github.com/cedagova/synth/issues/1
- Product definition PR: https://github.com/cedagova/synth/pull/2
- Requirements brief: Pending
- Status: Reconciling
- Classification: DECOMPOSE
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

- Single actor: the app user on their own Mac (the owner; D8). No accounts, collaboration, or sharing.
- The user owns and supplies every MusicXML file; the app ships no music (D9).
- Context: local, offline-capable app; network is used only to download instrument sound libraries (D3). Playback through system audio output devices (built-in speakers, Bluetooth, and similar).

## Desired outcomes

1. The user maintains a permanent personal library of imported MusicXML pieces and can find and open any piece quickly.
2. For any piece, every independent musical line the score encodes can be given exactly one sound — a fully customizable synthesized sound or a reasonably customizable sampled instrument — and the piece plays back exactly as configured.
3. Playback is musically faithful: everything the score notates is audible, with subtle user-controllable humanization, clearly better than a mechanical MIDI rendering.
4. The user can design synth sounds from scratch, modify existing sounds, and keep an organized, growing personal sound library.
5. The user's interpretations persist: named per-piece presets capture assignments, customizations, and mixer state, and survive relaunches indefinitely.
6. Any configured piece can be exported to a standard audio file that sounds identical to live playback.

## Product behavior and flows

### First run

- The library is empty; the app explains how to import pieces.
- The app offers to download the curated instrument sound libraries (free, legal, high quality; D3) with size shown; the shipped synth sound collection is available immediately. Instrument download can be deferred and resumed later; synth-only use works without it.

### Import a piece

- The user adds a MusicXML file (`.musicxml`, `.xml`, or compressed `.mxl`).
- The app copies the piece into its library permanently: the library entry is independent of the original file, which may be moved or deleted without any effect (D9).
- Title, composer, and work/movement metadata are read from the file and shown; the library is browsable, searchable, and sortable.

### Assign sounds to lines

- Opening a piece shows its line inventory: every independent line the score encodes (voice level; D1), named from part and voice information, renamable by the user. No score notation is displayed (D2).
- On first open the app auto-creates an initial preset mapping each line to the closest available library instrument named in the score (or a sensible default), so the piece is immediately playable.
- Per line the user assigns exactly one sound: a synth sound or an instrument (mutually exclusive), and adjusts per-line mixer controls (volume, pan, mute, solo).

### Play

- Transport: play, pause, stop, seek by measure/beat or time, optional loop over a measure range.
- Playback honors the score per D4 (structure + expressive notation + realized ornaments) with subtle humanization on by default, globally adjustable and disableable.
- A per-piece report lists any notation the app did not honor, so quality gaps are visible instead of silent.

### Design and customize sounds

- The synthesizer (fixed-but-rich architecture; D6) creates sounds from scratch or edits existing ones; every parameter is editable. Shipped sounds are read-only and editable as copies; user sounds are editable in place.
- Sounds can be auditioned with test notes and by live-editing while the piece plays.
- Instrument customization offers the D7 control set (tone/EQ, dynamics response, envelope shaping within realistic bounds, vibrato, tuning offset, volume/pan/room send), bounded by what the downloaded assets support; unsupported controls are disabled with an explanation.

### Store and reuse

- User sounds (synth patches and named instrument-customization variants) are saved, renamed, organized, and deleted in a personal sound library.
- Per-piece presets: multiple named presets per piece capture the complete assignment, customization, and mixer state; exactly one is active; changes are auto-saved; switching presets takes effect immediately.

### Export

- The user exports the current piece with its active preset to WAV or AIFF at CD quality or better; the render is faithful to live playback, including the current humanization setting (D5).

## States and failure behavior

- **Empty library:** clear guidance to import a first piece; no dead ends.
- **Invalid or unreadable MusicXML:** import fails with a message naming the file and the reason; the library is unchanged.
- **Partially supported score content:** the piece still plays; unhonored notation is listed in the per-piece report rather than silently dropped.
- **Instrument assets not yet downloaded / download interrupted:** affected instruments are visibly unavailable; downloads can be resumed; synth sounds remain fully usable offline. A line assigned to a missing instrument is flagged and audibly substituted only with explicit user awareness.
- **Audio device changes (e.g. Bluetooth connect/disconnect) during playback:** playback continues or pauses gracefully on the new/remaining device; no crash, no corrupted audio.
- **Long or complex pieces:** loading shows progress; playback start is prompt and dropout-free on target hardware.
- **Insufficient disk space during import, download, or export:** the operation fails with a clear message; no partial or corrupted library content, assets, or files remain.
- **Removing a piece:** explicit user action with confirmation; removes the piece and its presets.

## Requirements and acceptance

### Library

- **REQ-001** Importing a MusicXML file (`.musicxml`, `.xml`, `.mxl`) stores the piece permanently in the app library, independent of the source file. *Acceptance: import a file, delete the original, relaunch — the piece still opens and plays.*
- **REQ-002** The library shows title/composer/movement metadata read from each file and is browsable, searchable, and sortable. *Acceptance: find an imported piece by typing part of its composer's name.*
- **REQ-003** Removing a piece requires explicit confirmation and also removes its presets.
- **REQ-004** A failed import names the file and reason and leaves the library unchanged.

### Line assignment

- **REQ-005** The app enumerates every independent line the score encodes (voice level; D1) with names derived from part/voice information; the user can rename lines. *Acceptance: a WTC fugue for keyboard shows one line per fugue voice, not one line for "Piano".*
- **REQ-006** Each line has exactly one assigned sound: synth or instrument, mutually exclusive.
- **REQ-007** First open auto-creates a playable initial preset mapping lines to the closest available instruments named in the score, else a sensible default.
- **REQ-008** Per line: volume, pan, mute, and solo. *Acceptance: soloing one fugue voice plays only that voice.*

### Playback and interpretation

- **REQ-009** Transport: play, pause, stop, seek by measure/beat and by time, loop over a measure range; the current position is always displayed as measure/beat and elapsed time (the only positional orientation, since no score is shown).
- **REQ-010** Notated structure is honored: pitches, rhythms, key/time changes, tempo marks and changes, repeats, D.C./D.S./coda, fermatas (D4). *Acceptance: a piece with repeats and a D.C. al Fine plays the correct expanded sequence.*
- **REQ-011** Expressive notation is honored: dynamics including crescendo/diminuendo, articulations (staccato, legato, accents), slurs, pedal, grace notes, and realized ornaments (trills, mordents, turns) (D4). *Acceptance: a notated trill is audibly realized as alternating notes, not a single held note.*
- **REQ-012** Subtle humanization (micro-timing and phrase-shaped dynamics) is on by default, with a global enable/disable and intensity control (D4). Rendering is deterministic: for a given piece, preset, and humanization setting, every playback produces the same interpretation until the user changes something. *Acceptance: toggling humanization off produces a strictly literal rendering; playing the same configuration twice sounds identical.*
- **REQ-013** Playback is gapless and dropout-free on target hardware.
- **REQ-014** A per-piece report lists score notation that was not honored. *Acceptance: a file containing an unsupported marking shows it in the report.*

### Audio output

- **REQ-015** Audio plays through the system default output; the user can choose any available output device in-app; device connects/disconnects during playback are handled gracefully.

### Synthesizer

- **REQ-016** Fixed-but-rich architecture (D6): multiple oscillators with analog-style, wavetable, and FM synthesis types; filters; envelopes; LFOs; a modulation matrix; per-sound effects (reverb, delay, chorus, EQ). Every parameter is user-editable.
- **REQ-017** Sounds can be created from scratch, duplicated, and modified; shipped sounds are read-only and edited as copies.
- **REQ-018** Sounds can be auditioned with test notes and edited live during piece playback. *Acceptance: filter changes are audible while the piece keeps playing.*
- **REQ-019** The app ships a categorized starter collection of high-quality synth sounds.

### Instruments

- **REQ-020** The app offers in-app download of curated free, legal, high-quality sampled instrument libraries covering standard classical instrumentation (strings, woodwinds, brass, keyboard instruments including piano/harpsichord/organ, harp, timpani and common orchestral percussion), with licenses and attribution shown (D3).
- **REQ-021** Instrument customization offers tone/EQ, dynamics response, envelope shaping within realistic bounds, vibrato depth/rate, tuning offset, and per-line volume/pan/room send — bounded by what each downloaded asset supports; unsupported controls are disabled with an explanation (D7).
- **REQ-022** After download, all instrument content works fully offline and is re-downloadable.

### Storage

- **REQ-023** A personal sound library stores, renames, organizes, and deletes user sounds: synth patches and named instrument-customization variants.
- **REQ-024** Multiple named presets per piece capture complete assignment, customization, and mixer state; exactly one is active; changes auto-save; switching applies immediately.
- **REQ-029** Presets reference library sounds live: editing a user sound is heard by every preset that uses it. Deleting a sound that presets still use warns and, on confirmation, leaves each affected preset with a private embedded copy of the sound as it was — playback of an existing preset never breaks. *Acceptance: delete an in-use sound after confirming; the piece still plays with the same timbre, and the preset shows the sound as embedded.*
- **REQ-025** All library content, sounds, and presets persist locally across relaunches; no cloud dependency.

### Export

- **REQ-026** Export the current piece with its active preset to WAV or AIFF at CD quality or better, faithful to live playback including the current humanization state (D5). Because rendering is deterministic (REQ-012), the export equals what live playback of the same configuration produces. *Acceptance: exporting twice with an unchanged configuration yields the same musical content as live playback of that configuration.*

## Accessibility and content

- **REQ-027** Core flows (library, assignment, transport, presets) are fully keyboard-operable; controls carry VoiceOver labels; standard macOS text-size behavior applies. Sound-editor controls follow standard macOS keyboard-focus and adjustment conventions; pointer-first interaction is acceptable there beyond that baseline.
- UI language: English. Musical terms use their conventional Italian/standard notation names.

## Privacy, security, and policy

- **REQ-028** No accounts, no telemetry, no user data leaves the machine. Network access exists only to download instrument assets over HTTPS from their curated legal sources.
- Sample-library licenses must permit this distribution model; license texts and attributions are preserved and viewable in-app (D3).
- MusicXML files are user-owned content, consumed read-only, and never uploaded.

## Success measures and guardrails

- Owner-validated reference set plays correctly end to end: at minimum one keyboard fugue (voice-level polyphony), one string quartet movement, and one orchestral excerpt.
- For each reference piece, the notated structure and expressive detail of REQ-010/REQ-011 are audibly present, and the owner judges the result clearly superior to a plain General-MIDI-style rendering of the same file.
- Guardrails: no audio dropouts on target hardware; export always matches live playback; imported pieces and presets are never lost across updates.

## Constraints and non-goals

Constraints:

- macOS native app; Apple Silicon only; recent macOS (current minus ~2 major versions) (D8).
- Direct distribution to the owner; no App Store (D8).
- Classical instrumental music only; vocal/choral content and lyrics are out of scope.
- Instrument sample content must be free, legal, high quality, and downloaded on demand (D3).
- The app ships no music; users import their own MusicXML files (D9).

Non-goals:

- No score display of any kind — no engraved notation, no piano-roll/timeline visualization (D2).
- No score editing or composition features; MusicXML is consumed read-only.
- Not a general-purpose MIDI player, sampler workstation, or DAW; no fully modular synthesis (D6).
- No deep interpretation modeling (rubato styles, period-performance conventions) (D4).
- No public release, distribution channel work, or publishing for now — possible later (D8).
- No accounts, cloud sync, sharing, or collaboration.

## Evidence

- `cedagova/synth@63f1313b767a0cefdccae7a91daf1e86bfede1d9` is a blank slate (identity guards only): the entire product is new; no existing behavior constrains the definition.
- MusicXML is a stable, widely used W3C Community Group interchange format whose encoding of parts, voices, dynamics, articulations, ornaments, and structure is documented; the interpretation requirements in REQ-010/REQ-011 name standard MusicXML concepts.
- Owner statements in this conversation (2026-08-22) are the source of the objective and all D1–D9 decisions.

## Assumptions

- Free, legally redistributable sampled instrument libraries of sufficient quality exist to cover the standard classical instrumentation in REQ-020, including enough dynamic layering to make the D7 customization controls meaningful. Planning must validate concrete sources and licenses early; if coverage falls short for some instruments, the gap returns to the owner as a product decision.
- The owner's MusicXML files are broadly well-formed exports from mainstream notation software.
- Voice-level line separation (D1) is derivable from the part/voice/staff information those files encode.

## Owner decisions

| ID | Date | Decision | Rationale | Affects |
| --- | --- | --- | --- | --- |
| D1 | 2026-08-22 | Sound assignment happens at the level of **every independent line the score encodes** (voice level). A part with one voice is the trivial case. | The core use case (e.g. Bach polyphony) needs per-voice timbre; part-level would collapse a keyboard fugue into one line. | Assignment model, line inventory UI, presets |
| D2 | 2026-08-22 | **No score display of any kind** — no engraved notation and no visual timeline. Lines are presented as a named list for assignment; the product is for listening, not reading. | Owner: "user wants to listen to music, not read it." Removes the largest optional scope block. | UI scope, non-goals |
| D3 | 2026-08-22 | Instrument sounds come from **free, legal, high-quality openly licensed sample libraries**, **downloaded** (not bundled), keeping the app lean and fully usable offline after download. | No recurring cost, legal redistribution, high quality from the start. | Sound library, first-run experience, storage |
| D4 | 2026-08-22 | Playback honors **all notated structure** (pitches, rhythms, tempo, repeats/D.C./D.S., fermatas) and **all expressive notation** (dynamics incl. gradual, articulations, slurs, pedal, grace notes, realized ornaments such as trills/mordents/turns), plus **user-controllable subtle humanization, on by default** (micro-timing and phrase-shaped dynamics). Deep interpretation modeling (rubato styles, period-performance conventions) is out of scope. | Tiers 1+2 make the score audible; controllable tier-3 humanization is the difference between "MIDI-sounding" and musical. | Playback engine requirements, acceptance criteria |
| D5 | 2026-08-22 | The app supports **exporting the current piece with its active preset to an audio file** (WAV/AIFF) in addition to live playback. | Modest scope add, high value: listen elsewhere, archive an interpretation. | Flows, requirements |
| D6 | 2026-08-22 | The synthesizer uses a **fixed-but-rich architecture**: multiple oscillators with several synthesis types (analog-style, wavetable, FM), filters, envelopes, LFOs, a modulation matrix, and per-sound effects (reverb, delay, chorus, EQ). Every parameter is user-editable. Fully modular patching is out of scope. | "Completely customizable" with a learnable, classic-polysynth-style UI; modular would multiply UI complexity for the same musical results. | Synthesizer requirements, sound library, UI |
| D7 | 2026-08-22 | Instrument customization means: tone/EQ, dynamics response, envelope shaping within realistic bounds, vibrato depth/rate, tuning offset, and per-line volume/pan/room send — **as far as the downloaded assets feasibly support**; unsupported controls are disabled visibly rather than faked. | Concrete, useful control set without drifting into sampler-editor territory; honest about asset limits. | Instrument requirements, sound library curation |
| D8 | 2026-08-22 | **Direct distribution, Apple Silicon only, recent macOS.** The owner is the only user for now; publishing later would be nice but is explicitly out of scope. | Solo use; App Store ceremony and Intel support buy nothing today. | Constraints, non-goals |
| D9 | 2026-08-22 | The app **ships no music**. The user imports their own MusicXML files; on import a piece is stored **permanently in the app library, independent of the original file** (which may be deleted without effect). | User owns the content; the library must be durable and self-contained. | Library behavior, storage, privacy |

## Remaining uncertainty

- Which concrete sample libraries are curated for download, and the exact per-instrument depth of D7 controls they can support (feasibility-bounded by D7; validated in planning).
- Exact humanization controls beyond a global enable/intensity (kept product-level here; refinement is non-material).
- Alternate tunings/temperaments (e.g. well-tempered, meantone) were not requested and are not defined; may become a later product outcome if the owner wants them.
- Publishing/distribution beyond the owner's machine is deferred (D8), not designed.

## Product issue graph

| Key | Kind | Parent | Title | Issue |
| --- | --- | --- | --- | --- |
| ROOT | ROOT | None | Synth: native macOS high-quality MusicXML player with per-line synth/instrument sound assignment | https://github.com/cedagova/synth/issues/1 |
| OUT001 | OUTCOME | ROOT | Music library: MusicXML import, permanent storage, and piece browsing | https://github.com/cedagova/synth/issues/3 |
| OUT002 | OUTCOME | ROOT | High-fidelity playback: score interpretation, humanization, transport, and audio output | https://github.com/cedagova/synth/issues/4 |
| OUT003 | OUTCOME | ROOT | Per-line sound assignment, mixer, and per-piece presets | https://github.com/cedagova/synth/issues/5 |
| OUT004 | OUTCOME | ROOT | Synthesizer and sound design studio with shipped synth sound collection | https://github.com/cedagova/synth/issues/6 |
| OUT005 | OUTCOME | ROOT | Instrument sound libraries: curated download experience and instrument customization | https://github.com/cedagova/synth/issues/7 |
| OUT006 | OUTCOME | ROOT | Audio export of configured pieces | https://github.com/cedagova/synth/issues/8 |

## Publication verification

Pending: brief publication, outcome-issue creation, graph verification, exact-head decision-owner approval, and exact-head independent review are recorded here once complete.
