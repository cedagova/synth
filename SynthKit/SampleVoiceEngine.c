/*
 SampleVoiceEngine.c — everything the sampled instrument does on the audio
 thread, and nothing else.

 The split against `SampleVoiceSetup.c` is the same one `SynthAudioCore.c` and
 `SynthPatchEngine.c` already make, and it exists so that
 `RealtimeSafetyTests.testRenderCoresContainNoRealtimeUnsafeCall` can be a scan
 of a whole file rather than a judgement about which function runs where. There
 is no allocation, no lock, no message send and no logging in this file.

 What one note costs here, in order:

   1. `sample_voice_note_on` scans the regions indexed under that key — a
      handful, never the whole library — and starts a slot for each region
      whose velocity, round-robin, random and keyswitch conditions match.
   2. `sample_voice_render` walks the active slots, reads each one's source
      frames through a four-point Hermite interpolation, applies its envelope
      and level, and sums into the line's mono buffer.
   3. `sample_voice_note_off` releases those slots — unless the sustain pedal
      is down, in which case the key is remembered and released when the pedal
      lifts — and starts any `trigger=release` regions the library provides,
      attenuated by how long the note was held (`rt_decay`).

 Reading source frames means reading a memory-mapped file. That is the one
 thing in here that can block, and it is why `SampledInstrument` faults in each
 waveform's attack region before a voice is ever built.
 */

#include <math.h>

#include "SampleVoiceEngineInternal.h"

#pragma mark - Small helpers

static inline float sample_clampf(float value, float low, float high) {
    if (value < low) { return low; }
    if (value > high) { return high; }
    return value;
}

/// Replace a non-finite sample with silence.
///
/// A corrupt or truncated sample file is INS001's problem to re-download, but
/// it must never reach the output device as a NaN that poisons the mix for
/// every other line.
static inline float sample_finite(float value) {
    return (value == value && value * 0.0f == 0.0f) ? value : 0.0f;
}

/// Flush denormals, which cost hundreds of cycles each on a release tail.
static inline float sample_flush(float value) {
    return (value < 1.0e-25f && value > -1.0e-25f) ? 0.0f : value;
}

/*
 The same soft knee the synthesizer's output stage uses.

 Both engines feed the same mixer, so both must behave the same way when a
 sound is hotter than unity — and sampled orchestral libraries genuinely are.
 VSCO 2 writes `volume=12` on quiet layers to bring them up, and a chord of
 those at full velocity sums past ±1 without any error having occurred.
 */
#define SAMPLE_LIMIT_KNEE 0.85f

static inline float sample_limit(float value) {
    const float magnitude = value < 0.0f ? -value : value;
    if (magnitude <= SAMPLE_LIMIT_KNEE) { return value; }
    const float headroom = 1.0f - SAMPLE_LIMIT_KNEE;
    const float over = (magnitude - SAMPLE_LIMIT_KNEE) / headroom;
    /* tanh, near enough, without the call. */
    const float bent = over * (27.0f + over * over) / (27.0f + 9.0f * over * over);
    const float shaped = SAMPLE_LIMIT_KNEE + headroom * sample_clampf(bent, 0.0f, 1.0f);
    return value < 0.0f ? -shaped : shaped;
}

/// xorshift64*: one multiply and three shifts, no state beyond a word.
///
/// Seeded per voice and reset with the voice, so an offline render of the same
/// line makes the same random round-robin choices every time — which is what
/// REQ-012's byte-identity claim needs from a player that deliberately varies.
static inline uint64_t sample_random_next(uint64_t *state) {
    uint64_t x = *state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *state = x;
    return x * 0x2545F4914F6CDD1DULL;
}

/// The next draw, in 0…1 (never quite 1).
static inline float sample_random_unit(uint64_t *state) {
    return (float)((double)(sample_random_next(state) >> 11) / 9007199254740992.0);
}

/*
 Does `draw` fall in this region's `lorand`…`hirand` window?

 SFZ's random round robins partition 0…1 between the alternates, and the draw
 is in 0…1 exclusive of the top, so a half-open test covers the partition
 exactly and the default 0…1 window accepts everything.
 */
static inline int32_t sample_region_takes_draw(const SampleRegionData *region, float draw) {
    return draw >= region->randomLow && draw < region->randomHigh;
}

/// Does this region's round-robin position come up on this repetition?
static inline int32_t sample_region_takes_turn(const SampleRegionData *region, uint32_t sequence) {
    if (region->sequenceLength <= 1) { return 1; }
    return (int32_t)(sequence % (uint32_t)region->sequenceLength) + 1 == region->sequencePosition;
}

#pragma mark - Reading source frames

/*
 Scalar loads that do not care how the file's audio happens to be aligned.

 A `data` chunk starts wherever the chunks before it end, and the curated set
 puts a `junk` or `bext` chunk there in 618 of its files — so the first sample
 can begin at any even offset, and casting the mapping to `const float *` would
 be an unaligned access. `__builtin_memcpy` of a fixed small size is not a
 library call: on arm64 it compiles to the same single load, with no
 alignment assumption attached to it.
 */
static inline int16_t sample_load_i16(const uint8_t *bytes) {
    int16_t value;
    __builtin_memcpy(&value, bytes, sizeof value);
    return value;
}

static inline int32_t sample_load_i32(const uint8_t *bytes) {
    int32_t value;
    __builtin_memcpy(&value, bytes, sizeof value);
    return value;
}

static inline float sample_load_f32(const uint8_t *bytes) {
    float value;
    __builtin_memcpy(&value, bytes, sizeof value);
    return value;
}

static inline double sample_load_f64(const uint8_t *bytes) {
    double value;
    __builtin_memcpy(&value, bytes, sizeof value);
    return value;
}

/*
 One mono frame of `waveform` at integer frame `index`, summed if it is stereo.

 The line-voice interface renders mono because the engine owns pan (see
 `SynthLineVoice` in `SynthAudioCore.h`), so a stereo sample is folded here.
 That does lose the recorded stereo image of an orchestral sample; it is a
 property of the interface both engines implement, not of this one.

 Out-of-range indices return silence rather than reading past the mapping.
 */
static inline float sample_frame_at(const SampleWaveformData *waveform, int64_t index) {
    if (index < 0 || index >= waveform->frameCount) { return 0.0f; }

    const int32_t channels = waveform->channelCount;
    const int64_t base = index * (int64_t)channels;
    const uint8_t *bytes = (const uint8_t *)waveform->frames;

    switch (waveform->format) {
    case SampleFrameFormatPCM16: {
        float sum = 0.0f;
        for (int32_t channel = 0; channel < channels; channel++) {
            sum += (float)sample_load_i16(bytes + (base + channel) * 2);
        }
        return sum / ((float)channels * 32768.0f);
    }
    case SampleFrameFormatPCM24: {
        float sum = 0.0f;
        for (int32_t channel = 0; channel < channels; channel++) {
            const uint8_t *frame = bytes + (base + channel) * 3;
            /* Little-endian, sign-extended from 24 bits. */
            int32_t value = (int32_t)((uint32_t)frame[0]
                                      | ((uint32_t)frame[1] << 8)
                                      | ((uint32_t)frame[2] << 16));
            if (value & 0x800000) { value |= (int32_t)0xFF000000; }
            sum += (float)value;
        }
        return sum / ((float)channels * 8388608.0f);
    }
    case SampleFrameFormatPCM32: {
        float sum = 0.0f;
        for (int32_t channel = 0; channel < channels; channel++) {
            sum += (float)sample_load_i32(bytes + (base + channel) * 4) / 2147483648.0f;
        }
        return sum / (float)channels;
    }
    case SampleFrameFormatFloat32: {
        float sum = 0.0f;
        for (int32_t channel = 0; channel < channels; channel++) {
            sum += sample_load_f32(bytes + (base + channel) * 4);
        }
        return sum / (float)channels;
    }
    case SampleFrameFormatFloat64: {
        double sum = 0.0;
        for (int32_t channel = 0; channel < channels; channel++) {
            sum += sample_load_f64(bytes + (base + channel) * 8);
        }
        return (float)(sum / (double)channels);
    }
    default:
        return 0.0f;
    }
}

/*
 Four-point Hermite interpolation at a fractional position.

 Linear interpolation would be cheaper, but a sampler spends most of its life
 reading at a non-integer rate — every note away from its `pitch_keycenter`,
 and every 48 kHz sample in a 44.1 kHz render — and linear's response is
 audibly dull at the top of a violin's range. Hermite is the standard four-tap
 answer and costs about a dozen more flops per sample.
 */
static inline float sample_interpolate(const SampleWaveformData *waveform, double position) {
    const int64_t index = (int64_t)position;
    const float fraction = (float)(position - (double)index);

    const float previous = sample_frame_at(waveform, index - 1);
    const float current = sample_frame_at(waveform, index);
    const float next = sample_frame_at(waveform, index + 1);
    const float following = sample_frame_at(waveform, index + 2);

    const float c0 = current;
    const float c1 = 0.5f * (next - previous);
    const float c2 = previous - 2.5f * current + 2.0f * next - 0.5f * following;
    const float c3 = 0.5f * (following - previous) + 1.5f * (current - next);

    return ((c3 * fraction + c2) * fraction + c1) * fraction + c0;
}

#pragma mark - Slot lifecycle

/// The slot to use for a new note: a free one, or the oldest sounding one.
///
/// A sampler steals rather than drops. Dropping the note would leave a hole in
/// the music; stealing the oldest slot truncates a note that has already been
/// sounding longest, which is the least audible choice available. The steal is
/// counted so `sample_voice_stolen_slots` can say whether the ceiling was ever
/// actually reached.
static int32_t sample_voice_claim_slot(SampleVoiceState *state) {
    int32_t oldest = 0;
    int64_t oldestOrder = INT64_MAX;

    for (int32_t index = 0; index < SAMPLE_VOICE_MAX_SLOTS; index++) {
        if (!state->slots[index].inUse) { return index; }
        if (state->slots[index].startOrder < oldestOrder) {
            oldestOrder = state->slots[index].startOrder;
            oldest = index;
        }
    }

    atomic_fetch_add_explicit(&state->stolenSlots, 1, memory_order_relaxed);
    return oldest;
}

/// Per-frame multiplier that falls to a thousandth of its starting value over
/// `seconds`. Zero or negative time means "immediately".
static inline float sample_decay_coefficient(float seconds, double sampleRate) {
    if (seconds <= 0.0f) { return 0.0f; }
    const double frames = (double)seconds * sampleRate;
    if (frames < 1.0) { return 0.0f; }
    return (float)exp(-6.907755278982137 / frames); /* ln(1/1000) */
}

/*
 Start one region as a sounding slot.

 `heldSeconds` is only meaningful for a release trigger, where `rt_decay` turns
 it into an attenuation: Salamander's string resonances are 6 to 9 dB per
 second quieter the longer the note was held, which is what makes them track
 the note rather than punctuate every release identically.
 */
static void sample_voice_start_region(SampleVoiceState *state,
                                      int32_t regionIndex,
                                      int32_t key,
                                      int32_t velocity,
                                      int32_t isReleaseTrigger,
                                      double heldSeconds) {
    const SampleRegionData *region = &state->instrument->regions[regionIndex];
    if (region->waveformIndex < 0 || region->waveformIndex >= state->instrument->waveformCount) {
        return;
    }
    const SampleWaveformData *waveform = &state->instrument->waveforms[region->waveformIndex];
    if (waveform->frames == NULL || waveform->frameCount <= 0) { return; }

    const int32_t index = sample_voice_claim_slot(state);
    SampleVoiceSlot *slot = &state->slots[index];

    slot->inUse = 1;
    slot->regionIndex = regionIndex;
    slot->key = key;
    slot->isReleaseTrigger = isReleaseTrigger;
    slot->startOrder = ++state->startCounter;

    /* Pitch: how far the key is from the sample's recorded pitch, scaled by
       `pitch_keytrack`, plus the region's own tuning — and then the ratio
       between the file's rate and the engine's, so a 48 kHz sample in a
       44.1 kHz render is resampled rather than transposed. */
    const double semitones = (double)(key - region->pitchKeycenter) * (double)region->pitchKeytrack
                           + (double)region->tuneSemitones;
    double increment = pow(2.0, semitones / 12.0);
    if (waveform->sampleRate > 0.0 && state->sampleRate > 0.0) {
        increment *= waveform->sampleRate / state->sampleRate;
    }
    /* A ratio outside this range is a corrupt keycenter, not music. */
    slot->increment = increment < 0.000244140625 ? 0.000244140625
                    : (increment > 64.0 ? 64.0 : increment);

    /* Velocity: SFZ's `amp_veltrack` interpolates between "loudness ignores
       velocity" and "loudness follows velocity squared". */
    const float normalized = (float)velocity / 127.0f;
    const float tracking = region->ampVelocityTracking;
    float gain = 1.0f + tracking * (normalized * normalized - 1.0f);
    gain = sample_clampf(gain, 0.0f, 4.0f) * region->gainLinear;

    if (isReleaseTrigger && region->releaseTriggerDecayDBPerSecond > 0.0f) {
        const double attenuation = (double)region->releaseTriggerDecayDBPerSecond * heldSeconds;
        gain *= (float)pow(10.0, -attenuation / 20.0);
    }
    slot->levelGain = gain;

    slot->position = (double)region->sampleOffset;
    slot->playEnd = region->sampleEnd >= 0 && region->sampleEnd < waveform->frameCount
                  ? region->sampleEnd
                  : waveform->frameCount;

    slot->loopStart = region->loopStart >= 0 ? region->loopStart : waveform->fileLoopStart;
    slot->loopEnd = region->loopEnd >= 0 ? region->loopEnd : waveform->fileLoopEnd;

    /* SFZ 1.0's rule for an unstated `loop_mode`: a sample with loop points
       loops, one without does not. It matters — the only loops anywhere in the
       curated set are in VSCO 2's upright piano, declared in the WAV's own
       `smpl` chunk with no SFZ opcode at all, and a player that waited for
       `loop_mode=loop_continuous` would never find them. */
    const int32_t hasLoopPoints = slot->loopStart >= 0
        && slot->loopEnd > slot->loopStart
        && slot->loopEnd < waveform->frameCount;
    if (region->loopMode < 0) {
        slot->loopMode = hasLoopPoints ? SampleLoopModeContinuous : SampleLoopModeNone;
    } else {
        slot->loopMode = region->loopMode;
    }
    if (!hasLoopPoints && slot->loopMode != SampleLoopModeOneShot) {
        slot->loopMode = SampleLoopModeNone;
    }

    slot->sustainLevel = sample_clampf(region->sustainLevel, 0.0f, 1.0f);
    slot->decayCoefficient = sample_decay_coefficient(region->decaySeconds, state->sampleRate);
    slot->releaseCoefficient = sample_decay_coefficient(region->releaseSeconds, state->sampleRate);

    if (region->attackSeconds > 0.0f) {
        const double frames = (double)region->attackSeconds * state->sampleRate;
        slot->attackIncrement = frames < 1.0 ? 1.0f : (float)(1.0 / frames);
        slot->envelope = 0.0f;
        slot->stage = SampleEnvelopeStageAttack;
    } else {
        slot->attackIncrement = 1.0f;
        slot->envelope = 1.0f;
        slot->stage = region->decaySeconds > 0.0f ? SampleEnvelopeStageDecay
                                                  : SampleEnvelopeStageSustain;
    }

    /* A release trigger has no note to hold it, so it starts already
       releasing: its own sample is the whole sound. */
    if (isReleaseTrigger) {
        slot->stage = SampleEnvelopeStageSustain;
    }
}

/// Put every slot sounding for `key` into its release stage.
static void sample_voice_release_slots(SampleVoiceState *state, int32_t key) {
    for (int32_t index = 0; index < SAMPLE_VOICE_MAX_SLOTS; index++) {
        SampleVoiceSlot *slot = &state->slots[index];
        if (!slot->inUse || slot->key != key || slot->isReleaseTrigger) { continue; }
        /* A one-shot region ignores note-off by definition: that is what makes
           a cymbal ring out rather than stop when the notated note ends. */
        if (slot->loopMode == SampleLoopModeOneShot) { continue; }
        slot->stage = SampleEnvelopeStageRelease;
    }
}

/*
 Everything that happens when a key genuinely stops sounding.

 Called from note-off with the pedal up, and from the pedal lifting for every
 key that was being held. Both paths must start the release triggers, because
 the damper falls at the same moment either way.
 */
static void sample_voice_end_key(SampleVoiceState *state, int32_t key) {
    const SampleInstrumentData *instrument = state->instrument;

    const double heldSeconds = state->sampleRate > 0.0
        ? (double)(state->frameCounter - state->keyOnFrame[key]) / state->sampleRate
        : 0.0;
    const int32_t velocity = state->keyVelocity[key];

    sample_voice_release_slots(state, key);

    const int32_t begin = instrument->keyRegionStart[key];
    const int32_t end = instrument->keyRegionStart[key + 1];
    const uint32_t sequence = state->keySequence[key];
    const float draw = sample_random_unit(&state->randomState);

    for (int32_t cursor = begin; cursor < end; cursor++) {
        const int32_t regionIndex = instrument->keyRegions[cursor];
        const SampleRegionData *region = &instrument->regions[regionIndex];

        if (region->trigger != SampleRegionTriggerRelease) { continue; }
        if (velocity < region->loVelocity || velocity > region->hiVelocity) { continue; }
        if (region->switchKey >= 0 && region->switchKey != state->currentSwitchKey) { continue; }
        if (!sample_region_takes_turn(region, sequence)) { continue; }
        if (!sample_region_takes_draw(region, draw)) { continue; }

        sample_voice_start_region(state, regionIndex, key, velocity, 1, heldSeconds);
    }

    state->keyIsDown[key] = 0;
    state->keyIsPedalHeld[key] = 0;
}

#pragma mark - Vtable callbacks

/*
 Prepare, at the graph's sample rate.

 The engine calls this on the control thread before rendering and again on a
 device or offline-mode change. It may not allocate — every slot already
 exists — so all it does is re-derive the rate and silence what was sounding at
 the old one.
 */
void sample_voice_prepare(void *opaque, double sampleRate) {
    SampleVoiceState *state = (SampleVoiceState *)opaque;
    if (state == NULL) { return; }
    state->sampleRate = sampleRate > 0.0 ? sampleRate : 44100.0;
    sample_voice_reset(state);
}

void sample_voice_reset(void *opaque) {
    SampleVoiceState *state = (SampleVoiceState *)opaque;
    if (state == NULL) { return; }

    for (int32_t index = 0; index < SAMPLE_VOICE_MAX_SLOTS; index++) {
        state->slots[index].inUse = 0;
        state->slots[index].envelope = 0.0f;
    }
    for (int32_t key = 0; key < SAMPLE_VOICE_KEY_COUNT; key++) {
        state->keyIsDown[key] = 0;
        state->keyIsPedalHeld[key] = 0;
        state->keyVelocity[key] = 0;
        state->keyOnFrame[key] = 0;
        state->keySequence[key] = 0;
    }
    state->pedalIsDown = 0;
    state->frameCounter = 0;
    state->startCounter = 0;
    state->currentSwitchKey = state->instrument != NULL
        ? state->instrument->defaultSwitchKey
        : -1;

    /* Back to the beginning of the seeded sequence, so a seek does not change
       which round robin a passage plays. */
    state->randomState = state->randomSeed;

    /* The telemetry counters deliberately survive a reset. The engine resets
       every voice on stop and on seek, and a peak or a steal that a seek then
       erased would make the numbers say the line was easier to render than it
       was. */
}

void sample_voice_note_on(void *opaque, int32_t midiNoteNumber, int32_t velocity) {
    SampleVoiceState *state = (SampleVoiceState *)opaque;
    if (state == NULL || state->instrument == NULL) { return; }
    if (midiNoteNumber < 0 || midiNoteNumber >= SAMPLE_VOICE_KEY_COUNT) { return; }

    const SampleInstrumentData *instrument = state->instrument;
    const int32_t key = midiNoteNumber;

    /* A note inside the keyswitch range selects an articulation and sounds
       nothing — that is what a keyswitch is. Nothing in the curated set puts a
       playable range over its switches, but honouring it is what keeps a
       keyswitched patch from playing all four articulations at once. */
    if (instrument->switchLowKey >= 0
        && key >= instrument->switchLowKey && key <= instrument->switchHighKey) {
        state->currentSwitchKey = key;
        return;
    }

    const int32_t clampedVelocity = velocity < 1 ? 1 : (velocity > 127 ? 127 : velocity);
    const uint32_t sequence = state->keySequence[key];
    const float draw = sample_random_unit(&state->randomState);
    state->keySequence[key] = sequence + 1;

    const int32_t begin = instrument->keyRegionStart[key];
    const int32_t end = instrument->keyRegionStart[key + 1];
    int32_t started = 0;

    for (int32_t cursor = begin; cursor < end; cursor++) {
        const int32_t regionIndex = instrument->keyRegions[cursor];
        const SampleRegionData *region = &instrument->regions[regionIndex];

        if (region->trigger != SampleRegionTriggerAttack) { continue; }
        if (clampedVelocity < region->loVelocity || clampedVelocity > region->hiVelocity) {
            continue;
        }
        if (region->switchKey >= 0 && region->switchKey != state->currentSwitchKey) { continue; }
        if (!sample_region_takes_turn(region, sequence)) { continue; }
        if (!sample_region_takes_draw(region, draw)) { continue; }

        sample_voice_start_region(state, regionIndex, key, clampedVelocity, 0, 0.0);
        started++;
    }

    if (started == 0) {
        atomic_fetch_add_explicit(&state->unmappedNotes, 1, memory_order_relaxed);
        return;
    }

    state->keyIsDown[key] = 1;
    state->keyIsPedalHeld[key] = 0;
    state->keyVelocity[key] = clampedVelocity;
    state->keyOnFrame[key] = state->frameCounter;
}

void sample_voice_note_off(void *opaque, int32_t midiNoteNumber) {
    SampleVoiceState *state = (SampleVoiceState *)opaque;
    if (state == NULL || state->instrument == NULL) { return; }
    if (midiNoteNumber < 0 || midiNoteNumber >= SAMPLE_VOICE_KEY_COUNT) { return; }

    const int32_t key = midiNoteNumber;
    if (!state->keyIsDown[key]) { return; }

    if (state->pedalIsDown) {
        /* The damper has not fallen yet: keep the note sounding and remember
           it, so the pedal lifting releases it and starts its release layer. */
        state->keyIsDown[key] = 0;
        state->keyIsPedalHeld[key] = 1;
        return;
    }

    sample_voice_end_key(state, key);
}

void sample_voice_set_sustain_pedal(void *opaque, int32_t isDown) {
    SampleVoiceState *state = (SampleVoiceState *)opaque;
    if (state == NULL || state->instrument == NULL) { return; }

    const int32_t down = isDown != 0;
    if (down == state->pedalIsDown) { return; }
    state->pedalIsDown = down;
    if (down) { return; }

    for (int32_t key = 0; key < SAMPLE_VOICE_KEY_COUNT; key++) {
        if (state->keyIsPedalHeld[key]) { sample_voice_end_key(state, key); }
    }
}

/// Advance one slot's envelope by one frame, and report whether it is finished.
static inline int32_t sample_voice_step_envelope(SampleVoiceSlot *slot) {
    switch (slot->stage) {
    case SampleEnvelopeStageAttack:
        slot->envelope += slot->attackIncrement;
        if (slot->envelope >= 1.0f) {
            slot->envelope = 1.0f;
            slot->stage = slot->decayCoefficient > 0.0f ? SampleEnvelopeStageDecay
                                                        : SampleEnvelopeStageSustain;
        }
        return 0;
    case SampleEnvelopeStageDecay:
        slot->envelope = slot->sustainLevel
                       + (slot->envelope - slot->sustainLevel) * slot->decayCoefficient;
        if (slot->envelope - slot->sustainLevel < 0.0005f) {
            slot->envelope = slot->sustainLevel;
            slot->stage = SampleEnvelopeStageSustain;
        }
        return 0;
    case SampleEnvelopeStageRelease:
        slot->envelope *= slot->releaseCoefficient;
        return slot->envelope < 0.0001f;
    default:
        return 0;
    }
}

void sample_voice_render(void *opaque, float *monoOut, int32_t frameCount) {
    SampleVoiceState *state = (SampleVoiceState *)opaque;
    if (monoOut == NULL || frameCount <= 0) { return; }

    /* The interface says overwrite, not add: the engine owns gain, pan, mute
       and solo, and it reads this buffer as the line's whole contribution. */
    for (int32_t frame = 0; frame < frameCount; frame++) { monoOut[frame] = 0.0f; }
    if (state == NULL || state->instrument == NULL) { return; }

    int32_t sounding = 0;

    for (int32_t index = 0; index < SAMPLE_VOICE_MAX_SLOTS; index++) {
        SampleVoiceSlot *slot = &state->slots[index];
        if (!slot->inUse) { continue; }

        const SampleRegionData *region = &state->instrument->regions[slot->regionIndex];
        const SampleWaveformData *waveform = &state->instrument->waveforms[region->waveformIndex];
        sounding++;

        for (int32_t frame = 0; frame < frameCount; frame++) {
            /* A sustain loop stops looping once the note is released, so the
               sample plays through its own tail instead of repeating it. */
            const int32_t looping = slot->loopMode == SampleLoopModeContinuous
                || (slot->loopMode == SampleLoopModeSustain
                    && slot->stage != SampleEnvelopeStageRelease);

            if (looping && slot->position >= (double)slot->loopEnd) {
                const double span = (double)(slot->loopEnd - slot->loopStart);
                /* Subtract rather than `fmod`: the overshoot is at most one
                   frame's increment, so this is one iteration in practice and
                   avoids a library call in the inner loop. `span > 0` is
                   guaranteed at note-on, which is what stops this spinning. */
                while (slot->position >= (double)slot->loopEnd) {
                    slot->position -= span;
                }
            } else if (slot->position >= (double)slot->playEnd) {
                slot->inUse = 0;
                break;
            }

            const float source = sample_interpolate(waveform, slot->position);
            monoOut[frame] += source * slot->envelope * slot->levelGain;

            slot->position += slot->increment;

            if (sample_voice_step_envelope(slot)) {
                slot->inUse = 0;
                break;
            }
        }
    }

    for (int32_t frame = 0; frame < frameCount; frame++) {
        monoOut[frame] = sample_flush(sample_limit(sample_finite(monoOut[frame])));
    }

    state->frameCounter += frameCount;

    const int32_t peak = atomic_load_explicit(&state->peakSlots, memory_order_relaxed);
    if (sounding > peak) {
        atomic_store_explicit(&state->peakSlots, sounding, memory_order_relaxed);
    }
}

#pragma mark - Telemetry

int64_t sample_voice_stolen_slots(const SampleVoiceState *state) {
    if (state == NULL) { return 0; }
    return atomic_load_explicit(&state->stolenSlots, memory_order_relaxed);
}

int64_t sample_voice_unmapped_notes(const SampleVoiceState *state) {
    if (state == NULL) { return 0; }
    return atomic_load_explicit(&state->unmappedNotes, memory_order_relaxed);
}

int32_t sample_voice_peak_slots(const SampleVoiceState *state) {
    if (state == NULL) { return 0; }
    return atomic_load_explicit(&state->peakSlots, memory_order_relaxed);
}
