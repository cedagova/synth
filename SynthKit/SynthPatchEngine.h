/*
 SynthPatchEngine.h — the synthesizer (SYN001, REQ-016), as the render thread
 sees it.

 One `SynthPatchConfig` fully determines one sound. It is plain old data with
 no pointers, so a patch loaded from disk becomes a rendering voice by copying
 a struct, and two engines given the same struct and the same events produce
 the same samples.

 **The architecture is fixed; only the parameters vary (D6).** There is no
 modular patching and no user-visible routing graph. Every voice is:

     osc1 ┐
     osc2 ┼→ mix → filter → VCA (amplitude envelope × velocity) → voice
     osc3 ┤
     noise┘

 and every patch's summed voices then run through one fixed effect chain:

     voices → EQ → chorus → delay → reverb → soft limiter → out

 The only thing that varies is where the modulation matrix routes its eight
 sources and how much. That is the whole ceiling REQ-016 asks for and the
 whole ceiling D6 permits.

 **Mono, deliberately.** The line-voice interface renders mono because the
 engine owns gain, pan, mute and solo (see `SynthLineVoice` in
 `SynthAudioCore.h`). The effects here are therefore mono too: a stereo
 per-sound reverb would place the sound itself in the image and the engine's
 equal-power pan law would no longer describe where a line sits.

 Threading, same contract as the rest of the render core:

   - Control thread: `synth_patch_voice_state_size`, `synth_patch_config_*`,
     `synth_patch_voice_init`. Free to be slow; still never allocates — the
     caller owns the storage.
   - Render thread: only the vtable callbacks filled in by
     `synth_patch_voice_init`. `SynthPatchEngine.c` contains those and nothing
     else, and `RealtimeSafetyTests` scans it for allocation, locks and
     runtime calls exactly as it scans `SynthAudioCore.c`.
 */

#ifndef SYNTH_PATCH_ENGINE_H
#define SYNTH_PATCH_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#include "SynthAudioCore.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Fixed topology

/// Oscillators per voice. Fixed: this is the topology D6 pins down.
#define SYNTH_PATCH_OSCILLATOR_COUNT 3
/// Low-frequency oscillators per voice.
#define SYNTH_PATCH_LFO_COUNT 2
/// Modulation matrix slots. Eight is enough for every sound the shipped
/// collection needs and small enough to evaluate at control rate for free.
#define SYNTH_PATCH_MOD_SLOT_COUNT 8
/// Simultaneous notes one patch may sound. Matches the engine's own ceiling.
#define SYNTH_PATCH_MAX_VOICES 32

/*
 Highest sample rate the preallocated effect buffers are sized for.

 A voice prepared above this still renders at the device's real rate — pitch,
 envelopes, LFOs and the filter all follow it exactly — but the effect chain's
 buffer lengths are derived from this cap instead. Above it the reverb's room
 and the maximum delay time are slightly shorter than the patch asked for.

 The alternative would be worse in a specific way: every reverb comb would
 saturate to the same maximum length, and eight identical combs ring like one
 comb rather than sounding like a room.
 */
#define SYNTH_PATCH_MAX_SAMPLE_RATE 96000.0

#pragma mark - Enumerated parameters

/// Oscillator kind. Anonymous so each constant crosses into Swift as an
/// `Int32`, which is what the config fields are.
enum {
    /// Band-limited analogue waveform: sine, triangle, saw, square or pulse.
    SynthOscillatorTypeAnalog    = 0,
    /// Four-frame wavetable, morphed continuously by `shapeAmount`.
    SynthOscillatorTypeWavetable = 1,
    /// Two-operator FM: sine carrier, sine modulator at `fmRatio`, depth
    /// `shapeAmount`.
    SynthOscillatorTypeFM        = 2
};

enum {
    SynthAnalogShapeSine     = 0,
    SynthAnalogShapeTriangle = 1,
    SynthAnalogShapeSaw      = 2,
    SynthAnalogShapeSquare   = 3,
    /// Variable-width pulse. Width is `shapeAmount`, so the mod matrix can
    /// sweep it — the classic PWM sound.
    SynthAnalogShapePulse    = 4
};

/// Wavetable banks. Four frames each; `shapeAmount` picks a position between
/// them and the read interpolates, so a slow LFO on the position is a sweep
/// rather than four steps.
enum {
    /// Sine through saw: harmonic amplitudes roll off less steeply per frame.
    SynthWavetableBankHarmonic = 0,
    /// A resonant peak that climbs the harmonic series — vocal/formant-like.
    SynthWavetableBankFormant  = 1,
    /// Sparse upper partials; metallic, bell-like.
    SynthWavetableBankMetallic = 2,
    /// Odd harmonics only; hollow, clarinet-like.
    SynthWavetableBankHollow   = 3
};
#define SYNTH_WAVETABLE_BANK_COUNT 4
/// Frames per bank.
#define SYNTH_WAVETABLE_FRAME_COUNT 4

enum {
    SynthFilterTypeLowpass  = 0,
    SynthFilterTypeHighpass = 1,
    SynthFilterTypeBandpass = 2,
    SynthFilterTypeNotch    = 3
};

enum {
    SynthLFOShapeSine         = 0,
    SynthLFOShapeTriangle     = 1,
    SynthLFOShapeSaw          = 2,
    SynthLFOShapeSquare       = 3,
    /// Stepped random, seeded per render so it is repeatable.
    SynthLFOShapeSampleAndHold = 4
};

/// Modulation sources.
enum {
    SynthModSourceNone              = 0,
    SynthModSourceAmplitudeEnvelope = 1,
    SynthModSourceModulationEnvelope = 2,
    SynthModSourceLFO1              = 3,
    SynthModSourceLFO2              = 4,
    /// Note velocity, 0…1.
    SynthModSourceVelocity          = 5,
    /// Note number relative to middle C, -1…1 across the keyboard.
    SynthModSourceKeyTrack          = 6,
    /// One seeded random value per note, -1…1. Deterministic for a given seed
    /// and event sequence.
    SynthModSourceNoteRandom        = 7
};
#define SYNTH_MOD_SOURCE_COUNT 8

/// Modulation destinations. Voice-level only: nothing here can reach the
/// engine's mixer, because gain, pan, mute and solo are the engine's.
enum {
    SynthModDestinationNone            = 0,
    /// ±24 semitones at full amount.
    SynthModDestinationOscillator1Pitch = 1,
    SynthModDestinationOscillator2Pitch = 2,
    SynthModDestinationOscillator3Pitch = 3,
    /// Scales the oscillator's level, 0…2×.
    SynthModDestinationOscillator1Level = 4,
    SynthModDestinationOscillator2Level = 5,
    SynthModDestinationOscillator3Level = 6,
    /// Offsets `shapeAmount`: pulse width, wavetable position, or FM depth.
    SynthModDestinationOscillator1Shape = 7,
    SynthModDestinationOscillator2Shape = 8,
    SynthModDestinationOscillator3Shape = 9,
    /// ±6 octaves at full amount.
    SynthModDestinationFilterCutoff    = 10,
    SynthModDestinationFilterResonance = 11,
    /// Scales the whole voice, 0…2×.
    SynthModDestinationAmplitude       = 12
};
#define SYNTH_MOD_DESTINATION_COUNT 13

#pragma mark - Parameter blocks

typedef struct SynthOscillatorConfig {
    /// `SynthOscillatorType*`.
    int32_t type;
    /// `SynthAnalogShape*` when analogue, `SynthWavetableBank*` when
    /// wavetable, ignored for FM.
    int32_t shape;
    /// 0…1, before modulation.
    float   level;
    /// -48…48, added to the note's pitch.
    float   detuneSemitones;
    /// -100…100, on top of `detuneSemitones`.
    float   detuneCents;
    /// The one continuous per-oscillator control the mod matrix can reach,
    /// always normalised 0…1 here and mapped by type: pulse width
    /// (0.05…0.95), wavetable position (frame 0 → frame 3), or FM depth
    /// (0 → `SYNTH_FM_MAX_INDEX` radians).
    float   shapeAmount;
    /// FM modulator : carrier frequency ratio, 0.25…16. Ignored otherwise.
    float   fmRatio;
    /// Non-zero: phase restarts at `startPhase` on every note-on. Zero: the
    /// oscillator free-runs from wherever the voice left it, which is what
    /// makes repeated notes sound slightly different on an analogue synth.
    int32_t retriggersPhase;
    /// 0…1.
    float   startPhase;
} SynthOscillatorConfig;

/// Full FM depth in radians at `shapeAmount == 1`.
#define SYNTH_FM_MAX_INDEX 8.0f

typedef struct SynthFilterConfig {
    /// Zero bypasses the filter entirely. A patch with no filtering is a real
    /// patch — the shipped default voice is one — and bypassing is cheaper and
    /// more honest than a cutoff parked above Nyquist.
    int32_t isEnabled;
    /// `SynthFilterType*`.
    int32_t type;
    /// 2 or 4. Four poles is two identical stages in series.
    int32_t poles;
    /// 20…20000, clamped to 0.45 × sample rate at prepare time.
    float   cutoffHertz;
    /// 0…1. Maps to a state-variable damping of 2 → 0.1, so the filter is
    /// resonant but never self-oscillates.
    float   resonance;
    /// 0…1. How far the cutoff follows the note: 1 tracks the keyboard
    /// one-for-one about middle C.
    float   keyTracking;
} SynthFilterConfig;

typedef struct SynthEnvelopeConfig {
    float attackSeconds;   /* 0.0005…10 */
    float decaySeconds;    /* 0.001…20  */
    float sustainLevel;    /* 0…1       */
    float releaseSeconds;  /* 0.001…20  */
    /// 0 is a straight line, 1 is the fast-then-slow curve of an analogue
    /// envelope. The shipped default voice is linear, which is what makes it
    /// an exact continuation of increment 002's built-in sound.
    float curve;           /* 0…1       */
} SynthEnvelopeConfig;

typedef struct SynthLFOConfig {
    /// `SynthLFOShape*`.
    int32_t shape;
    float   rateHertz;   /* 0.01…40 */
    float   startPhase;  /* 0…1     */
    /// Non-zero: the LFO restarts at `startPhase` on each note-on, so every
    /// note has the same shape. Zero: it free-runs across the whole patch, so
    /// a chord moves together.
    int32_t retriggersPerNote;
} SynthLFOConfig;

typedef struct SynthModulationSlotConfig {
    /// `SynthModSource*`.
    int32_t source;
    /// `SynthModDestination*`.
    int32_t destination;
    /// -1…1.
    float   amount;
} SynthModulationSlotConfig;

/// Three bands: low shelf, peaking mid, high shelf. Coefficients are computed
/// once, on the control thread, because nothing modulates them.
typedef struct SynthEqualizerConfig {
    int32_t isEnabled;
    float   lowGainDecibels;   /* -24…24 */
    float   lowHertz;          /* 30…1000 */
    float   midGainDecibels;   /* -24…24 */
    float   midHertz;          /* 100…8000 */
    float   midQ;              /* 0.2…8 */
    float   highGainDecibels;  /* -24…24 */
    float   highHertz;         /* 1000…16000 */
} SynthEqualizerConfig;

typedef struct SynthChorusConfig {
    int32_t isEnabled;
    float   rateHertz;        /* 0.01…8   */
    float   depthMilliseconds;/* 0.5…20   */
    float   centreMilliseconds;/* 1…30    */
    float   mix;              /* 0…1      */
    /// Clamped to 0.7 so the two taps cannot run away.
    float   feedback;         /* 0…0.7    */
} SynthChorusConfig;

typedef struct SynthDelayConfig {
    int32_t isEnabled;
    float   timeSeconds;  /* 0.005…1  */
    /// Clamped to 0.85, and the feedback path is damped, so the tail always
    /// decays. This is the runaway-feedback guarantee the issue asks for.
    float   feedback;     /* 0…0.85   */
    float   mix;          /* 0…1      */
    /// 0 is a bright repeat, 1 loses the top of every pass.
    float   dampening;    /* 0…1      */
} SynthDelayConfig;

typedef struct SynthReverbConfig {
    int32_t isEnabled;
    float   roomSize;        /* 0…1, comb feedback 0.7…0.98 */
    float   dampening;       /* 0…1 */
    float   mix;             /* 0…1 */
    float   preDelaySeconds; /* 0…0.1 */
} SynthReverbConfig;

#pragma mark - The patch

/*
 One complete sound. Plain old data, no pointers, no padding that matters:
 `SynthPatchDocument` serialises the Swift model this mirrors, and
 `synth_patch_voice_init` copies this whole struct into the voice, so a
 rendering voice can never observe a half-applied patch.
 */
typedef struct SynthPatchConfig {
    SynthOscillatorConfig oscillators[SYNTH_PATCH_OSCILLATOR_COUNT];
    /// White noise mixed in alongside the oscillators, per voice, so it is
    /// shaped by the same filter and envelope. Seeded — see `seed`.
    float                 noiseLevel;          /* 0…1 */

    SynthFilterConfig     filter;
    SynthEnvelopeConfig   amplitudeEnvelope;
    SynthEnvelopeConfig   modulationEnvelope;
    SynthLFOConfig        lfos[SYNTH_PATCH_LFO_COUNT];
    SynthModulationSlotConfig modulation[SYNTH_PATCH_MOD_SLOT_COUNT];

    SynthEqualizerConfig  equalizer;
    SynthChorusConfig     chorus;
    SynthDelayConfig      delay;
    SynthReverbConfig     reverb;

    /// 1…32.
    int32_t maximumVoices;
    /// Final level for the whole patch, 0…1. The engine still owns line gain;
    /// this is the sound's own loudness relative to other sounds.
    float   outputLevel;
    /// Exponent applied to velocity/127 before it becomes amplitude. 1 is
    /// linear; above 1 makes soft playing softer. 0.2…4.
    float   velocitySensitivity;

    /// Seeds noise, sample-and-hold LFOs and the per-note random source, so
    /// "same patch + same events + same seed → same audio" is a property of
    /// the engine rather than an accident.
    uint64_t seed;
} SynthPatchConfig;

#pragma mark - Control-thread entry points

/// Fill `config` with the shipped default voice: three sine partials at 1×,
/// 2× and 3× through a linear ADSR, no filter, no effects.
///
/// This is AD7's transitional built-in voice re-expressed as a patch. It is
/// here rather than only in Swift so that the C side has a known-good starting
/// point, and so a `SynthPatchConfig` is never observed uninitialised.
void synth_patch_config_default(SynthPatchConfig *config);

/*
 Element setters for the three fixed-size arrays in `SynthPatchConfig`.

 A C array crosses into Swift as a tuple, which cannot be subscripted, so the
 alternative is `withUnsafeMutablePointer` and a memory rebind at every call
 site. These keep that pointer arithmetic on the C side, where the layout is
 already known. Out-of-range indices are ignored rather than trapping: the
 caller is Swift code that already knows the counts, and a crash in a setter
 would be a worse outcome than a no-op.
 */
void synth_patch_config_set_oscillator(SynthPatchConfig *config, int32_t index,
                                       const SynthOscillatorConfig *oscillator);
void synth_patch_config_set_lfo(SynthPatchConfig *config, int32_t index,
                                const SynthLFOConfig *lfo);
void synth_patch_config_set_modulation(SynthPatchConfig *config, int32_t index,
                                       const SynthModulationSlotConfig *slot);

/// Clamp every field into its documented range in place.
///
/// Called by `synth_patch_voice_init`, and safe to call directly. This is the
/// last line of defence: a patch document is validated on load, but the render
/// thread must be unable to receive an out-of-range value even if some future
/// caller skips that.
void synth_patch_config_sanitize(SynthPatchConfig *config);

/// Bytes of storage one voice needs. The caller allocates; nothing in the
/// engine does.
size_t synth_patch_voice_state_size(void);
/// Alignment that storage needs.
size_t synth_patch_voice_state_alignment(void);

typedef struct SynthPatchVoiceState SynthPatchVoiceState;

/// Initialise a voice in caller-provided storage and fill `outVoice` with the
/// vtable the engine will call. Control thread only.
void synth_patch_voice_init(SynthPatchVoiceState *state,
                            SynthLineVoice *outVoice,
                            double sampleRate,
                            const SynthPatchConfig *config);

/// Build the shared band-limited wavetables. Idempotent, control thread.
/// `synth_patch_voice_init` calls it; exposed so a test can time it separately
/// from rendering.
void synth_patch_prepare_tables(void);

#pragma mark - Live editing (control thread, safe while rendering)

/*
 SYN003's editor changes a sound the owner is currently listening to, and the
 acceptance criterion is that playback does not stop to let it. These three
 calls are the only way a patch or a note reaches a voice that is already
 rendering; nothing else in this header is safe while `render` is running.

 All three are **single-producer**: one control thread at a time per voice. The
 Swift side (`SynthPatchLiveVoices`) is what enforces that, and it also
 serialises them against a voice being released.
*/

/// Publish a complete replacement patch to a voice that may be rendering.
///
/// The patch is sanitised and fully worked out here, on the calling thread; the
/// render thread's share is a copy into place at its next block boundary, so an
/// edit is audible within one buffer and the audio never stops. Effect
/// histories, oscillator phases and sounding notes all survive it — this
/// changes what the voice is, not where it is.
///
/// Returns 1 when the patch was staged. Returns 0 when `sampleRate` is not the
/// rate this voice was prepared at, which means the caller is holding a voice
/// from a graph that has since been rebuilt and must build a new one; the
/// voice is left exactly as it was.
int32_t synth_patch_voice_publish(SynthPatchVoiceState *state,
                                  const SynthPatchConfig *config,
                                  double sampleRate);

/// How many published patches this voice has actually taken up.
///
/// The render thread writes it. A caller reads it to know that an edit reached
/// the audio rather than merely reaching the queue — the difference between a
/// test that proves live editing and one that proves a function was called.
int64_t synth_patch_voice_adoptions(const SynthPatchVoiceState *state);

/// Play, release, pedal or silence a note on a voice that may be rendering —
/// the editor's test notes, which have no timeline behind them.
///
/// `kind` is one of the `SynthLiveEvent*` constants. Events are taken up at the
/// start of the next render block, so a note sounds within one buffer of the
/// key going down. Returns 0 only when the queue is full, which the caller
/// should report rather than ignore: a dropped note-off is a stuck note.
int32_t synth_patch_voice_post_event(SynthPatchVoiceState *state,
                                     int32_t kind,
                                     int32_t midiNoteNumber,
                                     int32_t velocity);

/// `SynthLiveEvent*`, as ordinary `Int32`s on the Swift side.
int32_t synth_patch_live_event_note_on(void);
int32_t synth_patch_live_event_note_off(void);
int32_t synth_patch_live_event_pedal(void);
int32_t synth_patch_live_event_all_off(void);

#pragma mark - Auditioning one voice on its own (render thread)

/*
 Render one patch straight into a stereo buffer list, with no engine, no
 timeline and no mixer.

 The editor auditions a sound before it belongs to any piece, so there is
 nothing for `synth_audio_core_render` to render: no program, no lines, no
 events. This is the whole audio path for that case. It exists in C for the
 same reason everything else the audio thread runs does — the alternative is a
 Swift loop copying mono into two channels, on the render thread.
*/
int32_t synth_patch_voice_render_stereo(SynthPatchVoiceState *state,
                                        AudioBufferList *bufferList,
                                        int32_t frameCount,
                                        int32_t *isSilence);

#ifdef __cplusplus
}
#endif

#endif /* SYNTH_PATCH_ENGINE_H */
