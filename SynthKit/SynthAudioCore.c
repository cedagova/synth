#include "SynthAudioCore.h"
#include <stdatomic.h>
int32_t synth_audio_core_probe(int32_t value) {
    _Atomic int32_t v = value;
    return atomic_load_explicit(&v, memory_order_acquire) + 1;
}
