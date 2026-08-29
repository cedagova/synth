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

#include <stdlib.h>
#include <string.h>

#include "SampleVoiceEngineInternal.h"

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
