/*
 SynthPatchEngineInternal.h — the synthesizer's state layout.

 Private for the same reason the audio core's is: the public header keeps
 `SynthPatchVoiceState` incomplete so Swift can only reach it through the
 functions that know what to do with it, and so nothing here has to be
 expressible by the clang importer.

 Every buffer is sized for the worst case at compile time, because
 `synth_patch_voice_state_size` is what the control thread allocates and the
 render thread must never discover that a buffer grew.
 */

#ifndef SYNTH_PATCH_ENGINE_INTERNAL_H
#define SYNTH_PATCH_ENGINE_INTERNAL_H

#include "SynthPatchEngine.h"

#pragma mark - Shared tables

/// Wavetable length. A power of two so the index wrap is a mask.
#define SYNTH_WAVE_TABLE_SIZE 1024
#define SYNTH_WAVE_TABLE_MASK (SYNTH_WAVE_TABLE_SIZE - 1)

/*
 Mipmaps per waveform.

 A saw with every harmonic in it aliases the moment it is played above a few
 hundred hertz, and aliasing is exactly the kind of defect that makes a
 spectral test agree with a broken oscillator. So each waveform is stored once
 per octave, band-limited to the harmonics that still fit below Nyquist at the
 top of that octave.

 Mipmap `m` covers fundamentals in [20 × 2^m, 20 × 2^(m+1)) Hz. Eleven of them
 reach 40 kHz, which is past anything a MIDI note can ask for.
 */
#define SYNTH_WAVE_MIPMAP_COUNT 11
/// Lowest fundamental mipmap 0 covers.
#define SYNTH_WAVE_MIPMAP_BASE_HERTZ 20.0
/*
 Ceiling the tables are band-limited against.

 Fixed at build time rather than taken from the sample rate, because the tables
 are global and built once. 20 kHz is below the Nyquist frequency of every rate
 the app supports, so the tables are safe at 44.1 kHz and merely conservative
 at 96 kHz.
 */
#define SYNTH_WAVE_BAND_LIMIT_HERTZ 20000.0

/// Analogue waveforms that need band-limited tables. Sine needs none: it has
/// exactly one harmonic and cannot alias.
enum {
    SynthAnalogTableTriangle = 0,
    SynthAnalogTableSaw      = 1,
    SynthAnalogTableSquare   = 2
};
#define SYNTH_ANALOG_TABLE_COUNT 3

/// One cycle of a sine, for FM operators and the sine analogue shape.
extern float synth_patch_sine_table[SYNTH_WAVE_TABLE_SIZE];
extern float synth_patch_analog_tables[SYNTH_ANALOG_TABLE_COUNT]
                                      [SYNTH_WAVE_MIPMAP_COUNT]
                                      [SYNTH_WAVE_TABLE_SIZE];
extern float synth_patch_wavetables[SYNTH_WAVETABLE_BANK_COUNT]
                                   [SYNTH_WAVETABLE_FRAME_COUNT]
                                   [SYNTH_WAVE_MIPMAP_COUNT]
                                   [SYNTH_WAVE_TABLE_SIZE];

#pragma mark - Rates and buffer sizes

/*
 Frames between modulation updates.

 Envelopes, LFOs, the matrix and the filter coefficients are evaluated once per
 control block and the resulting amplitude is interpolated across it. At 48 kHz
 that is a 3 kHz control rate, which is far above anything the ear resolves as
 stepping, and it turns the per-sample cost of a voice into three table reads
 and a filter.

 The block boundary is anchored to the voice's own frame counter, not to the
 host buffer, so the output does not depend on how the engine happened to chop
 time at a note boundary. `OfflineRenderTests.testTheRenderIsIndependentOfThe\
 HostBufferSize` is what would catch that going wrong.
 */
#define SYNTH_CONTROL_BLOCK_FRAMES 16

#define SYNTH_DELAY_MAX_SECONDS 1.0
#define SYNTH_DELAY_MAX_FRAMES ((int32_t)(SYNTH_DELAY_MAX_SECONDS * SYNTH_PATCH_MAX_SAMPLE_RATE) + 2)

/// 40 ms of modulated delay at the maximum rate, rounded up to a power of two.
#define SYNTH_CHORUS_MAX_FRAMES 4096
#define SYNTH_CHORUS_MASK (SYNTH_CHORUS_MAX_FRAMES - 1)

/// Freeverb's mono topology: eight damped combs into four allpasses.
#define SYNTH_REVERB_COMB_COUNT 8
#define SYNTH_REVERB_ALLPASS_COUNT 4
/// Longest comb (1617 frames at 44.1 kHz) scaled to the maximum sample rate.
#define SYNTH_REVERB_COMB_MAX_FRAMES 3600
#define SYNTH_REVERB_ALLPASS_MAX_FRAMES 1280
#define SYNTH_REVERB_PREDELAY_MAX_FRAMES ((int32_t)(0.1 * SYNTH_PATCH_MAX_SAMPLE_RATE) + 2)

/// Above this the soft limiter starts bending; below it the voice is exactly
/// linear, so the engine's mixer arithmetic still holds.
#define SYNTH_LIMIT_KNEE 0.8f

/// How the per-sample loop reads one oscillator.
enum {
    /// One band-limited table, or the sine table.
    SynthOscModeTable      = 0,
    /// Two wavetable frames, interpolated by `oscTableBlend`.
    SynthOscModeBlend      = 1,
    /// Two reads of the saw table a pulse width apart.
    SynthOscModePulse      = 2,
    /// Sine carrier phase-modulated by a sine operator.
    SynthOscModeFM         = 3,
    /// Level is zero; skip it entirely.
    SynthOscModeSilent     = 4
};

#pragma mark - Envelope

enum {
    SynthPatchEnvelopeIdle    = 0,
    SynthPatchEnvelopeAttack  = 1,
    SynthPatchEnvelopeDecay   = 2,
    SynthPatchEnvelopeSustain = 3,
    SynthPatchEnvelopeRelease = 4
};

typedef struct {
    int32_t stage;
    /// 0…1 within the current stage.
    float   phase;
    /// Per-control-block phase increments, recomputed when the rate changes.
    float   level;
    /// Level the release started from, so a note released during attack
    /// glides down from where it actually was.
    float   releaseFrom;
} SynthPatchEnvelope;

#pragma mark - Voice slot

typedef struct {
    int32_t inUse;
    int32_t midiNoteNumber;
    int32_t heldByPedal;
    /// Monotonic, so note stealing picks a defined victim.
    int64_t age;

    float   velocity;       /* 0…1 */
    /// `velocity` through the patch's sensitivity curve, resolved at note-on
    /// so the control block does not repeat a `powf` that cannot change.
    float   velocityGain;
    float   keyTrack;       /* -1…1 about middle C */
    float   noteRandom;     /* -1…1, seeded */
    float   baseFrequency;  /* Hz, before pitch modulation */

    uint64_t rng;

    double  oscPhase[SYNTH_PATCH_OSCILLATOR_COUNT];
    double  oscIncrement[SYNTH_PATCH_OSCILLATOR_COUNT];
    double  fmPhase[SYNTH_PATCH_OSCILLATOR_COUNT];
    double  fmIncrement[SYNTH_PATCH_OSCILLATOR_COUNT];
    /// Increment and frequency with no pitch modulation applied, computed once
    /// at note-on. When the matrix routes nothing to this oscillator's pitch —
    /// the common case — the control block reuses these instead of an `exp2f`.
    double  oscBaseIncrement[SYNTH_PATCH_OSCILLATOR_COUNT];
    double  fmBaseIncrement[SYNTH_PATCH_OSCILLATOR_COUNT];
    float   oscBaseFrequency[SYNTH_PATCH_OSCILLATOR_COUNT];
    float   oscFrequency[SYNTH_PATCH_OSCILLATOR_COUNT];
    /// How the per-sample loop should read this oscillator, resolved once per
    /// control block so the inner loop branches on an int rather than
    /// re-deriving the patch's intent every sample.
    int32_t oscMode[SYNTH_PATCH_OSCILLATOR_COUNT];
    /// Chosen once per control block from the oscillator's current frequency.
    const float *oscTableA[SYNTH_PATCH_OSCILLATOR_COUNT];
    const float *oscTableB[SYNTH_PATCH_OSCILLATOR_COUNT];
    float   oscTableBlend[SYNTH_PATCH_OSCILLATOR_COUNT];
    float   oscLevel[SYNTH_PATCH_OSCILLATOR_COUNT];
    float   oscShape[SYNTH_PATCH_OSCILLATOR_COUNT];
    float   fmDepth[SYNTH_PATCH_OSCILLATOR_COUNT];

    double  lfoPhase[SYNTH_PATCH_LFO_COUNT];
    float   lfoHeld[SYNTH_PATCH_LFO_COUNT];
    float   lfoValue[SYNTH_PATCH_LFO_COUNT];

    SynthPatchEnvelope amplitude;
    SynthPatchEnvelope modulation;

    /// Two cascaded state-variable stages; the second is unused at two poles.
    float   filterIC1[2];
    float   filterIC2[2];
    float   filterK;
    float   filterA1, filterA2, filterA3;
    /// The cutoff and damping the current coefficients were derived from, so an
    /// unmodulated filter costs no `tanf` per control block.
    float   filterLastCutoff;
    float   filterLastK;

    float   noiseLevel;
    /// Interpolated across the control block so a moving envelope does not
    /// step the output.
    float   gainCurrent;
    float   gainTarget;
} SynthPatchVoiceSlot;

#pragma mark - Effects

typedef struct {
    float b0, b1, b2, a1, a2;
    float x1, x2, y1, y2;
} SynthBiquad;

typedef struct {
    SynthBiquad low;
    SynthBiquad mid;
    SynthBiquad high;
} SynthEqualizerState;

typedef struct {
    float   buffer[SYNTH_CHORUS_MAX_FRAMES];
    int32_t writeIndex;
    double  lfoPhase;
    double  lfoIncrement;
    float   centreFrames;
    float   depthFrames;
    float   mix;
    float   feedback;
} SynthChorusState;

typedef struct {
    float   buffer[SYNTH_DELAY_MAX_FRAMES];
    int32_t writeIndex;
    int32_t lengthFrames;
    float   feedback;
    float   mix;
    float   dampingCoefficient;
    float   dampingState;
} SynthDelayState;

typedef struct {
    float   comb[SYNTH_REVERB_COMB_COUNT][SYNTH_REVERB_COMB_MAX_FRAMES];
    int32_t combIndex[SYNTH_REVERB_COMB_COUNT];
    int32_t combLength[SYNTH_REVERB_COMB_COUNT];
    float   combStore[SYNTH_REVERB_COMB_COUNT];

    float   allpass[SYNTH_REVERB_ALLPASS_COUNT][SYNTH_REVERB_ALLPASS_MAX_FRAMES];
    int32_t allpassIndex[SYNTH_REVERB_ALLPASS_COUNT];
    int32_t allpassLength[SYNTH_REVERB_ALLPASS_COUNT];

    float   preDelay[SYNTH_REVERB_PREDELAY_MAX_FRAMES];
    int32_t preDelayIndex;
    int32_t preDelayLength;

    float   feedback;
    float   damping;
    float   mix;
} SynthReverbState;

#pragma mark - Voice state

struct SynthPatchVoiceState {
    SynthPatchConfig config;
    double  sampleRate;

    int32_t sustainPedalDown;
    int64_t ageCounter;
    int64_t noteCounter;
    uint64_t rng;

    /// Position inside the current control block, carried across render calls
    /// so buffer chopping cannot change the result.
    int32_t controlPhase;

    /// Free-running LFOs, shared by every voice that does not retrigger.
    double  freeLFOPhase[SYNTH_PATCH_LFO_COUNT];
    float   freeLFOHeld[SYNTH_PATCH_LFO_COUNT];
    float   freeLFOValue[SYNTH_PATCH_LFO_COUNT];
    double  lfoIncrement[SYNTH_PATCH_LFO_COUNT];

    /// Per-control-block phase increments for the two envelopes.
    float   amplitudeRate[3];   /* attack, decay, release */
    float   modulationRate[3];

    float   filterCutoffCeiling;
    float   tableStepPerHertz;

    int32_t activeVoiceLimit;

    SynthPatchVoiceSlot slots[SYNTH_PATCH_MAX_VOICES];

    SynthEqualizerState equalizer;
    SynthChorusState    chorus;
    SynthDelayState     delay;
    SynthReverbState    reverb;
};

/// Recompute every sample-rate-derived constant, including effect buffer
/// lengths and biquad coefficients. Control thread.
void synth_patch_voice_update_rate(SynthPatchVoiceState *state, double sampleRate);

/// Clear every effect buffer and silence every slot. Control thread at init;
/// also the body of the vtable's `reset`.
void synth_patch_voice_clear(SynthPatchVoiceState *state);

#endif /* SYNTH_PATCH_ENGINE_INTERNAL_H */
