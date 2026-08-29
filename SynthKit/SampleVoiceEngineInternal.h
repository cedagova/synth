/*
 SampleVoiceEngineInternal.h — the layout `SampleVoiceEngine.c` renders and
 `SampleVoiceSetup.c` builds.

 Private for the same two reasons the engine's own state is: Swift's clang
 importer cannot represent the `_Atomic` telemetry fields, and keeping the
 layout here means a caller cannot reach past the vtable into a voice that is
 rendering.
 */

#ifndef SAMPLE_VOICE_ENGINE_INTERNAL_H
#define SAMPLE_VOICE_ENGINE_INTERNAL_H

#include <stdatomic.h>
#include <stdint.h>

#include "SampleVoiceEngine.h"

/// Low shelf corner, in hertz. Body and weight, below the fundamental of most
/// orchestral writing so it moves the instrument's weight rather than its tune.
#define SAMPLE_TONE_LOW_HERTZ 250.0

/// High shelf corner, in hertz. Air, bow noise and hammer attack.
#define SAMPLE_TONE_HIGH_HERTZ 4000.0

#pragma mark - Envelope stages

enum {
    SampleEnvelopeStageAttack  = 0,
    SampleEnvelopeStageDecay   = 1,
    SampleEnvelopeStageSustain = 2,
    SampleEnvelopeStageRelease = 3
};

#pragma mark - Slot

/*
 One sounding sample player.

 A note-on normally starts one of these; a velocity-layered instrument still
 starts one, because layers are selected by `lovel`/`hivel` rather than
 stacked. A note-off can start more, for a library whose release triggers are
 separate regions.
 */
typedef struct SampleVoiceSlot {
    int32_t inUse;

    /// Index into the instrument's region table.
    int32_t regionIndex;

    /// The key that started this slot. Release triggers carry the key of the
    /// note that ended, so they are not stopped by a later note-off on it.
    int32_t key;

    /// 1 when this slot came from a `trigger=release` region.
    int32_t isReleaseTrigger;

    /// Fractional read position, in frames of the source waveform.
    double position;

    /// Frames of source per frame of output: rate conversion and pitch in one
    /// number.
    double increment;

    /// Everything about the note's loudness that does not change while it
    /// sounds: velocity tracking, `volume`, and a release trigger's `rt_decay`.
    float levelGain;

    /// Current amplitude-envelope value, 0…1.
    float envelope;

    /// A `SampleEnvelopeStage*`.
    int32_t stage;

    /// Attack is linear; decay and release are exponential, so a piano's
    /// release sounds like a damper rather than a fade-out. `decayCoefficient`
    /// and `releaseCoefficient` are per-frame multipliers.
    float attackIncrement;
    float decayCoefficient;
    float sustainLevel;
    float releaseCoefficient;

    /// Resolved once at note-on so the render loop never re-reads the region.
    int64_t loopStart, loopEnd, playEnd;
    int32_t loopMode;

    /// Order of creation, for stealing the oldest slot when every one is busy.
    int64_t startOrder;
} SampleVoiceSlot;

#pragma mark - Voice

struct SampleVoiceState {
    /// The shared, immutable instrument. Owned by the Swift side.
    const SampleInstrumentData *instrument;

    double sampleRate;

    /// Frames rendered since the last `reset`, for `rt_decay`.
    int64_t frameCounter;

    /// Monotonic slot counter, for stealing.
    int64_t startCounter;

    SampleVoiceSlot slots[SAMPLE_VOICE_MAX_SLOTS];

    /// Per-key note state, so note-off, the pedal and release triggers all
    /// know what the key was doing.
    int32_t keyIsDown[SAMPLE_VOICE_KEY_COUNT];
    int32_t keyIsPedalHeld[SAMPLE_VOICE_KEY_COUNT];
    int32_t keyVelocity[SAMPLE_VOICE_KEY_COUNT];
    int64_t keyOnFrame[SAMPLE_VOICE_KEY_COUNT];

    /// Round-robin position per key. `seq_position` is matched against this.
    uint32_t keySequence[SAMPLE_VOICE_KEY_COUNT];

    int32_t pedalIsDown;

    /// The keyswitch currently selected, or -1.
    int32_t currentSwitchKey;

    /// Seeded xorshift state, and the seed it returns to on `reset`.
    uint64_t randomState;
    uint64_t randomSeed;

    /*
     INS003's customization, one relaxed atomic per field.

     Individually atomic rather than double-buffered behind a pointer swap: each
     is one naturally aligned word, so no value can tear, and the only thing a
     split update costs is that two fields of one edit may land a buffer apart.
     `SynthAudioCore.h` already states that contract for gain and pan and calls
     the result inaudible; a shelf gain and a vibrato depth four milliseconds
     out of step with each other is the same size of disagreement.
    */
    _Atomic float customToneLowGain;
    _Atomic float customToneHighGain;
    _Atomic float customDynamicsResponse;
    _Atomic float customAttackSecondsAdded;
    _Atomic float customReleaseScale;
    _Atomic float customVibratoDepthCents;
    _Atomic float customVibratoRateHz;
    _Atomic float customTuningRatio;
    _Atomic int64_t customizationAdoptions;

    _Atomic int64_t stolenSlots;
    _Atomic int64_t unmappedNotes;
    _Atomic int32_t peakSlots;

    /*
     Render thread only: the shelving filters and the vibrato oscillator.

     One pair of one-pole states for the whole voice rather than one per slot.
     Tone is a property of the instrument, so it belongs on the voice's summed
     output — filtering every slot separately would cost 128 filters to produce
     the same answer.
    */
    float toneLowState;
    float toneHighState;
    /// One-pole coefficients for the shelf corners, derived in `prepare`.
    float toneLowCoefficient;
    float toneHighCoefficient;

    /// Vibrato phase in 0…1, advanced once per frame for the whole voice.
    float vibratoPhase;
};

#pragma mark - The vtable's five callbacks

/*
 Defined in `SampleVoiceEngine.c` and wired into a `SynthLineVoice` by
 `SampleVoiceSetup.c`. Declared here rather than in the public header because
 nothing outside those two files may call them: the engine reaches them through
 the vtable, which is the whole point of the interface.
 */
void sample_voice_prepare(void *state, double sampleRate);
void sample_voice_note_on(void *state, int32_t midiNoteNumber, int32_t velocity);
void sample_voice_note_off(void *state, int32_t midiNoteNumber);
void sample_voice_set_sustain_pedal(void *state, int32_t isDown);
void sample_voice_render(void *state, float *monoOut, int32_t frameCount);
void sample_voice_reset(void *state);

/// Fill `outVoice` with the stateless voice that renders silence.
///
/// `sample_voice_create` calls this on every path that returns NULL, so the
/// engine is never handed a vtable of null function pointers. Declared here for
/// the same reason the callbacks are: only the setup file may call it.
void sample_voice_fill_silent(SynthLineVoice *outVoice);

#endif /* SAMPLE_VOICE_ENGINE_INTERNAL_H */
