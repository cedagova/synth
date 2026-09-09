# Switched-On Bach, and the "Baroque Modular" shipped collection

Research notes behind the twelve `shipped.*` sounds added in September 2026,
and the audit of the thirteen that were already there. The goal was stated by
the owner: be able to replicate, to a reasonable degree, what Wendy Carlos did
on *Switched-On Bach* (1968), with sounds that are synthesizer sounds rather
than imitations of the sampled instruments.

## What is documented about how the album was made

Sources are listed at the end. Everything in this section is from them.

- **The instrument.** A Moog modular system built for Carlos, who had worked
  with Robert Moog testing modules and suggesting improvements. It offered a
  small number of oscillators with four waveforms (sine, triangle, pulse,
  sawtooth), a white-noise source, a low-pass filter used to mellow a wave,
  add resonance, or take out the bottom, and envelope generators with attack,
  decay, sustain and release in the form Vladimir Ussachevsky had proposed.
  The attack was set slow for an organ-like tone and fast for a plucked one;
  decay immediate for a harpsichord-like tone; release short and dry or
  longer for a resonant body.
- **Two additions Carlos asked for.** A *fixed filter bank* (a bank of
  band-pass filters used to impose formant-like resonances on a wave) and a
  *touch-sensitive keyboard*, so that playing harder changed the sound. There
  were no sustain or expression pedals.
- **Monophonic, one line at a time.** The synthesizer played one note at a
  time. Every line of every piece was played separately and overdubbed on a
  custom 8-track Ampex machine, then mixed to stereo. Carlos: "You had to
  release the note before you could make the next note start, which meant you
  had to play with a detached feeling on the keyboard." Moog later built a
  component that could trigger chords. The album took about five months and
  a thousand hours.
- **Expression was played, not programmed.** Filter, oscillator and envelope
  controls were adjusted with one hand while the melody was played with the
  other. Some notes were doubled on a second track with a different timbre.
- **Tuning drift.** The oscillators drifted; the synthesizer was tuned before
  each take and re-checked after a few notes.
- **How it was described.** Reviewers heard instruments that "huffed,
  wheezed, and clanked like an intergalactic music box", and a "fuzzy,
  buzzing, droning, humming" analogue sound that fitted Bach.
- **The programme.** Sinfonia to Cantata 29; Air on the G String; three
  two-part Inventions (F, B-flat, D minor); *Jesu, Joy of Man's Desiring*;
  Preludes and Fugues in E-flat and C minor from WTC I; the chorale prelude
  *Wachet auf*; Brandenburg Concerto No. 3 complete, with a composed second
  movement over Bach's two chords.

## What is standard Moog practice (inferred, not sourced)

None of the sources give patch sheets. The following is how those modules are
normally used to get the timbres heard on the record, and it is what the new
sounds are built from.

| On the Moog | What it did | In Synth's architecture |
|---|---|---|
| 901 oscillator, sawtooth | Bowed strings, brass, the "buzzing" leads | `.analog .saw`, two of them a few cents apart |
| 901 oscillator, narrow pulse | Nasal reeds: the oboe/bassoon-like lines in *Wachet auf* and the Inventions | `.analog .pulse` with `shapeAmount` 0.10–0.25 |
| 901 oscillator, square / triangle / sine | Hollow flute and recorder tones, organ ranks, whistles | `.square`, `.triangle`, `.sine` |
| 904A low-pass ladder filter | 24 dB/octave, resonant; tracked the keyboard so a line stayed even across the register | `filter` low-pass, `poles: 4`, `keyTracking` 0.5–0.9 |
| 911 envelope on the filter | The brass "blip", the plucked click, the bow-pressure swell | `modulationEnvelope → filterCutoff` |
| Touch-sensitive keyboard | Harder playing was louder **and brighter** | `velocitySensitivity` plus `velocity → filterCutoff` |
| 914 fixed filter bank | Formant peaks that read as a body or a vowel | `equalizer` mid band with high Q, or the `formant` wavetable |
| Oscillator as LFO | Vibrato, added by hand on sustained lines | `lfo1 → oscillator pitch`, ~0.01 (a quarter-tone peak) |
| Noise source | Breath on flute-like tones | `noiseLevel` 0.05–0.1 |
| Ring modulator | Clangs and "clanks" | Two-operator FM at an inharmonic ratio |
| Spring reverb, then hall on the mix | Space | `reverb` with small `roomSize`, higher `dampening` |
| One voice at a time | Detached, spliced phrasing | `maximumVoices: 1` on one lead; modest polyphony elsewhere |

Two things the Moog had that this architecture does not: **portamento**
(no glide stage exists in the engine) and a **delayed vibrato** (an LFO's
depth cannot be ramped by an envelope). Both are noted as future engine work,
not faked.

## The new collection

Filed by role, because that is how auto-assignment (`PresetAutoAssignment`)
matches a score's part names: a "Trumpet" part lands on a Brass sound, a
"Flute" on a Lead, a "Harpsichord" on Keys.

| Sound | Category | Built from | For |
|---|---|---|---|
| Modular Harpsichord | Keys | Narrow pulse + saw at the octave, 4-pole filter, instant decay, a filter click | Continuo, the Inventions, WTC preludes |
| Sinfonia Organ | Keys | Square + pulse + 16' sine, flat envelope, church reverb | Cantata 29, *Wachet auf*, the chorales |
| Brandenburg Violin | Leads | Two saws, 4-pole filter swell, vibrato, body EQ | The Brandenburg upper lines, the Air |
| Ladder Mono Lead | Leads | One saw, resonant 4-pole filter, one voice | The "buzzing" solo lines, spliced feel |
| Wachet Reed | Leads | Two narrow pulses, formant EQ | Oboe/bassoon-like lines |
| Air Flute | Leads | Triangle + sine, breath noise, pitch chiff, tremolo vibrato | Flute/recorder lines, the Inventions |
| Cantata Trumpet | Brass | Saw + pulse, brass blip, velocity-driven brightness | Cantata 29, festive lines |
| Continuo Bass | Bass | Saw + square sub-octave, tracked filter | Bass lines under everything |
| Modular Cello | Strings | Saw + wide pulse, slower bow, vibrato, body EQ | Cello/viola lines in the Brandenburg |
| Chorale Vox | Pads | Formant wavetable + pulse, vowel drift | Sustained chorale textures |
| Clank Box | Bells | Inharmonic FM, bright strike decaying | The "intergalactic music box" |
| Pizzicato Pulse | Plucks | Pulse + triangle, fast filter pluck | Pizzicato and detached bass figures |

Every one of them routes velocity to the filter as well as to loudness, which
is the touch-sensitive keyboard's signature and the single most audible thing
in the album's phrasing.

## Audit of the thirteen sounds that were already shipped

Measured by `ShippedSoundAuditTests` (render C4 at velocity 40 and 120; hold
1.5 s; four seconds of tail).

| Finding | Sounds | Change |
|---|---|---|
| Velocity changed loudness only, never brightness (soft/loud centroid ratio 1.000) | 11 of 13 — all but Reso Bass and Brass Section | `velocity → filterCutoff` added wherever a filter exists |
| Still audible more than two seconds after release, on a lead | Hollow Lead (2.35 s), from a 375 ms delay at 0.35 feedback | Delay feedback and mix roughly halved on Hollow Lead and Bright Lead; a tempo-unrelated echo smears a fugue |
| Loudest-window level spread of 3.15× across the collection | Breath Pad and Bowed Strings quiet; Sub Bass loud | Output levels raised on Bowed Strings, Warm Analog Pad and Breath Pad |
| Default Voice: three sines, no filter | Default Voice | Left as is — it is the app's fallback identity and tests pin it |

## Sources

- [Switched-On Bach — Wikipedia](https://en.wikipedia.org/wiki/Switched-On_Bach)
- [Just How Pioneering Was Wendy Carlos' "Switched-On Bach"? — Reverb](https://reverb.com/news/wendy-carlos-pioneering-moog-synthesis-switched-on-bach)
- [Switched-On Bach — wendycarlos.com](https://www.wendycarlos.com/+sob.html)
- [Wendy Carlos's Switched on Bach Turns 50 — Open Culture](https://www.openculture.com/2018/10/wendy-carlos-switched-on-bach-turns-50.html)
- [Wendy Carlos — Britannica](https://www.britannica.com/biography/Wendy-Carlos)
- [Wendy Carlos Demonstrates the Moog Modular Behind 'Switched On Bach' — Synthtopia](https://www.synthtopia.com/content/2022/06/21/wendy-carlos-demonstrates-the-moog-modular-behind-switched-on-bach/)
- [The Moog — How the synthesiser gave J.S. Bach his first platinum record — GJE](https://www.gje.com/resources/the-moog-how-the-synthesiser-gave-j-s-bach-his-first-platinum-record/)
- [Modular synthesis intro, part 7: the Moog ladder filter — North Coast Synthesis](https://northcoastsynthesis.com/news/modular-synthesis-intro-part-7-the-moog-ladder-filter/)
- [Wendy Carlos: Synth Visionary — Classical California](https://www.classicalcalifornia.org/articles/wendy-carlos-synth-visionary)
- [Moog exhibition — Cornell University Library](https://exhibits.library.cornell.edu/moog)
