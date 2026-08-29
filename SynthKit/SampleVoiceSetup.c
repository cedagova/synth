/*
 SampleVoiceSetup.c — building and tearing down a sampled-instrument voice.

 The control-thread half of the split `SampleVoiceEngine.c` documents: this is
 the only file in the sampler that allocates, and it never runs on the audio
 thread. `RealtimeSafetyTests` scans the render core for allocation and finds
 none precisely because everything that allocates is here.

 There is exactly one allocation per voice — the `SampleVoiceState` block — and
 it is sized at compile time. The instrument tables the voice reads are owned
 by the Swift `SampledInstrument` and shared by every voice over that
 instrument, so two lines assigned the same violin cost one copy of the
 samples and two of this struct.
 */

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "SampleVoiceEngineInternal.h"

void sample_voice_fill_silence(SynthLineVoice *outVoice) {
    /* The implementation lives in the render core beside the callbacks it
       installs; this is the public door onto it, so a Swift caller does not
       need the internal header. */
    sample_voice_fill_silent(outVoice);
}

SampleVoiceCustomization sample_voice_customization_neutral(void) {
    SampleVoiceCustomization neutral;
    neutral.toneLowGain = 1.0f;
    neutral.toneHighGain = 1.0f;
    neutral.dynamicsResponse = 1.0f;
    neutral.attackSecondsAdded = 0.0f;
    neutral.releaseScale = 1.0f;
    neutral.vibratoDepthCents = 0.0f;
    neutral.vibratoRateHz = 5.0f;
    neutral.tuningRatio = 1.0f;
    return neutral;
}

/// A finite value inside `low`…`high`, or `fallback` when it is neither.
static float sample_voice_bounded(float value, float low, float high, float fallback) {
    if (!(value == value)) { return fallback; }
    if (value < low) { return low; }
    if (value > high) { return high; }
    return value;
}

void sample_voice_set_customization(SampleVoiceState *state,
                                    const SampleVoiceCustomization *customization) {
    if (state == NULL) { return; }

    const SampleVoiceCustomization neutral = sample_voice_customization_neutral();
    const SampleVoiceCustomization *source = customization != NULL ? customization : &neutral;

    /* Bounds are the same ones `InstrumentCustomization` offers, converted:
       ±12 dB is 0.251…3.981 as a ratio, and ±100 cents is 0.9439…1.0595. A
       caller outside them is a bug or a hand-edited document, and either way
       the render loop is handed something playable rather than a NaN. */
    atomic_store_explicit(&state->customToneLowGain,
        sample_voice_bounded(source->toneLowGain, 0.2f, 4.0f, 1.0f), memory_order_relaxed);
    atomic_store_explicit(&state->customToneHighGain,
        sample_voice_bounded(source->toneHighGain, 0.2f, 4.0f, 1.0f), memory_order_relaxed);
    atomic_store_explicit(&state->customDynamicsResponse,
        sample_voice_bounded(source->dynamicsResponse, 0.0f, 2.0f, 1.0f), memory_order_relaxed);
    atomic_store_explicit(&state->customAttackSecondsAdded,
        sample_voice_bounded(source->attackSecondsAdded, 0.0f, 0.5f, 0.0f), memory_order_relaxed);
    atomic_store_explicit(&state->customReleaseScale,
        sample_voice_bounded(source->releaseScale, 0.25f, 4.0f, 1.0f), memory_order_relaxed);
    atomic_store_explicit(&state->customVibratoDepthCents,
        sample_voice_bounded(source->vibratoDepthCents, 0.0f, 100.0f, 0.0f), memory_order_relaxed);
    atomic_store_explicit(&state->customVibratoRateHz,
        sample_voice_bounded(source->vibratoRateHz, 0.5f, 9.0f, 5.0f), memory_order_relaxed);
    atomic_store_explicit(&state->customTuningRatio,
        sample_voice_bounded(source->tuningRatio, 0.9f, 1.1f, 1.0f), memory_order_relaxed);

    atomic_fetch_add_explicit(&state->customizationAdoptions, 1, memory_order_relaxed);
}

SampleVoiceCustomization sample_voice_customization(const SampleVoiceState *state) {
    if (state == NULL) { return sample_voice_customization_neutral(); }

    SampleVoiceCustomization current;
    current.toneLowGain =
        atomic_load_explicit(&state->customToneLowGain, memory_order_relaxed);
    current.toneHighGain =
        atomic_load_explicit(&state->customToneHighGain, memory_order_relaxed);
    current.dynamicsResponse =
        atomic_load_explicit(&state->customDynamicsResponse, memory_order_relaxed);
    current.attackSecondsAdded =
        atomic_load_explicit(&state->customAttackSecondsAdded, memory_order_relaxed);
    current.releaseScale =
        atomic_load_explicit(&state->customReleaseScale, memory_order_relaxed);
    current.vibratoDepthCents =
        atomic_load_explicit(&state->customVibratoDepthCents, memory_order_relaxed);
    current.vibratoRateHz =
        atomic_load_explicit(&state->customVibratoRateHz, memory_order_relaxed);
    current.tuningRatio =
        atomic_load_explicit(&state->customTuningRatio, memory_order_relaxed);
    return current;
}

int64_t sample_voice_customization_adoptions(const SampleVoiceState *state) {
    if (state == NULL) { return 0; }
    return atomic_load_explicit(&state->customizationAdoptions, memory_order_relaxed);
}

SampleVoiceState *sample_voice_create(const SampleInstrumentData *instrument,
                                      SynthLineVoice *outVoice,
                                      double sampleRate,
                                      uint64_t seed) {
    if (outVoice == NULL) { return NULL; }

    /* Every failure below leaves the caller holding a working vtable that
       renders silence, so a line whose voice could not be built is still a line
       the render thread can call into. Silence rather than some other sound is
       the point: see the note on `sample_voice_create` in the header. */
    sample_voice_fill_silent(outVoice);
    if (instrument == NULL) { return NULL; }

    SampleVoiceState *state = (SampleVoiceState *)calloc(1, sizeof(SampleVoiceState));
    if (state == NULL) { return NULL; }

    state->instrument = instrument;
    state->sampleRate = sampleRate > 0.0 ? sampleRate : 44100.0;

    /* A zero seed would leave xorshift stuck at zero for ever, which would
       make every random round robin pick the same alternate. */
    state->randomSeed = seed == 0 ? 0x9E3779B97F4A7C15ULL : seed;

    atomic_store_explicit(&state->stolenSlots, 0, memory_order_relaxed);
    atomic_store_explicit(&state->unmappedNotes, 0, memory_order_relaxed);
    atomic_store_explicit(&state->peakSlots, 0, memory_order_relaxed);

    /* The instrument as recorded, so a voice built without a customization
       sounds exactly like INS002's did. `sample_voice_set_customization` then
       counts its own first adoption, which is what a caller checks against. */
    const SampleVoiceCustomization neutral = sample_voice_customization_neutral();
    sample_voice_set_customization(state, &neutral);
    atomic_store_explicit(&state->customizationAdoptions, 0, memory_order_relaxed);

    /* Clears every slot, seats the default keyswitch and rewinds the seeded
       sequence, so a freshly built voice and a reset one are the same voice. */
    sample_voice_reset(state);

    memset(outVoice, 0, sizeof(*outVoice));
    outVoice->state = state;
    outVoice->prepare = sample_voice_prepare;
    outVoice->noteOn = sample_voice_note_on;
    outVoice->noteOff = sample_voice_note_off;
    outVoice->setSustainPedal = sample_voice_set_sustain_pedal;
    outVoice->render = sample_voice_render;
    outVoice->reset = sample_voice_reset;

    return state;
}

void sample_voice_destroy(SampleVoiceState *state) {
    if (state == NULL) { return; }
    /* The instrument tables and the sample mappings belong to the Swift side
       and outlive every voice over them; only this block is ours. */
    free(state);
}
