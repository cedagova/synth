# Implementation Plan: Synth: native macOS high-quality MusicXML player with per-line synth/instrument sound assignment

- Planning issue: https://github.com/cedagova/synth/issues/1
- Planning PR: https://github.com/cedagova/synth/pull/9
- Status: Ready for implementation
- Root classification: INCREMENTAL
- Delivery topology: INCREMENTAL
- Planner: Planning lead (Claude Fable 5, implementation-planning-lead)
- Started: 2026-08-27
- Product definition: https://github.com/cedagova/synth/pull/2
- Product definition head: 1da5fae12c542b89882dd2298e111577ed87aa97
- Requirements brief: https://github.com/cedagova/synth/issues/1#issuecomment-5382594160

## Pinned baselines

| Repository | Baseline |
| --- | --- |
| `cedagova/synth` | `63f1313b767a0cefdccae7a91daf1e86bfede1d9` |

## Preserved objective and boundaries

The approved product contract is `docs/product-definitions/cedagova-synth-1/definition.md`
(REQ-001..REQ-029, decisions D1–D9) at the pinned definition head above. This
plan preserves it unchanged: a macOS-native (Apple Silicon, direct
distribution) player for the owner's classical instrumental MusicXML files;
voice-level line enumeration with exactly one sound per line (fully
customizable synth or reasonably customizable downloaded instrument); faithful
deterministic playback of all notated structure and expressive notation with
default-on adjustable humanization; per-piece named presets; from-scratch
synthesizer with shipped collection; curated free/legal instrument downloads;
WAV/AIFF export equal to live playback. Non-goals stay non-goals: no score
display, no editing, no DAW/sampler ambitions, no modular synthesis, no deep
interpretation modeling, no vocal works, no accounts/cloud, no public release.

The six approved product outcomes (issues #3–#8) remain the native children of
root #1. Planning adds execution structure only; it does not reinterpret the
product contract.

## Classification

- **ROOT #1 — `INCREMENTAL`.** The root owns six delivery-sized outcomes on a
  blank-slate repository. Each outcome is a real effort with its own delivery
  boundary (several PRs, independent verification); flattening them into one
  effort would create an unreviewable project run, and none is a single leaf.
  The root becomes tracking-only with a strict `001`–`006` increment sequence.
- **Increments (existing outcome issues, reused; each `GROUP`):**
  - `001` #3 Music library — app foundation, import, permanent storage, browsing.
  - `002` #4 High-fidelity playback — score interpretation, humanization,
    audio engine with built-in default voice, transport.
  - `003` #6 Synthesizer studio — synthesis engine, sound library, editor,
    shipped collection.
  - `004` #5 Assignment, mixer, presets — line inventory UI, per-line sound
    assignment, mixer, per-piece presets.
  - `005` #7 Instrument libraries — curated downloads, sampled-instrument
    engine, bounded customization.
  - `006` #8 Audio export.
- **Every descendant leaf — `LEAF`** (16 leaves total; see manifest). No
  increment is `DEFERRED`: all six paths are reliably plannable today from the
  approved definition, the MusicXML specification, and the instrument-source
  research recorded below. Nothing presently knowable is deferred.

The delivery order follows real dependencies, not outcome numbering: playback
needs imported pieces (001→002); the synthesizer provides the first real,
user-manageable sound palette and the sound-library substrate (002→003);
assignment/presets need lines, playback, and a palette plus the sound-library
reference semantics of REQ-029 (003→004); instrument libraries extend the
palette and the assignment states for missing instruments (004→005); export
renders what a fully configured piece plays (005→006).

## Current-state evidence

- `cedagova/synth@63f1313` is a blank slate: identity guards (`bin/`,
  `.githooks/`) and `.gitignore` only. No stack, no code, no CI. Everything is
  new; no existing behavior constrains or partially satisfies any REQ, so
  `ALREADY_SATISFIED` is impossible and no gap analysis beyond this is needed.
- `definition status` on 2026-08-27: Ready for planning, PR #2, head
  `1da5fae12c542b89882dd2298e111577ed87aa97`, decision-owner approval and
  independent review recorded.
- Instrument-source research (2026-08-27, planning specialist; details in
  `## Instrument source evidence`) confirms the definition's flagged
  assumption: free, legal, high-quality libraries cover the REQ-020
  instrumentation, with honest quality caveats recorded for owner visibility.

## Selected implementation direction

System-level HOW; files, classes, and algorithms belong to implementation.

1. **One native macOS app, one repository.** Swift + SwiftUI application in
   this repository, Apple Silicon only, minimum macOS = current minus two
   majors at first build (pinned concretely in increment 001). Direct
   distribution (Developer ID, no App Store), per D8.
2. **Audio through Core Audio via AVAudioEngine** with custom real-time DSP
   (source-node render callbacks; allocation-free audio thread, DSP core in
   real-time-safe Swift/C as implementation chooses). The same render path
   runs live and in offline manual-rendering mode, which is what makes
   REQ-026 (export equals live playback) structural rather than aspirational.
3. **Deterministic interpretation pipeline.** Import keeps the user's
   MusicXML verbatim in the library store. A pure, seeded compiler turns a
   stored piece + preset + humanization setting into a per-line performance
   event timeline: structural expansion (repeats, D.C./D.S./coda, tempo map)
   → expressive realization (dynamics, articulations, slurs, pedal, grace
   notes, ornaments) → humanization (seeded micro-timing and phrase-shaped
   dynamics). Identical inputs always yield the identical timeline (REQ-012);
   anything not honored is emitted into the per-piece report (REQ-014), never
   silently dropped. Voice-level line identity (D1) is established here and
   reused by assignment, mixing, presets, and export.
4. **Local persistence under one Application Support container**: an SQLite
   database for library metadata, sounds, presets, and catalog state;
   imported MusicXML and downloaded assets as files inside the container.
   All persisted formats (database schema, patch documents, preset documents)
   are versioned from day one with forward migrations; every increment leaves
   stores openable by its successor (REQ-025, "never lost across updates").
5. **Sounds are one abstraction with two engines.** A "sound" assignable to a
   line is either a synth patch (fixed-but-rich engine per REQ-016) or an
   instrument (SFZ-subset sample player over downloaded assets) — mutually
   exclusive per line (REQ-006). The personal sound library, shipped
   read-only collection, edit-as-copy, live references, and embed-on-delete
   (REQ-017/023/029) sit above both engines.
6. **Instrument content is curated, downloaded, never shipped.** A catalog
   manifest built into the app pins each curated library's source URL,
   license, attribution, size, and covered instruments (sources in
   `## Instrument source evidence`). The app downloads over HTTPS with
   resume and re-download, shows licenses in-app, and works fully offline
   afterward (REQ-020..022, REQ-028). SFZ (+ WAV/FLAC samples) is the single
   canonical asset format; curation converts or repackages where a source
   needs it.
7. **Validation is test-first where determinism lives**: golden-file tests
   for the interpretation compiler, offline-render tests for the engines (no
   audio device needed in CI), and owner-audible checks on the reference set
   (keyboard fugue, string quartet movement, orchestral excerpt) as each
   increment's completion evidence.

## Architecture decisions

Recorded under the owner's 2026-08-27 delegation to run planning to completion
and document decisions in the PR (see `Assumptions and open questions`). Each
is the pragmatic solo-developer choice; the planning PR stays open for veto.

| ID | Decision | Rationale | Reversibility |
| --- | --- | --- | --- |
| AD1 | Swift + SwiftUI native app; Xcode project; XCTest; no cross-platform framework (JUCE, Qt, Electron) | Best-fit for a macOS-only, Apple-Silicon-only, direct-distribution app; first-class Core Audio access; solo-friendly toolchain; avoids JUCE licensing and non-native UI | Foundational; cheap to change only now (blank slate) — hence recorded for explicit owner veto |
| AD2 | AVAudioEngine/Core Audio with custom DSP in source-node render callbacks; export via the same graph in offline manual-rendering mode | Meets dropout-free + device-handling REQs natively; single render path makes export≡live structural (REQ-026) | Engine internals swappable behind the line-voice interface |
| AD3 | One Application Support container; SQLite for metadata/presets/sounds; verbatim MusicXML + assets as files; versioned schemas + forward migrations from day one | Durable, inspectable, atomic; satisfies REQ-025 and the never-lose-data guardrail without cloud | Additive migrations; low risk |
| AD4 | Own MusicXML importer on Foundation XML parsing, targeting the documented MusicXML 3.1/4.0 concepts named in REQ-010/011; verbatim source retained | No maintained Swift library covers the needed interpretive depth; verbatim retention lets interpretation improve without re-import | Parser internal; verbatim files make it fully revisable |
| AD5 | Determinism by construction: pure seeded compiler stage producing the event timeline; humanization is a deterministic function of (piece, preset, setting) | REQ-012 acceptance and REQ-026 equality become testable invariants instead of QA hopes | Internal contract |
| AD6 | SFZ subset (+ WAV/FLAC) as the single instrument asset format; bounded opcode support driven by the curated set; catalog manifest ships in the app, updated with app updates | All curated sources are SFZ-native or convertible; one player instead of N format engines; REQ-028 keeps network = asset downloads only | Catalog data-driven; subset extensible |
| AD7 | Increment 002 ships a fixed built-in default synth voice so playback is audible before the studio exists; increment 003 replaces it with the real engine + shipped collection | Keeps every increment independently verifiable and the product working at each frontier | Transitional by design |

## Execution graph and waves

Strict increment sequence (each blocked by its immediate predecessor; no
parallel increments, per the incremental contract):

| Wave | Increment | Leaves in order |
| --- | --- | --- |
| 1 | `001` #3 Music library | LIB001 → LIB002 → LIB003 |
| 2 | `002` #4 High-fidelity playback | PLY001 → PLY002 → PLY003 → PLY004 |
| 3 | `003` #6 Synthesizer studio | SYN001 → SYN002 → SYN003 |
| 4 | `004` #5 Assignment, mixer, presets | ASN001 → ASN002 |
| 5 | `005` #7 Instrument libraries | INS001 → INS002 → INS003 |
| 6 | `006` #8 Audio export | EXP001 |

Within an increment, leaf order is expressed as native blocked-by edges
between siblings; cross-increment order lives only on the increment issues.
Every increment ends with the app in a working, owner-verifiable state:

- after 001: import, browse, search, remove pieces durably;
- after 002: pieces play faithfully with the default voice; transport, report,
  device handling work;
- after 003: sounds can be designed, organized, auditioned; shipped collection
  present;
- after 004: per-line assignment, mixing, and durable presets over the synth
  palette;
- after 005: full dual palette with downloads, licenses, customization;
- after 006: export closes the loop.

## Interfaces and ownership

All interfaces are internal to `cedagova/synth` (single repository, single
app). The contracts that cross increment boundaries — and therefore must stay
stable once delivered — are:

- **Score model + line identity** (from PLY001): the parsed, expanded score
  with stable voice-level line identifiers per piece. Consumed by realization,
  assignment, mixer, presets, export.
- **Performance event timeline** (from PLY002): deterministic per-line event
  streams consumed by the audio engine, live and offline.
- **Line-voice rendering interface** (from PLY003): how any sound renders a
  line's events inside the engine graph. Implemented by the built-in default
  voice (002), the synth engine (003), and the sample player (005).
- **Sound library model** (from SYN002): identified, versioned sound
  documents; read-only shipped entries; edit-as-copy; live references with
  embed-on-delete (REQ-029). Consumed by assignment/presets (004) and
  extended with instrument variants (005).
- **Preset document** (from ASN001): complete assignment + customization +
  mixer state per piece; exactly one active; auto-saved (REQ-024).
- **Catalog manifest** (from INS001): curated source list with license,
  attribution, size, and instrument coverage.

## Risks and rabbit holes

- **MusicXML interpretive breadth is unbounded.** The contract is bounded by
  REQ-010/011's named concepts plus the REQ-014 report as the honest safety
  valve. Do not chase exhaustive notation support; the owner's reference set
  drives priority. Unknown markings go to the report, never block playback.
- **Real-time safety.** The audio thread must be allocation- and lock-free;
  Swift on the audio thread requires discipline or a small C core. PLY003
  owns this decision; the golden rule is the dropout-free guardrail on
  target hardware, verified with the orchestral reference piece.
- **Free instrument-library quality varies** (see evidence section): solo
  strings and some winds have limited dynamic layers; harpsichord/organ come
  from dedicated sources. The catalog leaf (INS001) surfaces per-instrument
  quality honestly; a genuine coverage shortfall returns to the owner as the
  definition requires. Customization controls degrade visibly, never fake
  (REQ-021).
- **SFZ opcode sprawl.** Implement only the subset the curated set uses;
  extending the subset is data-driven, not speculative.
- **Synth scope creep.** REQ-016's fixed architecture is the ceiling: no
  modular patching, no user-visible routing graphs (D6).
- **SwiftUI for a knob-heavy editor** may need custom controls; REQ-027
  allows pointer-first editing beyond the keyboard baseline, so this is
  bounded UI work, not a framework risk.
- **Humanization taste.** Product-level controls are just enable + intensity
  (definition "Remaining uncertainty"); resist inventing deeper controls.

## Migration, rollout, recovery, and rollback

Local single-user app; no server, no fleet, no staged rollout. The material
concerns are the owner's data and the sequential baseline:

- **Data safety:** every persisted format versioned from day one; forward
  migrations on open; atomic writes (import, download, export leave no
  partial state on failure, REQ-004 and disk-full states). The
  never-lose-pieces/presets guardrail is acceptance in LIB002/ASN001.
- **Rollback:** each increment merges to `main` only when verified; a
  defective increment is reverted as ordinary git history before the next
  increment starts (strict frontier guarantees no dependent work is in
  flight). Store migrations are additive so a reverted app version still
  opens the store it created.
- **Recovery:** downloads resume; re-download restores assets; the library
  and presets are self-contained under the app container and survive app
  reinstalls.

## Issue publication manifest

| Key | Kind | Parent | Repository | Title | Delivery | Blocked by | Issue |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ROOT | TRACKING | None | cedagova/synth | Synth: native macOS high-quality MusicXML player with per-line synth/instrument sound assignment | INCREMENTAL | None | https://github.com/cedagova/synth/issues/1 |
| INC001 | GROUP | ROOT | cedagova/synth | Music library: MusicXML import, permanent storage, and piece browsing | COLLECTOR | None | https://github.com/cedagova/synth/issues/3 |
| INC002 | GROUP | ROOT | cedagova/synth | High-fidelity playback: score interpretation, humanization, transport, and audio output | COLLECTOR | INC001 | https://github.com/cedagova/synth/issues/4 |
| INC003 | GROUP | ROOT | cedagova/synth | Synthesizer and sound design studio with shipped synth sound collection | COLLECTOR | INC002 | https://github.com/cedagova/synth/issues/6 |
| INC004 | GROUP | ROOT | cedagova/synth | Per-line sound assignment, mixer, and per-piece presets | COLLECTOR | INC003 | https://github.com/cedagova/synth/issues/5 |
| INC005 | GROUP | ROOT | cedagova/synth | Instrument sound libraries: curated download experience and instrument customization | COLLECTOR | INC004 | https://github.com/cedagova/synth/issues/7 |
| INC006 | GROUP | ROOT | cedagova/synth | Audio export of configured pieces | DIRECT | INC005 | https://github.com/cedagova/synth/issues/8 |
| LIB001 | LEAF | INC001 | cedagova/synth | App foundation: SwiftUI shell, persistent store container, CI build/test | None | None | https://github.com/cedagova/synth/issues/10 |
| LIB002 | LEAF | INC001 | cedagova/synth | MusicXML import pipeline: formats, verbatim storage, metadata, failure states | None | LIB001 | https://github.com/cedagova/synth/issues/11 |
| LIB003 | LEAF | INC001 | cedagova/synth | Library UI: browse, search, sort, remove, import experience | None | LIB002 | https://github.com/cedagova/synth/issues/12 |
| PLY001 | LEAF | INC002 | cedagova/synth | Score model and structural interpretation compiler with line identity and honored-notation report | None | None | https://github.com/cedagova/synth/issues/13 |
| PLY002 | LEAF | INC002 | cedagova/synth | Expressive realization and deterministic humanization producing performance event timelines | None | PLY001 | https://github.com/cedagova/synth/issues/14 |
| PLY003 | LEAF | INC002 | cedagova/synth | Real-time audio engine, line-voice interface, built-in default voice, output-device handling | None | PLY002 | https://github.com/cedagova/synth/issues/15 |
| PLY004 | LEAF | INC002 | cedagova/synth | Transport and playback UI: play/pause/stop/seek/loop, position display, piece report | None | PLY003 | https://github.com/cedagova/synth/issues/16 |
| SYN001 | LEAF | INC003 | cedagova/synth | Synthesis engine: oscillators (analog/wavetable/FM), filters, envelopes, LFOs, mod matrix, per-sound effects | None | None | https://github.com/cedagova/synth/issues/17 |
| SYN002 | LEAF | INC003 | cedagova/synth | Sound library: personal store, shipped read-only collection, edit-as-copy, patch documents | None | SYN001 | https://github.com/cedagova/synth/issues/18 |
| SYN003 | LEAF | INC003 | cedagova/synth | Synth editor UI: full parameter editing, test-note audition, live editing during playback | None | SYN002 | https://github.com/cedagova/synth/issues/19 |
| ASN001 | LEAF | INC004 | cedagova/synth | Assignment and preset model: line inventory, one-sound-per-line, named auto-saved presets, live references with embed-on-delete | None | None | https://github.com/cedagova/synth/issues/20 |
| ASN002 | LEAF | INC004 | cedagova/synth | Assignment and mixer UI: line list, sound picker, volume/pan/mute/solo, preset management | None | ASN001 | https://github.com/cedagova/synth/issues/21 |
| INS001 | LEAF | INC005 | cedagova/synth | Curated instrument catalog and download manager with licenses, resume, and offline integrity | None | None | https://github.com/cedagova/synth/issues/22 |
| INS002 | LEAF | INC005 | cedagova/synth | SFZ-subset sampled-instrument playback engine behind the line-voice interface | None | INS001 | https://github.com/cedagova/synth/issues/23 |
| INS003 | LEAF | INC005 | cedagova/synth | Instrument customization bounded by assets, named variants, missing-instrument states | None | INS002 | https://github.com/cedagova/synth/issues/24 |
| EXP001 | LEAF | INC006 | cedagova/synth | Offline export of the active preset to WAV/AIFF equal to live playback | None | None | https://github.com/cedagova/synth/issues/25 |

## Instrument source evidence

Research result (2026-08-27, read-only planning specialist with live web
verification) validating the definition's flagged assumption for REQ-020.
**Verdict: full coverage of the required instrumentation is achievable with
clean licenses at reasonable quality — entirely from CC0/CC-BY sources, all
legally mirrorable.** The concrete curated set, exact versions, URLs, and
license texts are pinned by INS001; this section records planning-level
evidence, not the final catalog.

Planning-level candidate set:

| Role | Library | License | Format | Notes |
| --- | --- | --- | --- | --- |
| Orchestra core (winds, brass, strings, timpani, percussion) | VSCO 2 Community Edition v1.1.0 (github.com/sgossner/VSCO-2-CE) | CC0 | SFZ+WAV | 3–6 dynamic levels, round robins on shorts; best-in-class CC0 orchestral set |
| Piano | Salamander Grand v3 (freepats.zenvoid.org) | CC-BY 3.0 | SFZ+WAV | 16 velocity layers, release samples; the reference free piano |
| Harpsichord, organ, extra percussion | VCSL selections (github.com/sgossner/VCSL) | CC0 | SFZ+WAV | 5 harpsichords, 2 organs; harpsichord/organ need no velocity layers, so lean sampling is adequate |
| Harp | Etherealwinds Harp II CE (Versilian) | CC-BY 4.0 | SFZ | 2 velocity layers × 2 round robins |
| Optional strings upgrade | Virtual Playing Orchestra 3.3 | mixed (contains Philharmonia content) | SFZ+WAV | hotlink from source only — never mirror; include only if INS001 needs the quality |

Verified-incompatible: Spitfire LABS / BBCSO Discover (EULA forbids any
redistribution; proprietary format and installer). Excluded.

Known quality bounds recorded for owner visibility (not blockers; the
definition routes genuine shortfalls back to the owner at INS001):

- Solo viola and solo cello have no clean-license solo patches (VSCO 2 CE has
  solo violin and solo contrabass, sections otherwise); solo lines for those
  instruments start on section patches, with mixed-license VPO as an opt-in
  upgrade.
- No free library offers true legato transitions; slurred passages render as
  shaped sustains.
- Dynamic layering is thin outside VSCO 2 CE shorts and Salamander; expressive
  long-note dynamics rely on synthetic gain/filter shaping (which the D7
  customization set already anticipates).

Implication for INS002: an SFZ 1.0 subset with WAV samples suffices —
region/group structure, key/velocity mapping, tuning, round-robin sequencing,
ADSR + velocity tracking, loops, release triggers, volume/pan. No FLAC, no
keyswitches, no CC crossfades unless VPO is adopted.

## Acceptance coverage

| Requirement | Covered by |
| --- | --- |
| REQ-001 import + permanence | LIB002 (playable end-to-end once INC002 delivers) |
| REQ-002 metadata, browse/search/sort | LIB002, LIB003 |
| REQ-003 removal + preset cascade | LIB003 (cascade contract), ASN001 (presets side; full verification with real presets completes at increment 004) |
| REQ-004 failed import, library unchanged | LIB002, LIB003 |
| REQ-005 voice-level line enumeration + rename | PLY001 (identity), ASN001/ASN002 (surface) |
| REQ-006 one sound per line, mutually exclusive | ASN001 |
| REQ-007 auto-created playable initial preset | ASN001 (synth palette), INS003 (instrument-aware mapping) |
| REQ-008 per-line volume/pan/mute/solo | PLY003 (engine basis), ASN002 (UI) |
| REQ-009 transport + position display | PLY004 |
| REQ-010 notated structure honored | PLY001 |
| REQ-011 expressive notation honored | PLY002 |
| REQ-012 deterministic humanization, on by default | PLY002 |
| REQ-013 gapless, dropout-free | PLY003 |
| REQ-014 per-piece unhonored-notation report | PLY001 (data), PLY004 (UI) |
| REQ-015 output device selection + graceful changes | PLY003 |
| REQ-016 synth architecture, all parameters editable | SYN001 |
| REQ-017 create/duplicate/modify, shipped read-only as copies | SYN002, SYN003 |
| REQ-018 audition + live editing during playback | SYN003 (in-increment play-through audition binding; assigned-line form re-verified at increment 004 completion) |
| REQ-019 shipped categorized starter collection | SYN002 |
| REQ-020 curated legal instrument downloads + licenses shown | INS001 |
| REQ-021 bounded customization, unsupported disabled | INS003 |
| REQ-022 fully offline after download, re-downloadable | INS001 |
| REQ-023 personal sound library (patches + variants) | SYN002, INS003 |
| REQ-024 multiple named auto-saved presets, one active | ASN001, ASN002 |
| REQ-025 local persistence across relaunches | LIB001 (store), ASN001, SYN002 |
| REQ-026 WAV/AIFF export equal to live playback | EXP001 |
| REQ-027 keyboard operability + VoiceOver baseline | LIB003, PLY004, SYN003, ASN002, INS001, INS003 (every UI leaf carries it) |
| REQ-028 no telemetry; network only for asset downloads | LIB001 (baseline), INS001 (only network user) |
| REQ-029 live references, warn-and-embed on delete | ASN001 |

Root acceptance (reference set audibly superior end to end) is the joint
completion evidence of increments 002, 003, and 005 and the closure condition
of the tracking root. No REQ is orphaned; overlaps above are deliberate
(engine capability vs. UI surface).

## Validation and feedback

- Every leaf: `xcodebuild` build + XCTest suite green in CI (`Required
  checks` gate); leaf-specific acceptance in its issue.
- Interpretation compiler (PLY001/PLY002): golden-file tests on crafted
  MusicXML fixtures (repeats/D.C. expansion, trill realization, determinism
  byte-equality of timelines).
- Engines (PLY003, SYN001, INS002, EXP001): offline-render tests asserting
  audible-content invariants without an audio device; dropout guardrail
  checked on target hardware with the orchestral reference.
- Increment completion: owner-audible smoke on the reference set as stated in
  each increment's completion rule.
- Planning artifact: `plan validate` phases + `plan reconcile-graph` /
  `plan verify-graph` per the shared CLI.

## Assumptions and open questions

- **Owner delegation (2026-08-27):** the owner instructed this planning run to
  proceed to completion autonomously, spawn the independent reviewer, and
  document all decisions in the issues/PR rather than pausing per decision.
  Material architecture choices AD1–AD7 are therefore recorded above and in
  the planning PR for veto; AD1 (Swift/SwiftUI native stack) is the one the
  owner should actively confirm reading, since it fixes the toolchain for the
  whole product. No product-contract decision was taken: all product behavior
  comes from the approved definition.
- **From the definition, still true:** owner MusicXML files are well-formed
  mainstream-notation exports; voice-level separation is derivable from their
  part/voice/staff encoding. First real-file evidence arrives in increment
  001–002; contradictions return to the owner.
- **Instrument coverage:** validated at planning level (see
  `## Instrument source evidence`); INS001 re-verifies each pinned source at
  implementation time and any genuine shortfall returns to the owner as a
  product decision, per the definition.
- Open questions: None.

## Satisfaction proof

Not applicable — the repository is a blank slate; implementation work remains
across all six increments. Disposition is `IMPLEMENTATION_REQUIRED`.

## Publication verification

- Independent content review (pass 1): COMMENT review by
  `cedagova-codex-reviewer[bot]` on candidate head `f14afd7e`
  (https://github.com/cedagova/synth/pull/9#pullrequestreview-5043698917),
  verdict content-satisfied; its three advisory findings (REQ-018 in-increment
  verification, REQ-027 coverage of INS001/INS003, REQ-003 cross-increment
  cascade) are folded into this revision and the published leaves.
- Leaf issues #10–#25 published 2026-08-27; tracking metadata added to root
  #1 and GROUP/sequence/delivery metadata to increments #3–#8, preserving all
  definition content.
- `plan validate --phase publication-ready`: valid (23 manifest rows).
- `plan reconcile-graph`: attached all 16 leaves to their increments; added
  the five increment predecessor edges and eleven intra-increment leaf edges.
- `plan verify-graph`: live native graph matches the manifest exactly
  (23 rows valid, 2026-08-27).
- Final exact-head validation (`ready-for-implementation` with head and
  reviewed head) runs after the official exact-head review; the native PR
  review is the approval record.
