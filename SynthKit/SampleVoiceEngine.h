/*
 SampleVoiceEngine.h — the sampled-instrument player (INS002, REQ-020), as the
 render thread sees it.

 This is the second implementation of the line-voice interface in
 `SynthAudioCore.h`. The synthesizer (SYN001) computes its output from a
 `SynthPatchConfig`; this one reads it out of downloaded WAV files that INS001
 installed. Everything above the vtable — the engine, the transport, the mixer,
 the offline render path, presets and export — is identical for both, which is
 the entire point of the boundary PLY003 drew.

 **The instrument is data, and the voice is state.** A `SampleInstrumentData`
 is a flat, immutable table of regions and waveforms with no Swift object
 behind it: the Swift side builds it once on the control thread, and the render
 thread only ever reads it. A `SampleVoiceState` is one line's playing voice
 over that table. Several lines assigned the same instrument share one table
 and hold one voice each, so two violin lines cost one copy of the samples.

 **Sample bytes are memory-mapped, and reading them is the one real-time risk
 in this file.** A mapped page that is not resident faults, and a fault on the
 audio thread is a blocking read. The mitigation is entirely on the control
 side — `SampledInstrument` faults in each waveform's attack region when the
 instrument is loaded — and the residual risk is a cold page deep inside a long
 sample. `RealtimePlaybackTests` measures what that costs against the
 orchestral reference rather than assuming it is free.

 Threading, the same contract as the rest of the render core:

   - Control thread: `sample_voice_create`, `sample_voice_destroy`, and
     building the `SampleInstrumentData` those are handed. Free to allocate.
     Lives in `SampleVoiceSetup.c`.
   - Render thread: only the vtable callbacks. `SampleVoiceEngine.c` contains
     those and nothing else, and `RealtimeSafetyTests` scans it for allocation,
     locks and runtime calls exactly as it scans the other two render cores.
 */

#ifndef SAMPLE_VOICE_ENGINE_H
#define SAMPLE_VOICE_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#include "SynthAudioCore.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Limits

/*
 Simultaneously sounding sample players in one line's voice.

 Higher than the synthesizer's 32 for two reasons that are specific to
 sampling: a pedalled piano line holds far more notes than it plays, and one
 note-off can start release-trigger regions of its own on top of the notes
 still ringing. 128 covers the densest bar of the orchestral reference with
 room to spare, and costs about 20 kB of voice state.
 */
#define SAMPLE_VOICE_MAX_SLOTS 128

/// Sounding notes one voice can remember for the sustain pedal and for release
/// triggers. One entry per key is exactly enough: a line cannot hold the same
/// key twice.
#define SAMPLE_VOICE_KEY_COUNT 128

#pragma mark - Sample data

/// How one waveform's frames are stored in the mapped file.
typedef enum SampleFrameFormat {
    SampleFrameFormatPCM16   = 0,
    SampleFrameFormatPCM24   = 1,
    SampleFrameFormatPCM32   = 2,
    SampleFrameFormatFloat32 = 3,
    SampleFrameFormatFloat64 = 4
} SampleFrameFormat;

/*
 One sample file, as bytes the render thread can interpolate.

 `frames` points at the first frame of the file's `data` chunk — normally
 inside a read-only mapping of the file, which is why nothing here owns it. The
 Swift `SampledInstrument` owns every mapping and outlives every voice over it.
 */
typedef struct SampleWaveformData {
    /// First byte of the first frame. Read-only, never freed by this engine.
    const void *frames;

    /// Frames available, already divided by the channel count.
    int64_t frameCount;

    /// 1 or 2. More channels than that are rejected when the file is read.
    int32_t channelCount;

    /// A `SampleFrameFormat`.
    int32_t format;

    /// The file's own rate. Playback rate is derived from this and the engine's
    /// rate, so a 48 kHz sample in a 44.1 kHz render is resampled rather than
    /// transposed.
    double sampleRate;

    /// Loop points from the file's `smpl` chunk, or -1 when it declares none.
    /// An SFZ `loop_start`/`loop_end` on a region overrides these.
    int64_t fileLoopStart;
    int64_t fileLoopEnd;
} SampleWaveformData;

/// What starts a region.
typedef enum SampleRegionTrigger {
    /// `trigger=attack` (the default): a note going down.
    SampleRegionTriggerAttack  = 0,
    /// `trigger=release`: a note coming up. Salamander's string resonances and
    /// hammer noise are these.
    SampleRegionTriggerRelease = 1,
    /// `trigger=first` / `trigger=legato`. Parsed, reported, never started —
    /// nothing in the curated set uses them.
    SampleRegionTriggerOther   = 2
} SampleRegionTrigger;

/// What a region does when it reaches its loop end.
typedef enum SampleLoopMode {
    /// Play to the end of the sample and stop.
    SampleLoopModeNone       = 0,
    /// Loop for as long as the region sounds.
    SampleLoopModeContinuous = 1,
    /// Loop while the note is held; play through the loop end after note-off.
    SampleLoopModeSustain    = 2,
    /// Play to the end regardless of note-off.
    SampleLoopModeOneShot    = 3
} SampleLoopMode;

/*
 One `<region>`, with its `<global>`, `<master>` and `<group>` inheritance
 already resolved.

 Plain old data with no pointers except the waveform index, so an instrument
 table is one contiguous allocation and two engines given the same table and
 the same events produce the same samples.
 */
typedef struct SampleRegionData {
    /// Index into `SampleInstrumentData.waveforms`.
    int32_t waveformIndex;

    int32_t loKey, hiKey;
    int32_t loVelocity, hiVelocity;

    /// `pitch_keycenter`. The key at which the sample plays back untransposed.
    int32_t pitchKeycenter;

    /// `tune` and `transpose` folded into one figure, in semitones.
    float tuneSemitones;

    /// `pitch_keytrack`/100. 1 is normal; 0 pins the sample to its recorded
    /// pitch, which is how Salamander's hammer noise stays a thud.
    float pitchKeytrack;

    /// `volume` converted out of decibels.
    float gainLinear;

    /// `amp_veltrack`/100. 1 makes loudness follow velocity squared; 0 makes
    /// the region play at one level whatever the velocity.
    float ampVelocityTracking;

    /// `ampeg_*`, in seconds and 0…1.
    float attackSeconds, decaySeconds, sustainLevel, releaseSeconds;

    /// A `SampleRegionTrigger`.
    int32_t trigger;

    /// `rt_decay`, in decibels per second of held time. A release sample of a
    /// note that was held for four seconds at 6 dB/s is 24 dB quieter than one
    /// released immediately, which is what makes a piano's release layer track
    /// the note rather than punctuate it.
    float releaseTriggerDecayDBPerSecond;

    /// A `SampleLoopMode`, and the points it uses. -1 means "take the file's".
    int32_t loopMode;
    int64_t loopStart, loopEnd;

    /// `offset` and `end`, in frames. `sampleEnd` is -1 for "to the end".
    int64_t sampleOffset, sampleEnd;

    /// `seq_length`/`seq_position`, 1-based. A length of 1 is "always".
    int32_t sequenceLength, sequencePosition;

    /// `lorand`/`hirand`. The default 0…1 accepts every draw.
    float randomLow, randomHigh;

    /// `sw_last` (or `sw_default` when the group only declares that), or -1
    /// when this region is not behind a keyswitch.
    int32_t switchKey;
} SampleRegionData;

/*
 One instrument: every region, every waveform, and the index that makes
 note-on a bounded scan instead of a walk over all 641 of Salamander's regions.
 */
typedef struct SampleInstrumentData {
    const SampleWaveformData *waveforms;
    int32_t waveformCount;

    const SampleRegionData *regions;
    int32_t regionCount;

    /*
     Region indices grouped by key: the regions that can sound for key `k` are
     `keyRegions[keyRegionStart[k] ..< keyRegionStart[k + 1]]`.

     `keyRegionStart` has `SAMPLE_VOICE_KEY_COUNT + 1` entries. Building this
     costs one pass on the control thread and turns every note-on into a scan
     over the handful of regions that can possibly match, which is what keeps
     the audio thread's worst case bounded and independent of library size.
     */
    const int32_t *keyRegions;
    const int32_t *keyRegionStart;

    /// The keyswitch a voice starts on (`sw_default`), or -1 when the
    /// instrument has no keyswitches.
    int32_t defaultSwitchKey;

    /// The key range reserved for keyswitches, or -1/-1 when there is none.
    /// A note landing in it selects an articulation and sounds nothing.
    int32_t switchLowKey, switchHighKey;
} SampleInstrumentData;

#pragma mark - Customization

/*
 The bounded parameter set INS003 lets the owner put over a recorded instrument
 (REQ-021, D7), in the units the render loop actually uses.

 **Nothing here rewrites a sample.** Each field is applied while the recorded
 audio is being played back: a shelf on the voice's output, a multiplier on the
 playback rate, a scale on the envelope the SFZ file declared. The downloaded
 library stays exactly as it was installed, which is what makes "variants never
 mutate the downloaded assets" a property of this interface rather than a rule
 somebody has to keep.

 Decibels and cents are converted on the Swift side, so this struct holds only
 ratios the render loop can multiply by. The one exception is
 `vibratoDepthCents`, which has to reach the loop as cents because it modulates
 a ratio rather than being one.

 A field the instrument cannot honestly support has already been put back to
 its neutral value by `InstrumentCapabilities.bounded` before it gets here.
 This engine does not second-guess that: it applies what it is given, and
 neutral values cost nothing because each one short-circuits below.
 */
typedef struct SampleVoiceCustomization {
    /// Linear gain of the low shelf. 1 is flat.
    float toneLowGain;

    /// Linear gain of the high shelf. 1 is flat.
    float toneHighGain;

    /// Exponent applied to the region's velocity-derived level. 1 leaves the
    /// library's own response exactly as recorded; above 1 widens the gap
    /// between soft and loud, below 1 narrows it.
    float dynamicsResponse;

    /// Extra attack time added to whatever the region declares, in seconds.
    /// Never negative: softening an attack is adding to the recording, and
    /// there is no way to make a sample start sooner than it was recorded.
    float attackSecondsAdded;

    /// Multiplier on the region's own release time. 1 leaves it as recorded.
    float releaseScale;

    /// Peak vibrato excursion in cents, 0 for none.
    float vibratoDepthCents;

    /// Vibrato rate in hertz.
    float vibratoRateHz;

    /// Constant playback-rate multiplier for the tuning offset. 1 is A=440 as
    /// the library recorded it.
    float tuningRatio;
} SampleVoiceCustomization;

/// The instrument exactly as recorded: every field neutral.
SampleVoiceCustomization sample_voice_customization_neutral(void);

#pragma mark - Silence

/*
 Fill `outVoice` with the stateless voice that renders silence.

 The vtable a line gets when it has an instrument to play and no way to play it
 — not downloaded, files gone, or a voice that could not be allocated. It holds
 no state, needs no teardown, and writes zeroes.

 **Silence rather than a substitute is the product decision, not a fallback.**
 Issue #24 requires a line to be flagged and substituted only with the owner's
 explicit acknowledgment, so a line whose cello is missing plays nothing and
 says so. Handing it a synth patch instead would reach the prohibited end state
 by the pleasanter route, which is why this exists as a named, public thing
 rather than as an accident of a null check.
 */
void sample_voice_fill_silence(SynthLineVoice *outVoice);

#pragma mark - Voice

typedef struct SampleVoiceState SampleVoiceState;

/*
 Build one voice over `instrument` and fill `outVoice` with the vtable the
 engine will call. Control thread only; this is the one function here that
 allocates.

 `instrument`, its tables, and every mapping their waveforms point at must
 outlive the voice.

 **Returns NULL when it cannot allocate, and fills `outVoice` with a voice that
 renders silence.** The engine is handed a vtable either way, because a line
 whose voice failed to build must still be a line the render thread can call
 into without checking. Silence rather than a substitute sound is deliberate:
 INS003 (#24) requires a line to be flagged and substituted only with the
 owner's explicit acknowledgment, and quietly playing a synthesizer where a
 cello was assigned would reach that prohibited end state by another route. The
 Swift side records the failure so INS003 has something to flag.

 `seed` makes round-robin and random region selection reproducible: the same
 seed and the same note sequence pick the same samples, on every run and on
 every machine, which is what REQ-012 and REQ-026 need from a sampler that
 deliberately varies. `reset` returns the sequence to its start, so seeking
 does not shift what a passage sounds like either.
 */
SampleVoiceState *sample_voice_create(const SampleInstrumentData *instrument,
                                      SynthLineVoice *outVoice,
                                      double sampleRate,
                                      uint64_t seed);

/// Free a voice built by `sample_voice_create`. Control thread, after the
/// engine holding it has been destroyed.
void sample_voice_destroy(SampleVoiceState *state);

/*
 Put a new customization on a voice that may already be rendering.

 **Control thread, safe while rendering**, on the same terms as the engine's
 own mixer accessors in `SynthAudioCore.h`: every field crosses as one
 naturally aligned relaxed atomic, so no value can tear and the change lands
 within one buffer. Two fields of one edit may land on either side of a block
 boundary — a four-millisecond disagreement between, say, the low and high
 shelf — which is inaudible and is what the same contract already accepts for
 gain and pan.

 This is what makes a customization editable while the piece plays, without
 rebuilding the render program and therefore without stopping the music: the
 sampler's version of the path SYN001 opened for a synth patch (REQ-018).

 Values are clamped here rather than trusted, because this is a public entry
 point and a NaN reaching the render loop would silence the line.
 */
void sample_voice_set_customization(SampleVoiceState *state,
                                    const SampleVoiceCustomization *customization);

/// What the voice is currently rendering with. Control thread; for tests and
/// for a caller that needs to prove an edit arrived.
SampleVoiceCustomization sample_voice_customization(const SampleVoiceState *state);

/// How many customizations this voice has taken up since it was built.
///
/// The sampler's counterpart to `synth_patch_voice_adoptions`, and for the same
/// reason: it lets a caller prove that an edit reached the voices that are
/// actually sounding rather than assume it.
int64_t sample_voice_customization_adoptions(const SampleVoiceState *state);

#pragma mark - Telemetry (render thread writes, control thread reads)

/*
 Notes this voice could not sound because every slot was busy.

 A sampler steals its oldest slot rather than dropping a note, so this is not a
 count of lost notes; it is the count of times the ceiling was reached, which
 is the number that says whether `SAMPLE_VOICE_MAX_SLOTS` is big enough for
 real music. Zero over the orchestral reference is the claim INS002 makes.
 */
int64_t sample_voice_stolen_slots(const SampleVoiceState *state);

/// Note-ons that matched no region at all — a key outside the instrument's
/// sampled range. Reported rather than silently ignored, because a line
/// assigned an instrument that cannot play its part should be visible.
int64_t sample_voice_unmapped_notes(const SampleVoiceState *state);

/// The highest number of slots that ever sounded at once.
///
/// Survives `reset`, unlike the voice's audible state: the engine resets every
/// voice on stop and on seek, and a peak a seek erased would make the numbers
/// say the line was easier to render than it was.
int32_t sample_voice_peak_slots(const SampleVoiceState *state);

#ifdef __cplusplus
}
#endif

#endif /* SAMPLE_VOICE_ENGINE_H */
