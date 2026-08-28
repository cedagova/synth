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

#include <stdatomic.h>

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
 time at a note boundary. The buffer-size-independence tests in
 `OfflineRenderTests` and `SynthEngineIntegrationTests` are what would catch
 that going wrong.
 */
#define SYNTH_CONTROL_BLOCK_FRAMES 16

#define SYNTH_DELAY_MAX_SECONDS 1.0
/// Integer arithmetic rather than a folded double, so this is a constant
/// expression rather than a variable-length array the compiler forgives.
#define SYNTH_DELAY_MAX_FRAMES (96000 + 2)

/// 40 ms of modulated delay at the maximum rate, rounded up to a power of two.
#define SYNTH_CHORUS_MAX_FRAMES 4096
#define SYNTH_CHORUS_MASK (SYNTH_CHORUS_MAX_FRAMES - 1)

/// Freeverb's mono topology: eight damped combs into four allpasses.
#define SYNTH_REVERB_COMB_COUNT 8
#define SYNTH_REVERB_ALLPASS_COUNT 4
/// Longest comb (1617 frames at 44.1 kHz) scaled to the maximum sample rate.
#define SYNTH_REVERB_COMB_MAX_FRAMES 3600
#define SYNTH_REVERB_ALLPASS_MAX_FRAMES 1280
/// 100 ms at the maximum rate the effect buffers are sized for.
#define SYNTH_REVERB_PREDELAY_MAX_FRAMES (9600 + 2)

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

    /*
     What the note-on-time derivations above were derived from.

     SYN003 edits a patch while its notes are still sounding, so a value that
     was resolved once at note-on and never looked at again is a knob that does
     nothing until the next note. These caches make the resolution repeatable
     without making it repeated: the control block compares, and only pays for
     the `pow` or `powf` when the owner has actually moved something. For a
     patch nobody is editing every comparison is equal and the arithmetic is
     byte-for-byte what it was before — which is what keeps the determinism
     tests meaningful.
    */
    /// The note's frequency before this oscillator's detune, so a detune edit
    /// can be re-applied to the note that is already sounding.
    double  noteFrequency;
    /// The three tuning parameters behind the current base increments, kept
    /// exactly as the config states them so the comparison is against what the
    /// owner set rather than against a rounded combination of it.
    float   tuningSemitones[SYNTH_PATCH_OSCILLATOR_COUNT];
    float   tuningCents[SYNTH_PATCH_OSCILLATOR_COUNT];
    float   tuningRatio[SYNTH_PATCH_OSCILLATOR_COUNT];
    /// The exponent `velocityGain` was computed with.
    float   velocitySensitivity;

    /// The voice's gain at the start of the current control block, at its end,
    /// and where it has actually reached.
    ///
    /// Interpolated across the block so a moving envelope does not step the
    /// output, and interpolated from `gainStart` by position rather than by
    /// accumulation so the result cannot depend on where the host split a
    /// buffer.
    float   gainStart;
    float   gainTarget;
    float   gainCurrent;
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

#pragma mark - Live parameter updates

/*
 One patch, with everything expensive already worked out.

 SYN003's editor changes a sound while it is being heard, and the acceptance
 criterion is that playback *continues*. Rebuilding the voice would stop it, so
 a patch has to be able to reach a rendering voice instead. The problem with
 doing that directly is that installing a patch is not a single word: it is a
 whole `SynthPatchConfig` plus three biquads, four effect geometries and a set
 of per-control-block rates. Half of one and half of the other is not a sound.

 So the crossing is split. Everything that costs a `pow`, a `cos` or a divide
 is computed here, on the control thread, into this flat snapshot; the render
 thread's whole job is to copy it into place. That keeps the transcendental
 work off the audio thread — where `SYNTH_PATCH_MAX_SAMPLE_RATE`-sized effect
 geometry and three RBJ biquads would be a real cost during a knob drag — and
 it keeps the render-side operation short enough to be obviously bounded.

 Deliberately *not* in here: anything that is running state rather than
 parameter. No biquad histories, no delay or reverb buffers, no phases, no
 write indices. Installing a snapshot changes what the voice is; it must not
 change where the voice currently is, or every parameter move would click.
*/
typedef struct SynthPatchDerived {
    SynthPatchConfig config;
    /// The rate this snapshot was derived at. A voice refuses a snapshot from
    /// another rate rather than rendering with the wrong geometry.
    double  sampleRate;

    float   amplitudeRate[3];
    float   modulationRate[3];
    double  lfoIncrement[SYNTH_PATCH_LFO_COUNT];
    float   filterCutoffCeiling;
    int32_t activeVoiceLimit;

    /// b0, b1, b2, a1, a2 — coefficients only, never the four history terms.
    float   equalizerLow[5];
    float   equalizerMid[5];
    float   equalizerHigh[5];

    float   chorusCentreFrames;
    float   chorusDepthFrames;
    float   chorusMix;
    float   chorusFeedback;
    double  chorusLFOIncrement;

    int32_t delayLengthFrames;
    float   delayFeedback;
    float   delayMix;
    float   delayDampingCoefficient;

    int32_t reverbCombLength[SYNTH_REVERB_COMB_COUNT];
    int32_t reverbAllpassLength[SYNTH_REVERB_ALLPASS_COUNT];
    int32_t reverbPreDelayLength;
    float   reverbFeedback;
    float   reverbDamping;
    float   reverbMix;
} SynthPatchDerived;

/*
 Three snapshots, because two are not enough.

 This is the standard triple buffer: the producer owns one slot, the consumer
 owns one, and one sits in `liveShared` as the most recent complete value.
 Publishing is one `atomic_exchange`; adopting is one load and one exchange.
 Neither side ever waits, neither side can ever be writing the slot the other
 is reading, and a burst of edits during one long render block costs the
 intermediate values rather than a torn one. A two-slot swap has no such
 guarantee: a second publish landing while the render thread is mid-copy lands
 on the slot being copied.

 The fresh bit rides in the same word as the index so publish and adopt each
 stay a single atomic operation.
*/
#define SYNTH_LIVE_SLOT_COUNT 3
#define SYNTH_LIVE_INDEX_MASK 3
#define SYNTH_LIVE_FRESH 4

/// Live note events, control thread → render thread.
enum {
    SynthLiveEventNoteOn  = 1,
    SynthLiveEventNoteOff = 2,
    SynthLiveEventPedal   = 3,
    /// Everything off at once, for a panic or for closing the editor.
    SynthLiveEventAllOff  = 4
};

typedef struct SynthLiveNoteEvent {
    int32_t kind;
    int32_t note;
    int32_t velocity;
} SynthLiveNoteEvent;

/*
 Room for one test-note queue.

 A power of two so the wrap is a mask. 128 is far more than the handful of
 events a person can produce between two render blocks; the queue exists to
 make the crossing correct rather than to buffer a performance, and a full
 queue is reported to the caller rather than silently dropping a note-off.
*/
#define SYNTH_LIVE_NOTE_CAPACITY 128
#define SYNTH_LIVE_NOTE_MASK (SYNTH_LIVE_NOTE_CAPACITY - 1)

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

    int32_t activeVoiceLimit;

    SynthPatchVoiceSlot slots[SYNTH_PATCH_MAX_VOICES];

    SynthEqualizerState equalizer;
    SynthChorusState    chorus;
    SynthDelayState     delay;
    SynthReverbState    reverb;

    /* Live parameter updates. `liveWriteIndex` is the producer's alone,
       `liveReadIndex` the consumer's alone, and `liveShared` is the only word
       they both touch. */
    SynthPatchDerived liveSlots[SYNTH_LIVE_SLOT_COUNT];
    _Atomic int32_t   liveShared;
    int32_t           liveWriteIndex;
    int32_t           liveReadIndex;
    /// Incremented by the render thread every time it takes a published patch.
    /// Read from the control thread so a caller — or a test — can prove an edit
    /// actually reached the audio rather than assume it.
    _Atomic int64_t   liveAdoptions;

    /* Live notes. Single-producer, single-consumer ring. */
    SynthLiveNoteEvent liveNotes[SYNTH_LIVE_NOTE_CAPACITY];
    _Atomic int64_t    liveNoteWrite;
    _Atomic int64_t    liveNoteRead;
};

/// Copy `derived` into the voice's live parameters, leaving every running
/// value — phases, buffers, biquad histories, indices — where it is.
///
/// Real-time safe: assignments and index wraps, no arithmetic that could be
/// slow. Lives in the render core so the guard that scans that file covers it.
void synth_patch_voice_install(SynthPatchVoiceState *state,
                               const SynthPatchDerived *derived);

/// Work out everything one patch determines at one sample rate. Control thread:
/// this is where the `pow`s and the biquad design live.
void synth_patch_derive(SynthPatchDerived *derived,
                        const SynthPatchConfig *config,
                        double sampleRate);

/// Recompute every sample-rate-derived constant, including effect buffer
/// lengths and biquad coefficients. Control thread.
void synth_patch_voice_update_rate(SynthPatchVoiceState *state, double sampleRate);

/// Clear every effect buffer and silence every slot. Control thread at init;
/// also the body of the vtable's `reset`.
void synth_patch_voice_clear(SynthPatchVoiceState *state);

#endif /* SYNTH_PATCH_ENGINE_INTERNAL_H */
