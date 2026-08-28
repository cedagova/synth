/*
 SynthPatchEngine.c — the synthesizer's render thread, and nothing else.

 THIS FILE MUST NOT ALLOCATE, LOCK, OR CALL INTO THE OBJECTIVE-C RUNTIME.
 `RealtimeSafetyTests.testRenderCoresContainNoRealtimeUnsafeCall` reads it and
 fails the build if a name from its forbidden list appears, exactly as it does
 for `SynthAudioCore.c`. Construction, table generation and parameter clamping
 live in `SynthPatchSetup.c`, which is allowed to be slow because it never runs
 while audio is playing.

 Shape of the work, per voice:

   1. Every `SYNTH_CONTROL_BLOCK_FRAMES` frames, advance the two envelopes and
      the two LFOs, evaluate the modulation matrix, and resolve the result into
      per-oscillator increments, levels and shapes plus one set of filter
      coefficients.
   2. Between those points, run a tight per-sample loop: three table reads, a
      noise sample, a state-variable filter, and one interpolated gain.

 The control block is anchored to the voice's own frame counter rather than to
 the host's buffer, so the output cannot depend on where the engine happened to
 split a buffer at a note boundary.
 */

#include "SynthPatchEngineInternal.h"

#include <math.h>

#pragma mark - Small helpers

static inline float synth_patch_clamp(float value, float low, float high) {
    return value < low ? low : (value > high ? high : value);
}

/*
 Denormals cost hundreds of cycles and are how a long reverb tail quietly turns
 into missed deadlines. Flushing them keeps the cost of a decaying tail
 constant and makes two runs of the same tail identical.
 */
static inline float synth_patch_flush(float value) {
    return (value > -1.0e-25f && value < 1.0e-25f) ? 0.0f : value;
}

/*
 Anything that is not a finite number is a bug that has already happened; the
 job here is to make sure it does not leave the voice as a burst of noise at
 full scale.

 Applied to every recursive store in the file — the two filter integrators, the
 three equaliser biquads, and the delay, chorus and reverb feedback paths —
 because those are the only places a value can feed back into itself. All of
 them are damped and clamped below unity, so this should never fire; a guard
 that covered most of them would be worth much less than one that covers all.
 */
static inline float synth_patch_finite(float value) {
    if (!(value == value)) { return 0.0f; }
    if (value > 1.0e6f || value < -1.0e6f) { return 0.0f; }
    return value;
}

/// Table read with linear interpolation. `phase` is 0…1.
static inline float synth_patch_read(const float *table, double phase) {
    const double scaled = phase * (double)SYNTH_WAVE_TABLE_SIZE;
    const int32_t index = (int32_t)scaled;
    const float fraction = (float)(scaled - (double)index);
    const float a = table[index & SYNTH_WAVE_TABLE_MASK];
    const float b = table[(index + 1) & SYNTH_WAVE_TABLE_MASK];
    return a + (b - a) * fraction;
}

static inline float synth_patch_sine(double phase) {
    return synth_patch_read(synth_patch_sine_table, phase - floor(phase));
}

static inline double synth_patch_wrap(double phase) {
    return phase - floor(phase);
}

/*
 Phase advance in the oscillator inner loop.

 A conditional subtraction rather than `synth_patch_wrap`, because the
 increment is always below one: it is frequency over sample rate, and no note
 — even two octaves up through the modulation matrix — reaches the sample
 rate. Worth the special case, because this runs three times per sample per
 sounding note and is the hottest line in the file.
 */
static inline double synth_patch_advance(double phase, double increment) {
    const double next = phase + increment;
    return next >= 1.0 ? next - 1.0 : next;
}

/// xorshift64*. Small, fast, and — the point here — exactly repeatable.
static inline float synth_patch_random(uint64_t *rng) {
    uint64_t x = *rng;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *rng = x;
    const uint64_t scrambled = x * 0x2545F4914F6CDD1DULL;
    /* Top 24 bits into -1…1. */
    return (float)((int32_t)(scrambled >> 40) - 8388608) * (1.0f / 8388608.0f);
}

/*
 Output protection.

 Below the knee this is the identity, so the engine's per-line gain and pan
 arithmetic still describes the mix exactly. Above it the curve bends towards
 an asymptote of 1, so no patch — however much delay feedback or reverb it
 asks for — can hand the engine a sample outside ±1.
 */
static inline float synth_patch_limit(float value) {
    const float magnitude = value < 0.0f ? -value : value;
    if (magnitude <= SYNTH_LIMIT_KNEE) { return value; }
    const float headroom = 1.0f - SYNTH_LIMIT_KNEE;
    const float over = (magnitude - SYNTH_LIMIT_KNEE) / headroom;
    /* tanh, near enough, without the call. */
    const float bent = over * (27.0f + over * over) / (27.0f + 9.0f * over * over);
    const float shaped = SYNTH_LIMIT_KNEE + headroom * synth_patch_clamp(bent, 0.0f, 1.0f);
    return value < 0.0f ? -shaped : shaped;
}

/// Mipmap covering this fundamental. Below 20 Hz uses the fullest table.
static inline int32_t synth_patch_mipmap(float frequency) {
    if (frequency <= (float)SYNTH_WAVE_MIPMAP_BASE_HERTZ) { return 0; }
    int32_t index = (int32_t)(log2f(frequency / (float)SYNTH_WAVE_MIPMAP_BASE_HERTZ));
    if (index < 0) { index = 0; }
    if (index > SYNTH_WAVE_MIPMAP_COUNT - 1) { index = SYNTH_WAVE_MIPMAP_COUNT - 1; }
    return index;
}

#pragma mark - Clearing

void synth_patch_voice_clear(SynthPatchVoiceState *state) {
    state->sustainPedalDown = 0;
    state->controlPhase = 0;
    state->rng = state->config.seed ? state->config.seed : 0x9E3779B97F4A7C15ULL;
    state->noteCounter = 0;

    for (int32_t index = 0; index < SYNTH_PATCH_LFO_COUNT; index++) {
        state->freeLFOPhase[index] = (double)state->config.lfos[index].startPhase;
        state->freeLFOHeld[index] = 0.0f;
        state->freeLFOValue[index] = 0.0f;
    }

    for (int32_t index = 0; index < SYNTH_PATCH_MAX_VOICES; index++) {
        SynthPatchVoiceSlot *slot = &state->slots[index];
        slot->inUse = 0;
        slot->midiNoteNumber = -1;
        slot->heldByPedal = 0;
        slot->amplitude.stage = SynthPatchEnvelopeIdle;
        slot->amplitude.level = 0.0f;
        slot->modulation.stage = SynthPatchEnvelopeIdle;
        slot->modulation.level = 0.0f;
        slot->gainStart = 0.0f;
        slot->gainCurrent = 0.0f;
        slot->gainTarget = 0.0f;
        slot->filterLastCutoff = -1.0f;
        slot->filterLastK = -1.0f;
        for (int32_t stage = 0; stage < 2; stage++) {
            slot->filterIC1[stage] = 0.0f;
            slot->filterIC2[stage] = 0.0f;
        }
    }

    /* Only the frames each effect can actually reach are cleared. Reads are
       wrapped inside those lengths, so anything beyond them is unreachable and
       clearing it would only make a seek more expensive. */
    for (int32_t index = 0; index < SYNTH_CHORUS_MAX_FRAMES; index++) {
        state->chorus.buffer[index] = 0.0f;
    }
    state->chorus.writeIndex = 0;
    state->chorus.lfoPhase = 0.0;

    for (int32_t index = 0; index < state->delay.lengthFrames; index++) {
        state->delay.buffer[index] = 0.0f;
    }
    state->delay.writeIndex = 0;
    state->delay.dampingState = 0.0f;

    for (int32_t comb = 0; comb < SYNTH_REVERB_COMB_COUNT; comb++) {
        for (int32_t index = 0; index < state->reverb.combLength[comb]; index++) {
            state->reverb.comb[comb][index] = 0.0f;
        }
        state->reverb.combIndex[comb] = 0;
        state->reverb.combStore[comb] = 0.0f;
    }
    for (int32_t allpass = 0; allpass < SYNTH_REVERB_ALLPASS_COUNT; allpass++) {
        for (int32_t index = 0; index < state->reverb.allpassLength[allpass]; index++) {
            state->reverb.allpass[allpass][index] = 0.0f;
        }
        state->reverb.allpassIndex[allpass] = 0;
    }
    for (int32_t index = 0; index < state->reverb.preDelayLength; index++) {
        state->reverb.preDelay[index] = 0.0f;
    }
    state->reverb.preDelayIndex = 0;

    state->equalizer.low.x1 = 0.0f;  state->equalizer.low.x2 = 0.0f;
    state->equalizer.low.y1 = 0.0f;  state->equalizer.low.y2 = 0.0f;
    state->equalizer.mid.x1 = 0.0f;  state->equalizer.mid.x2 = 0.0f;
    state->equalizer.mid.y1 = 0.0f;  state->equalizer.mid.y2 = 0.0f;
    state->equalizer.high.x1 = 0.0f; state->equalizer.high.x2 = 0.0f;
    state->equalizer.high.y1 = 0.0f; state->equalizer.high.y2 = 0.0f;
}

void synth_patch_voice_reset(void *opaque) {
    synth_patch_voice_clear((SynthPatchVoiceState *)opaque);
}

#pragma mark - Installing a published patch

static inline void synth_patch_load_biquad(SynthBiquad *biquad, const float coefficients[5]) {
    /* Coefficients only. `x1`, `x2`, `y1` and `y2` are the filter's memory of
       the audio that has already gone through it; replacing them mid-signal is
       a click, and a filter whose shape changed still has the same past. */
    biquad->b0 = coefficients[0];
    biquad->b1 = coefficients[1];
    biquad->b2 = coefficients[2];
    biquad->a1 = coefficients[3];
    biquad->a2 = coefficients[4];
}

void synth_patch_voice_install(SynthPatchVoiceState *state,
                               const SynthPatchDerived *derived) {
    state->config = derived->config;
    state->sampleRate = derived->sampleRate;
    state->filterCutoffCeiling = derived->filterCutoffCeiling;
    state->activeVoiceLimit = derived->activeVoiceLimit;

    for (int32_t index = 0; index < 3; index++) {
        state->amplitudeRate[index] = derived->amplitudeRate[index];
        state->modulationRate[index] = derived->modulationRate[index];
    }
    for (int32_t index = 0; index < SYNTH_PATCH_LFO_COUNT; index++) {
        state->lfoIncrement[index] = derived->lfoIncrement[index];
    }

    synth_patch_load_biquad(&state->equalizer.low, derived->equalizerLow);
    synth_patch_load_biquad(&state->equalizer.mid, derived->equalizerMid);
    synth_patch_load_biquad(&state->equalizer.high, derived->equalizerHigh);

    state->chorus.centreFrames = derived->chorusCentreFrames;
    state->chorus.depthFrames  = derived->chorusDepthFrames;
    state->chorus.mix          = derived->chorusMix;
    state->chorus.feedback     = derived->chorusFeedback;
    state->chorus.lfoIncrement = derived->chorusLFOIncrement;

    state->delay.lengthFrames = derived->delayLengthFrames;
    state->delay.feedback     = derived->delayFeedback;
    state->delay.mix          = derived->delayMix;
    state->delay.dampingCoefficient = derived->delayDampingCoefficient;
    /* A shorter delay leaves the write head past its own end. Wrapping keeps
       every subsequent read in bounds; the audio already in the line is heard
       out at the new length, which is what a delay time knob does. */
    if (state->delay.writeIndex >= state->delay.lengthFrames) {
        state->delay.writeIndex = 0;
    }

    for (int32_t index = 0; index < SYNTH_REVERB_COMB_COUNT; index++) {
        state->reverb.combLength[index] = derived->reverbCombLength[index];
        if (state->reverb.combIndex[index] >= state->reverb.combLength[index]) {
            state->reverb.combIndex[index] = 0;
        }
    }
    for (int32_t index = 0; index < SYNTH_REVERB_ALLPASS_COUNT; index++) {
        state->reverb.allpassLength[index] = derived->reverbAllpassLength[index];
        if (state->reverb.allpassIndex[index] >= state->reverb.allpassLength[index]) {
            state->reverb.allpassIndex[index] = 0;
        }
    }
    state->reverb.preDelayLength = derived->reverbPreDelayLength;
    if (state->reverb.preDelayIndex >= state->reverb.preDelayLength) {
        state->reverb.preDelayIndex = 0;
    }
    state->reverb.feedback = derived->reverbFeedback;
    state->reverb.damping  = derived->reverbDamping;
    state->reverb.mix      = derived->reverbMix;
}

/// Take the most recently published patch, if there is one. Render thread.
static inline void synth_patch_voice_adopt(SynthPatchVoiceState *state) {
    const int32_t shared = atomic_load_explicit(&state->liveShared, memory_order_relaxed);
    if (!(shared & SYNTH_LIVE_FRESH)) { return; }

    /* Hand back the slot this thread owned and take the published one. After
       the exchange the three indices are still distinct, so the publisher's
       next write cannot land on what is about to be read. */
    const int32_t exchanged = atomic_exchange_explicit(
        &state->liveShared, state->liveReadIndex, memory_order_acq_rel);
    state->liveReadIndex = exchanged & SYNTH_LIVE_INDEX_MASK;

    synth_patch_voice_install(state, &state->liveSlots[state->liveReadIndex]);
    atomic_fetch_add_explicit(&state->liveAdoptions, 1, memory_order_relaxed);
}

#pragma mark - Note lifecycle

static void synth_patch_resolve_slot(SynthPatchVoiceState *state, SynthPatchVoiceSlot *slot);
static inline float synth_patch_lfo_value(int32_t shape, double phase, float held);

/*
 Resolve one oscillator's tuning from the note and the patch.

 Called at note-on, and again from the control block whenever the owner has
 moved a detune or an FM ratio — which is what makes those knobs audible on a
 note that is already sounding rather than only on the next one. The cached
 values are what makes the second case free when nobody is editing: an
 unchanged patch compares equal and no `pow` is paid for.
*/
static void synth_patch_retune_oscillator(SynthPatchVoiceState *state,
                                          SynthPatchVoiceSlot *slot,
                                          int32_t index) {
    const SynthOscillatorConfig *oscillator = &state->config.oscillators[index];
    const double semitones = (double)oscillator->detuneSemitones
                           + (double)oscillator->detuneCents / 100.0;
    const double tuned = slot->noteFrequency * pow(2.0, semitones / 12.0);

    slot->tuningSemitones[index] = oscillator->detuneSemitones;
    slot->tuningCents[index] = oscillator->detuneCents;
    slot->tuningRatio[index] = oscillator->fmRatio;
    slot->oscBaseFrequency[index] = (float)tuned;
    slot->oscFrequency[index] = (float)tuned;
    slot->oscBaseIncrement[index] = tuned / state->sampleRate;
    slot->oscIncrement[index] = slot->oscBaseIncrement[index];
    slot->fmBaseIncrement[index] = tuned * (double)oscillator->fmRatio / state->sampleRate;
    slot->fmIncrement[index] = slot->fmBaseIncrement[index];
}

void synth_patch_voice_note_on(void *opaque, int32_t midiNoteNumber, int32_t velocity) {
    SynthPatchVoiceState *state = (SynthPatchVoiceState *)opaque;

    /* Pick a slot: a free one, else the quietest, else the oldest. Choosing by
       envelope level rather than by age means the note that gets cut is the one
       the listener is least likely to notice; the tie-break on age keeps the
       choice deterministic, which the determinism test depends on. */
    int32_t chosen = -1;
    float quietest = 2.0f;
    int64_t oldest = INT64_MAX;
    for (int32_t index = 0; index < state->activeVoiceLimit; index++) {
        SynthPatchVoiceSlot *candidate = &state->slots[index];
        if (!candidate->inUse) { chosen = index; break; }
        const float level = candidate->amplitude.level;
        if (level < quietest || (level == quietest && candidate->age < oldest)) {
            quietest = level;
            oldest = candidate->age;
            chosen = index;
        }
    }
    if (chosen < 0) { return; }

    SynthPatchVoiceSlot *slot = &state->slots[chosen];
    const int32_t reusing = slot->inUse;

    slot->inUse = 1;
    slot->midiNoteNumber = midiNoteNumber;
    slot->heldByPedal = 0;
    slot->age = state->ageCounter++;
    slot->velocity = synth_patch_clamp((float)velocity / 127.0f, 0.0f, 1.0f);
    slot->keyTrack = synth_patch_clamp(((float)midiNoteNumber - 60.0f) / 36.0f, -1.0f, 1.0f);

    /* Seeded from the patch seed and the note's ordinal, never from a clock,
       so a second render of the same events produces the same randomness. */
    const uint64_t noteIndex = (uint64_t)(state->noteCounter++);
    slot->rng = state->config.seed
        ^ (noteIndex * 0x9E3779B97F4A7C15ULL)
        ^ ((uint64_t)midiNoteNumber << 32);
    if (slot->rng == 0) { slot->rng = 0x2545F4914F6CDD1DULL; }
    slot->noteRandom = synth_patch_random(&slot->rng);

    /* Equal temperament, A4 = 440 Hz. */
    const double frequency = 440.0 * pow(2.0, ((double)midiNoteNumber - 69.0) / 12.0);
    slot->noteFrequency = frequency;

    for (int32_t index = 0; index < SYNTH_PATCH_OSCILLATOR_COUNT; index++) {
        const SynthOscillatorConfig *oscillator = &state->config.oscillators[index];
        synth_patch_retune_oscillator(state, slot, index);
        if (oscillator->retriggersPhase || !reusing) {
            slot->oscPhase[index] = (double)oscillator->startPhase;
            slot->fmPhase[index] = 0.0;
        }
    }

    for (int32_t index = 0; index < SYNTH_PATCH_LFO_COUNT; index++) {
        if (state->config.lfos[index].retriggersPerNote) {
            slot->lfoPhase[index] = (double)state->config.lfos[index].startPhase;
            slot->lfoHeld[index] = synth_patch_random(&slot->rng);
            slot->lfoValue[index] = synth_patch_lfo_value(
                state->config.lfos[index].shape, slot->lfoPhase[index], slot->lfoHeld[index]);
        } else {
            slot->lfoPhase[index] = state->freeLFOPhase[index];
            slot->lfoHeld[index] = state->freeLFOHeld[index];
            slot->lfoValue[index] = state->freeLFOValue[index];
        }
    }

    /* Both envelopes restart from zero. The per-sample gain still glides from
       whatever the slot was last at, so stealing a sounding note does not
       click. */
    slot->amplitude.stage = SynthPatchEnvelopeAttack;
    slot->amplitude.phase = 0.0f;
    slot->amplitude.level = 0.0f;
    slot->modulation.stage = SynthPatchEnvelopeAttack;
    slot->modulation.phase = 0.0f;
    slot->modulation.level = 0.0f;

    slot->velocitySensitivity = state->config.velocitySensitivity;
    slot->velocityGain = powf(slot->velocity, slot->velocitySensitivity);
    slot->noiseLevel = state->config.noiseLevel;
    slot->filterLastCutoff = -1.0f;
    slot->filterLastK = -1.0f;

    /* Resolve the derived values now rather than waiting for the next
       control-block boundary, so the oscillators, filter and levels are already
       correct for this note on its very first frame.

       The amplitude envelope is the one thing this cannot make exact: it is
       being started here, so its level is zero, and the note's attack begins at
       the next control-block boundary — at most fifteen frames, or 0.31 ms at
       48 kHz, later. Deterministic and independent of the buffer size, and far
       below the ear's resolution for an onset, but it is a quantisation and
       worth saying so rather than claiming sample accuracy. */
    synth_patch_resolve_slot(state, slot);
}

void synth_patch_voice_note_off(void *opaque, int32_t midiNoteNumber) {
    SynthPatchVoiceState *state = (SynthPatchVoiceState *)opaque;
    for (int32_t index = 0; index < SYNTH_PATCH_MAX_VOICES; index++) {
        SynthPatchVoiceSlot *slot = &state->slots[index];
        if (!slot->inUse || slot->midiNoteNumber != midiNoteNumber) { continue; }
        if (slot->amplitude.stage == SynthPatchEnvelopeRelease) { continue; }
        if (state->sustainPedalDown) {
            slot->heldByPedal = 1;
        } else {
            slot->amplitude.stage = SynthPatchEnvelopeRelease;
            slot->amplitude.phase = 0.0f;
            slot->amplitude.releaseFrom = slot->amplitude.level;
            slot->modulation.stage = SynthPatchEnvelopeRelease;
            slot->modulation.phase = 0.0f;
            slot->modulation.releaseFrom = slot->modulation.level;
        }
    }
}

void synth_patch_voice_set_pedal(void *opaque, int32_t isDown) {
    SynthPatchVoiceState *state = (SynthPatchVoiceState *)opaque;
    const int32_t wasDown = state->sustainPedalDown;
    state->sustainPedalDown = isDown ? 1 : 0;
    if (!wasDown || state->sustainPedalDown) { return; }

    for (int32_t index = 0; index < SYNTH_PATCH_MAX_VOICES; index++) {
        SynthPatchVoiceSlot *slot = &state->slots[index];
        if (!slot->heldByPedal) { continue; }
        slot->heldByPedal = 0;
        slot->amplitude.stage = SynthPatchEnvelopeRelease;
        slot->amplitude.phase = 0.0f;
        slot->amplitude.releaseFrom = slot->amplitude.level;
        slot->modulation.stage = SynthPatchEnvelopeRelease;
        slot->modulation.phase = 0.0f;
        slot->modulation.releaseFrom = slot->modulation.level;
    }
}

#pragma mark - Envelopes

/*
 Stage shaping.

 `curve` blends between a straight line and a cubic. Two multiplies instead of
 a `powf`, monotonic in both directions, and at `curve == 0` exactly the linear
 ADSR increment 002's built-in voice used — which is what lets the shipped
 default patch be a continuation of that sound rather than a replacement for it.
 */
static inline float synth_patch_shape_down(float phase, float curve) {
    const float linear = 1.0f - phase;
    const float cubic = linear * linear * linear;
    return linear + curve * (cubic - linear);
}

static inline float synth_patch_shape_up(float phase, float curve) {
    const float linear = phase;
    const float inverse = 1.0f - phase;
    const float fast = 1.0f - inverse * inverse * inverse;
    return linear + curve * (fast - linear);
}

/// Advance one envelope by one control block. Returns its level, 0…1.
static inline float synth_patch_envelope_step(SynthPatchEnvelope *envelope,
                                              const SynthEnvelopeConfig *config,
                                              const float *rates) {
    switch (envelope->stage) {
        case SynthPatchEnvelopeAttack:
            envelope->phase += rates[0];
            if (envelope->phase >= 1.0f) {
                envelope->phase = 0.0f;
                envelope->stage = SynthPatchEnvelopeDecay;
                envelope->level = 1.0f;
            } else {
                envelope->level = synth_patch_shape_up(envelope->phase, config->curve);
            }
            break;

        case SynthPatchEnvelopeDecay:
            envelope->phase += rates[1];
            if (envelope->phase >= 1.0f) {
                envelope->phase = 1.0f;
                envelope->stage = SynthPatchEnvelopeSustain;
                envelope->level = config->sustainLevel;
            } else {
                const float fall = synth_patch_shape_down(envelope->phase, config->curve);
                envelope->level = config->sustainLevel + (1.0f - config->sustainLevel) * fall;
            }
            break;

        case SynthPatchEnvelopeSustain:
            envelope->level = config->sustainLevel;
            break;

        case SynthPatchEnvelopeRelease:
            envelope->phase += rates[2];
            if (envelope->phase >= 1.0f) {
                envelope->phase = 1.0f;
                envelope->stage = SynthPatchEnvelopeIdle;
                envelope->level = 0.0f;
            } else {
                envelope->level = envelope->releaseFrom
                                * synth_patch_shape_down(envelope->phase, config->curve);
            }
            break;

        default:
            envelope->level = 0.0f;
            break;
    }
    envelope->level = synth_patch_flush(envelope->level);
    return envelope->level;
}

#pragma mark - LFOs

/// Evaluate one LFO shape at `phase`, 0…1. Returns -1…1.
static inline float synth_patch_lfo_value(int32_t shape, double phase, float held) {
    switch (shape) {
        case SynthLFOShapeSine:     return synth_patch_sine(phase);
        case SynthLFOShapeTriangle: {
            const float ramp = (float)(phase * 4.0);
            if (phase < 0.25) { return ramp; }
            if (phase < 0.75) { return 2.0f - ramp; }
            return ramp - 4.0f;
        }
        case SynthLFOShapeSaw:    return (float)(phase * 2.0 - 1.0);
        case SynthLFOShapeSquare: return phase < 0.5 ? 1.0f : -1.0f;
        default:                  return held;
    }
}

/// Advance one LFO by a control block, resampling sample-and-hold on wrap.
static inline float synth_patch_lfo_step(double *phase, float *held, uint64_t *rng,
                                         const SynthLFOConfig *config, double increment) {
    const double previous = *phase;
    double next = previous + increment;
    if (next >= 1.0) {
        next -= floor(next);
        if (config->shape == SynthLFOShapeSampleAndHold) {
            *held = synth_patch_random(rng);
        }
    }
    *phase = next;
    return synth_patch_lfo_value(config->shape, next, *held);
}

#pragma mark - State-variable filter

/*
 Topology-preserving-transform SVF (Zavalishin). One structure gives lowpass,
 highpass, bandpass and notch from the same two integrator states, it is stable
 up to the coefficient limits enforced here, and its cutoff is accurate right
 up to Nyquist — which a naive digital ladder is not.
 */
static inline void synth_patch_filter_coefficients(SynthPatchVoiceSlot *slot,
                                                   float cutoff, float damping,
                                                   double sampleRate) {
    if (cutoff == slot->filterLastCutoff && damping == slot->filterLastK) { return; }
    slot->filterLastCutoff = cutoff;
    slot->filterLastK = damping;

    const float g = tanf((float)(M_PI * (double)cutoff / sampleRate));
    slot->filterK = damping;
    slot->filterA1 = 1.0f / (1.0f + g * (g + damping));
    slot->filterA2 = g * slot->filterA1;
    slot->filterA3 = g * slot->filterA2;
}

static inline float synth_patch_filter_stage(SynthPatchVoiceSlot *slot, int32_t stage,
                                             float input, int32_t type) {
    const float v3 = input - slot->filterIC2[stage];
    const float v1 = slot->filterA1 * slot->filterIC1[stage] + slot->filterA2 * v3;
    const float v2 = slot->filterIC2[stage] + slot->filterA2 * slot->filterIC1[stage]
                   + slot->filterA3 * v3;
    slot->filterIC1[stage] = synth_patch_finite(
        synth_patch_flush(2.0f * v1 - slot->filterIC1[stage]));
    slot->filterIC2[stage] = synth_patch_finite(
        synth_patch_flush(2.0f * v2 - slot->filterIC2[stage]));

    switch (type) {
        case SynthFilterTypeHighpass: return input - slot->filterK * v1 - v2;
        case SynthFilterTypeBandpass: return v1;
        case SynthFilterTypeNotch:    return input - slot->filterK * v1;
        default:                      return v2;   /* lowpass */
    }
}

#pragma mark - Control-block update

/*
 Resolve the modulation matrix into the numbers the per-sample loop reads:
 per-oscillator increments, levels, table pointers and shapes, one set of
 filter coefficients, and the target gain.

 Split from the envelope/LFO advance below because a note that starts partway
 through a control block still needs its derived values before the first sample
 is written. Resolving without advancing gives that note the right oscillators,
 filter and levels immediately; its amplitude envelope still starts at the next
 control-block boundary, which is where the 0.31 ms onset quantisation noted in
 `synth_patch_voice_note_on` comes from.
 */
static void synth_patch_resolve_slot(SynthPatchVoiceState *state, SynthPatchVoiceSlot *slot) {
    const SynthPatchConfig *config = &state->config;

    /*
     Anything the owner may have moved since this note started.

     These four were resolved once at note-on because nothing could change them
     mid-note. SYN003's editor can, so they are re-resolved here — but only
     when they actually differ, so a patch nobody is editing pays three float
     comparisons per oscillator per control block and no arithmetic at all.
    */
    for (int32_t index = 0; index < SYNTH_PATCH_OSCILLATOR_COUNT; index++) {
        const SynthOscillatorConfig *oscillator = &config->oscillators[index];
        if (slot->tuningSemitones[index] != oscillator->detuneSemitones
            || slot->tuningCents[index] != oscillator->detuneCents
            || slot->tuningRatio[index] != oscillator->fmRatio) {
            synth_patch_retune_oscillator(state, slot, index);
        }
    }
    if (slot->velocitySensitivity != config->velocitySensitivity) {
        slot->velocitySensitivity = config->velocitySensitivity;
        slot->velocityGain = powf(slot->velocity, slot->velocitySensitivity);
    }
    slot->noiseLevel = config->noiseLevel;

    const float amplitudeEnvelope = slot->amplitude.level;
    const float modulationEnvelope = slot->modulation.level;

    float source[SYNTH_MOD_SOURCE_COUNT];
    source[SynthModSourceNone]               = 0.0f;
    source[SynthModSourceAmplitudeEnvelope]  = amplitudeEnvelope;
    source[SynthModSourceModulationEnvelope] = modulationEnvelope;
    source[SynthModSourceLFO1]               = slot->lfoValue[0];
    source[SynthModSourceLFO2]               = slot->lfoValue[1];
    source[SynthModSourceVelocity]           = slot->velocity;
    source[SynthModSourceKeyTrack]           = slot->keyTrack;
    source[SynthModSourceNoteRandom]         = slot->noteRandom;

    float modulation[SYNTH_MOD_DESTINATION_COUNT];
    for (int32_t index = 0; index < SYNTH_MOD_DESTINATION_COUNT; index++) {
        modulation[index] = 0.0f;
    }
    for (int32_t index = 0; index < SYNTH_PATCH_MOD_SLOT_COUNT; index++) {
        const SynthModulationSlotConfig *route = &config->modulation[index];
        if (route->source == SynthModSourceNone) { continue; }
        if (route->destination == SynthModDestinationNone) { continue; }
        modulation[route->destination] += route->amount * source[route->source];
    }

    for (int32_t index = 0; index < SYNTH_PATCH_OSCILLATOR_COUNT; index++) {
        const SynthOscillatorConfig *oscillator = &config->oscillators[index];

        /* Pitch: ±24 semitones at full amount. Unmodulated oscillators reuse
           the increment computed at note-on rather than paying for an exp2. */
        const float pitch = modulation[SynthModDestinationOscillator1Pitch + index];
        if (pitch == 0.0f) {
            slot->oscIncrement[index] = slot->oscBaseIncrement[index];
            slot->fmIncrement[index] = slot->fmBaseIncrement[index];
            slot->oscFrequency[index] = slot->oscBaseFrequency[index];
        } else {
            const float factor = exp2f(synth_patch_clamp(pitch, -1.0f, 1.0f) * 2.0f);
            slot->oscIncrement[index] = slot->oscBaseIncrement[index] * (double)factor;
            slot->fmIncrement[index] = slot->fmBaseIncrement[index] * (double)factor;
            slot->oscFrequency[index] = slot->oscBaseFrequency[index] * factor;
        }

        const float levelModulation = modulation[SynthModDestinationOscillator1Level + index];
        slot->oscLevel[index] = oscillator->level
            * synth_patch_clamp(1.0f + levelModulation, 0.0f, 2.0f);

        const float shape = synth_patch_clamp(
            oscillator->shapeAmount + modulation[SynthModDestinationOscillator1Shape + index],
            0.0f, 1.0f);

        if (slot->oscLevel[index] <= 0.0f) {
            slot->oscMode[index] = SynthOscModeSilent;
            continue;
        }

        const int32_t mipmap = synth_patch_mipmap(slot->oscFrequency[index]);

        switch (oscillator->type) {
            case SynthOscillatorTypeFM:
                slot->oscMode[index] = SynthOscModeFM;
                slot->fmDepth[index] = shape * SYNTH_FM_MAX_INDEX;
                break;

            case SynthOscillatorTypeWavetable: {
                const int32_t bank = oscillator->shape;
                const float position = shape * (float)(SYNTH_WAVETABLE_FRAME_COUNT - 1);
                int32_t frame = (int32_t)position;
                if (frame > SYNTH_WAVETABLE_FRAME_COUNT - 2) {
                    frame = SYNTH_WAVETABLE_FRAME_COUNT - 2;
                }
                if (frame < 0) { frame = 0; }
                slot->oscMode[index] = SynthOscModeBlend;
                slot->oscTableA[index] = synth_patch_wavetables[bank][frame][mipmap];
                slot->oscTableB[index] = synth_patch_wavetables[bank][frame + 1][mipmap];
                slot->oscTableBlend[index] = position - (float)frame;
                break;
            }

            default:
                switch (oscillator->shape) {
                    case SynthAnalogShapeSine:
                        slot->oscMode[index] = SynthOscModeTable;
                        slot->oscTableA[index] = synth_patch_sine_table;
                        break;
                    case SynthAnalogShapeTriangle:
                        slot->oscMode[index] = SynthOscModeTable;
                        slot->oscTableA[index] = synth_patch_analog_tables[SynthAnalogTableTriangle][mipmap];
                        break;
                    case SynthAnalogShapeSquare:
                        slot->oscMode[index] = SynthOscModeTable;
                        slot->oscTableA[index] = synth_patch_analog_tables[SynthAnalogTableSquare][mipmap];
                        break;
                    case SynthAnalogShapePulse:
                        /* Two saws a width apart. Subtracting one band-limited
                           saw from another gives a pulse that is band-limited
                           too, at any width, for the price of one extra read. */
                        slot->oscMode[index] = SynthOscModePulse;
                        slot->oscTableA[index] = synth_patch_analog_tables[SynthAnalogTableSaw][mipmap];
                        slot->oscTableBlend[index] = 0.05f + 0.90f * shape;
                        break;
                    default:
                        slot->oscMode[index] = SynthOscModeTable;
                        slot->oscTableA[index] = synth_patch_analog_tables[SynthAnalogTableSaw][mipmap];
                        break;
                }
                break;
        }
    }

    if (config->filter.isEnabled) {
        float cutoff = config->filter.cutoffHertz;
        if (config->filter.keyTracking > 0.0f) {
            cutoff *= exp2f(config->filter.keyTracking * slot->keyTrack * 3.0f);
        }
        const float cutoffModulation = modulation[SynthModDestinationFilterCutoff];
        if (cutoffModulation != 0.0f) {
            cutoff *= exp2f(synth_patch_clamp(cutoffModulation, -1.0f, 1.0f) * 6.0f);
        }
        cutoff = synth_patch_clamp(cutoff, 20.0f, state->filterCutoffCeiling);

        const float resonance = synth_patch_clamp(
            config->filter.resonance + modulation[SynthModDestinationFilterResonance], 0.0f, 1.0f);
        /* Damping 2 → 0.1. Never zero, so the filter cannot self-oscillate. */
        const float damping = 2.0f - 1.9f * resonance;
        synth_patch_filter_coefficients(slot, cutoff, damping, state->sampleRate);
    }

    const float amplitudeModulation = synth_patch_clamp(
        1.0f + modulation[SynthModDestinationAmplitude], 0.0f, 2.0f);

    slot->gainTarget = amplitudeEnvelope
        * amplitudeModulation
        * slot->velocityGain
        * config->outputLevel;
}

/// One control block for one sounding note: advance both envelopes and both
/// LFOs, then resolve everything downstream of them.
static void synth_patch_update_slot(SynthPatchVoiceState *state, SynthPatchVoiceSlot *slot) {
    const SynthPatchConfig *config = &state->config;

    synth_patch_envelope_step(&slot->amplitude, &config->amplitudeEnvelope, state->amplitudeRate);
    synth_patch_envelope_step(&slot->modulation, &config->modulationEnvelope, state->modulationRate);

    for (int32_t index = 0; index < SYNTH_PATCH_LFO_COUNT; index++) {
        if (config->lfos[index].retriggersPerNote) {
            slot->lfoValue[index] = synth_patch_lfo_step(
                &slot->lfoPhase[index], &slot->lfoHeld[index], &slot->rng,
                &config->lfos[index], state->lfoIncrement[index]);
        } else {
            slot->lfoValue[index] = state->freeLFOValue[index];
        }
    }

    synth_patch_resolve_slot(state, slot);
}

#pragma mark - Effects

static inline float synth_patch_biquad_step(SynthBiquad *biquad, float input) {
    const float output = biquad->b0 * input + biquad->b1 * biquad->x1 + biquad->b2 * biquad->x2
                       - biquad->a1 * biquad->y1 - biquad->a2 * biquad->y2;
    biquad->x2 = biquad->x1;
    biquad->x1 = input;
    biquad->y2 = biquad->y1;
    biquad->y1 = synth_patch_finite(synth_patch_flush(output));
    return biquad->y1;
}

static inline float synth_patch_chorus_tap(SynthChorusState *chorus, float delayFrames) {
    float position = (float)chorus->writeIndex - delayFrames;
    while (position < 0.0f) { position += (float)SYNTH_CHORUS_MAX_FRAMES; }
    const int32_t index = (int32_t)position;
    const float fraction = position - (float)index;
    const float a = chorus->buffer[index & SYNTH_CHORUS_MASK];
    const float b = chorus->buffer[(index + 1) & SYNTH_CHORUS_MASK];
    return a + (b - a) * fraction;
}

static inline float synth_patch_chorus_step(SynthChorusState *chorus, float input) {
    /* Two taps half a cycle apart: one alone is a flanger, two is a chorus. */
    const float sweep = synth_patch_sine(chorus->lfoPhase);
    const float opposite = synth_patch_sine(chorus->lfoPhase + 0.5);
    chorus->lfoPhase = synth_patch_wrap(chorus->lfoPhase + chorus->lfoIncrement);

    const float first = synth_patch_chorus_tap(
        chorus, chorus->centreFrames + chorus->depthFrames * sweep);
    const float second = synth_patch_chorus_tap(
        chorus, chorus->centreFrames + chorus->depthFrames * opposite);
    const float wet = 0.5f * (first + second);

    chorus->buffer[chorus->writeIndex] = synth_patch_flush(
        synth_patch_finite(input + wet * chorus->feedback));
    chorus->writeIndex = (chorus->writeIndex + 1) & SYNTH_CHORUS_MASK;

    return input * (1.0f - chorus->mix) + wet * chorus->mix;
}

static inline float synth_patch_delay_step(SynthDelayState *delay, float input) {
    const float wet = delay->buffer[delay->writeIndex];

    /* One-pole low pass in the feedback path. Feedback is clamped below 1 and
       this removes energy on every pass, so the tail always ends. */
    delay->dampingState = synth_patch_flush(
        wet + (delay->dampingState - wet) * delay->dampingCoefficient);

    delay->buffer[delay->writeIndex] = synth_patch_flush(
        synth_patch_finite(input + delay->dampingState * delay->feedback));
    delay->writeIndex++;
    if (delay->writeIndex >= delay->lengthFrames) { delay->writeIndex = 0; }

    return input * (1.0f - delay->mix) + wet * delay->mix;
}

static inline float synth_patch_reverb_step(SynthReverbState *reverb, float input) {
    /* Pre-delay: the gap before the first reflection is most of what tells the
       ear how big the room is. */
    const float delayed = reverb->preDelay[reverb->preDelayIndex];
    reverb->preDelay[reverb->preDelayIndex] = synth_patch_flush(synth_patch_finite(input));
    reverb->preDelayIndex++;
    if (reverb->preDelayIndex >= reverb->preDelayLength) { reverb->preDelayIndex = 0; }

    /* Input scaled by (1 - feedback) so the eight combs sum to roughly unity
       whatever the room size; otherwise a large room would simply be louder
       rather than longer. */
    const float driven = delayed * 0.12f * (1.0f - reverb->feedback);

    float summed = 0.0f;
    for (int32_t index = 0; index < SYNTH_REVERB_COMB_COUNT; index++) {
        const float tap = reverb->comb[index][reverb->combIndex[index]];
        reverb->combStore[index] = synth_patch_flush(
            tap + (reverb->combStore[index] - tap) * reverb->damping);
        reverb->comb[index][reverb->combIndex[index]] = synth_patch_flush(
            synth_patch_finite(driven + reverb->combStore[index] * reverb->feedback));
        reverb->combIndex[index]++;
        if (reverb->combIndex[index] >= reverb->combLength[index]) { reverb->combIndex[index] = 0; }
        summed += tap;
    }

    float wet = summed;
    for (int32_t index = 0; index < SYNTH_REVERB_ALLPASS_COUNT; index++) {
        const float tap = reverb->allpass[index][reverb->allpassIndex[index]];
        const float output = tap - wet;
        reverb->allpass[index][reverb->allpassIndex[index]] = synth_patch_flush(
            synth_patch_finite(wet + tap * 0.5f));
        reverb->allpassIndex[index]++;
        if (reverb->allpassIndex[index] >= reverb->allpassLength[index]) {
            reverb->allpassIndex[index] = 0;
        }
        wet = output;
    }

    return input * (1.0f - reverb->mix) + wet * reverb->mix;
}

#pragma mark - The render callback

/// Play out whatever the editor's keyboard has queued. Render thread.
///
/// Defined here rather than beside `synth_patch_voice_adopt` so it can call the
/// note callbacks without forward declarations; it runs at the same point.
static void synth_patch_voice_drain_events(SynthPatchVoiceState *state) {
    const int64_t write = atomic_load_explicit(&state->liveNoteWrite, memory_order_acquire);
    int64_t read = atomic_load_explicit(&state->liveNoteRead, memory_order_relaxed);
    if (read == write) { return; }

    while (read < write) {
        const SynthLiveNoteEvent *event = &state->liveNotes[read & SYNTH_LIVE_NOTE_MASK];
        switch (event->kind) {
            case SynthLiveEventNoteOn:
                synth_patch_voice_note_on(state, event->note, event->velocity);
                break;
            case SynthLiveEventNoteOff:
                synth_patch_voice_note_off(state, event->note);
                break;
            case SynthLiveEventPedal:
                synth_patch_voice_set_pedal(state, event->velocity);
                break;
            case SynthLiveEventAllOff:
                /* Release rather than silence: closing the editor should let
                   the sound end the way the patch says it ends. */
                synth_patch_voice_set_pedal(state, 0);
                for (int32_t index = 0; index < SYNTH_PATCH_MAX_VOICES; index++) {
                    SynthPatchVoiceSlot *slot = &state->slots[index];
                    if (!slot->inUse) { continue; }
                    synth_patch_voice_note_off(state, slot->midiNoteNumber);
                }
                break;
            default:
                break;
        }
        read++;
    }

    atomic_store_explicit(&state->liveNoteRead, read, memory_order_release);
}

void synth_patch_voice_render(void *opaque, float *monoOut, int32_t frameCount) {
    SynthPatchVoiceState *state = (SynthPatchVoiceState *)opaque;

    /*
     The two control-thread crossings, both at a block boundary and both before
     a single sample is produced.

     A published patch is taken up whole, so no frame is ever rendered from
     half of one patch and half of another; a queued test note lands on the
     first frame of this block. Both are cheap enough to be unconditional: when
     nothing has been published and nothing is queued this is two relaxed
     atomic loads.
    */
    synth_patch_voice_adopt(state);
    synth_patch_voice_drain_events(state);

    const SynthPatchConfig *config = &state->config;

    for (int32_t frame = 0; frame < frameCount; frame++) { monoOut[frame] = 0.0f; }

    int32_t written = 0;
    while (written < frameCount) {
        /* Advance in control-block-aligned chunks. The alignment is the voice's
           own, so two runs that chop the buffer differently still hit the same
           modulation points and produce identical samples. */
        if (state->controlPhase == 0) {
            for (int32_t index = 0; index < SYNTH_PATCH_LFO_COUNT; index++) {
                state->freeLFOValue[index] = synth_patch_lfo_step(
                    &state->freeLFOPhase[index], &state->freeLFOHeld[index], &state->rng,
                    &config->lfos[index], state->lfoIncrement[index]);
            }
            for (int32_t index = 0; index < SYNTH_PATCH_MAX_VOICES; index++) {
                SynthPatchVoiceSlot *slot = &state->slots[index];
                /* The gain glide's origin, captured for every slot including
                   the ones that are only ringing down, so the interpolation
                   below is a function of position rather than of history. */
                slot->gainStart = slot->gainCurrent;
                if (!slot->inUse) { continue; }
                synth_patch_update_slot(state, slot);
                if (slot->amplitude.stage == SynthPatchEnvelopeIdle) {
                    slot->inUse = 0;
                    slot->midiNoteNumber = -1;
                    slot->heldByPedal = 0;
                    slot->gainTarget = 0.0f;
                }
            }
        }

        int32_t chunk = SYNTH_CONTROL_BLOCK_FRAMES - state->controlPhase;
        if (chunk > frameCount - written) { chunk = frameCount - written; }

        float *out = monoOut + written;

        for (int32_t index = 0; index < SYNTH_PATCH_MAX_VOICES; index++) {
            SynthPatchVoiceSlot *slot = &state->slots[index];
            /* Decided from `gainStart`, which only moves at a control-block
               boundary, so a chunk split inside a block cannot change whether
               a ringing-down slot is rendered. */
            if (!slot->inUse && slot->gainStart == 0.0f) { continue; }

            /*
             The gain glide, as a function of where we are in the control block
             rather than as a running sum.

             An accumulating `gain += step` gives a slightly different answer
             depending on where a chunk boundary happened to fall, because the
             running value is rounded to a float and the step recomputed from
             it. The error is around 1e-7 — inaudible, but it would make a
             render depend on the host's buffer size, and increment 006 has to
             be able to claim that an export is bit-identical to what was
             played.
            */
            const float span = slot->gainTarget - slot->gainStart;
            float gain = slot->gainStart;

            for (int32_t frame = 0; frame < chunk; frame++) {
                gain = slot->gainStart
                     + span * ((float)(state->controlPhase + frame + 1)
                               * (1.0f / (float)SYNTH_CONTROL_BLOCK_FRAMES));
                float mixed = 0.0f;

                for (int32_t osc = 0; osc < SYNTH_PATCH_OSCILLATOR_COUNT; osc++) {
                    switch (slot->oscMode[osc]) {
                        case SynthOscModeTable:
                            mixed += slot->oscLevel[osc]
                                   * synth_patch_read(slot->oscTableA[osc], slot->oscPhase[osc]);
                            break;
                        case SynthOscModeBlend: {
                            const float a = synth_patch_read(slot->oscTableA[osc], slot->oscPhase[osc]);
                            const float b = synth_patch_read(slot->oscTableB[osc], slot->oscPhase[osc]);
                            mixed += slot->oscLevel[osc] * (a + (b - a) * slot->oscTableBlend[osc]);
                            break;
                        }
                        case SynthOscModePulse: {
                            double shifted = slot->oscPhase[osc] + (double)slot->oscTableBlend[osc];
                            if (shifted >= 1.0) { shifted -= 1.0; }
                            const float a = synth_patch_read(slot->oscTableA[osc], slot->oscPhase[osc]);
                            const float b = synth_patch_read(slot->oscTableA[osc], shifted);
                            mixed += slot->oscLevel[osc] * (a - b) * 0.5f;
                            break;
                        }
                        case SynthOscModeFM: {
                            const float modulator = synth_patch_sine(slot->fmPhase[osc]);
                            const float phase = (float)slot->oscPhase[osc]
                                              + modulator * slot->fmDepth[osc] * (1.0f / 6.2831853f);
                            mixed += slot->oscLevel[osc] * synth_patch_sine((double)phase);
                            slot->fmPhase[osc] = synth_patch_advance(
                                slot->fmPhase[osc], slot->fmIncrement[osc]);
                            break;
                        }
                        default:
                            break;
                    }
                    if (slot->oscMode[osc] != SynthOscModeSilent) {
                        slot->oscPhase[osc] = synth_patch_advance(
                            slot->oscPhase[osc], slot->oscIncrement[osc]);
                    }
                }

                if (slot->noiseLevel > 0.0f) {
                    mixed += slot->noiseLevel * synth_patch_random(&slot->rng);
                }

                if (config->filter.isEnabled) {
                    mixed = synth_patch_filter_stage(slot, 0, mixed, config->filter.type);
                    if (config->filter.poles == 4) {
                        mixed = synth_patch_filter_stage(slot, 1, mixed, config->filter.type);
                    }
                }

                out[frame] += mixed * gain;
            }

            /* A finished note's ramp lands exactly on zero at the last frame
               of its control block — `a + (0 - a) * 1` is exactly zero — so
               the skip above starts firing on the next block with no need to
               snap anything, and a silent slot stops costing three table reads
               a sample for the rest of the piece. */
            slot->gainCurrent = gain;
        }

        written += chunk;
        state->controlPhase += chunk;
        if (state->controlPhase >= SYNTH_CONTROL_BLOCK_FRAMES) { state->controlPhase = 0; }
    }

    /*
     One fixed effect chain for the whole patch, after the voices are summed.

     Per patch rather than per voice: running it per voice would multiply its
     cost by the polyphony and would make a held chord's reverb louder than a
     single note's.

     Run unconditionally, including over silence. An earlier version of this
     stopped the chain once its input had been silent and its output below
     -140 dBFS for long enough, on the reasoning that a line which is not
     playing should not keep paying for eight comb filters and four allpasses.
     It was wrong, and `testAboveTheSizedRateTheLongestDelayShortensPredictably`
     is what caught it: a delay line holds up to a second of audio that has not
     reached the output yet, and a reverb pre-delay holds another tenth. Silent
     output does not mean an empty chain, so the shortcut swallowed the repeat
     entirely. Making it safe would mean tracking every stage's internal
     latency; measured against the eighteen-line orchestral reference the
     shortcut saved nothing at all, because in a real score the lines are
     almost never silent. So it is gone rather than repaired.
    */
    for (int32_t frame = 0; frame < frameCount; frame++) {
        float sample = monoOut[frame];

        if (config->equalizer.isEnabled) {
            sample = synth_patch_biquad_step(&state->equalizer.low, sample);
            sample = synth_patch_biquad_step(&state->equalizer.mid, sample);
            sample = synth_patch_biquad_step(&state->equalizer.high, sample);
        }
        if (config->chorus.isEnabled) { sample = synth_patch_chorus_step(&state->chorus, sample); }
        if (config->delay.isEnabled)  { sample = synth_patch_delay_step(&state->delay, sample); }
        if (config->reverb.isEnabled) { sample = synth_patch_reverb_step(&state->reverb, sample); }

        monoOut[frame] = synth_patch_flush(synth_patch_limit(synth_patch_finite(sample)));
    }
}

#pragma mark - Auditioning one voice on its own

/*
 One patch, straight into a stereo buffer list.

 The editor auditions a sound that belongs to no piece, so there is no program
 for `synth_audio_core_render` to walk: no timeline, no lines, no mixer, no
 transport. What is left is exactly this — take the queued test notes, render
 the voice, and put the mono result in both channels.

 It is here rather than in Swift for the reason the whole render path is here.
 The alternative is a Swift loop copying one channel into another on the audio
 thread, and `RealtimeSafetyTests` exists precisely so that no such loop
 appears. Rendering straight into the left channel and copying it across means
 the voice needs no scratch buffer of its own, so this call allocates nothing
 and the audition path costs the voice state and not a byte more.

 `isSilence` is always reported as false. A voice with a second of delay and a
 tenth of reverb pre-delay holds audio that has not reached the output yet, so
 a silent block is not an idle chain — the render core makes the same point
 about the effect chain it runs unconditionally.
*/
int32_t synth_patch_voice_render_stereo(SynthPatchVoiceState *state,
                                        AudioBufferList *bufferList,
                                        int32_t frameCount,
                                        int32_t *isSilence) {
    if (isSilence != NULL) { *isSilence = 0; }
    if (state == NULL || bufferList == NULL || frameCount <= 0) { return 0; }
    if (bufferList->mNumberBuffers < 1) { return 0; }

    float *left = (float *)bufferList->mBuffers[0].mData;
    if (left == NULL) { return 0; }

    synth_patch_voice_render(state, left, frameCount);

    for (UInt32 index = 1; index < bufferList->mNumberBuffers; index++) {
        float *channel = (float *)bufferList->mBuffers[index].mData;
        if (channel == NULL) { continue; }
        for (int32_t frame = 0; frame < frameCount; frame++) {
            channel[frame] = left[frame];
        }
    }

    return 0;
}
