/*
 SynthAudioCoreInternal.h — layout shared by the render core and its setup.

 Private on purpose. `SynthAudioCore.h` keeps every one of these types opaque
 so that Swift cannot reach past the accessors, and so that the `_Atomic`
 fields below (which the Swift clang importer cannot represent) never appear in
 a header Swift parses.
 */

#ifndef SYNTH_AUDIO_CORE_INTERNAL_H
#define SYNTH_AUDIO_CORE_INTERNAL_H

#include "SynthAudioCore.h"
#include <stdatomic.h>

/// Notes one line may sound at once before the scheduler steals the slot that
/// ends soonest. Fixed so that every buffer is sized at creation.
#define SYNTH_MAX_POLYPHONY 32

/// Sine table length. A power of two so the index wrap is a mask.
#define SYNTH_SINE_TABLE_SIZE 4096
#define SYNTH_SINE_TABLE_MASK (SYNTH_SINE_TABLE_SIZE - 1)

/// Partials the built-in voice sums. Cheap, fixed, and enough to sound like an
/// instrument rather than a test tone.
#define SYNTH_DEFAULT_VOICE_PARTIALS 3

/// Fade applied across any transport discontinuity, in seconds. Long enough to
/// remove the step, short enough that a seek feels immediate.
#define SYNTH_DECLICK_SECONDS 0.004

/// Consecutive over-deadline blocks before the engine gives up and pauses
/// cleanly. At a 512-frame buffer and 48 kHz this is a little over a fifth of
/// a second of sustained overload — long enough not to fire on one scheduling
/// hiccup, short enough to beat the listener to the conclusion.
#define SYNTH_OVERLOAD_PAUSE_BLOCKS 20

/// Fraction of a block's real-time deadline that counts as an overload.
#define SYNTH_OVERLOAD_DEADLINE_FRACTION 0.85

#pragma mark - Built-in default voice

typedef enum {
    SynthEnvelopeIdle    = 0,
    SynthEnvelopeAttack  = 1,
    SynthEnvelopeDecay   = 2,
    SynthEnvelopeSustain = 3,
    SynthEnvelopeRelease = 4
} SynthEnvelopeStage;

typedef struct {
    int32_t midiNoteNumber;
    int32_t stage;
    /// Note has been released but the sustain pedal is holding it.
    int32_t heldByPedal;
    /// Monotonic counter, so stealing picks a defined victim.
    int64_t age;
    /// Table phase in table units, kept in double so a long note does not
    /// accumulate audible drift.
    double  phase[SYNTH_DEFAULT_VOICE_PARTIALS];
    double  phaseIncrement[SYNTH_DEFAULT_VOICE_PARTIALS];
    float   amplitude;
    float   envelope;
} SynthDefaultVoiceSlot;

struct SynthDefaultVoiceState {
    double  sampleRate;
    int32_t sustainPedalDown;
    int64_t ageCounter;

    /// Per-sample linear envelope deltas, recomputed whenever the rate changes.
    float attackDelta;
    float decayDelta;
    float releaseDelta;
    float sustainLevel;

    SynthDefaultVoiceSlot slots[SYNTH_MAX_POLYPHONY];
};

#pragma mark - Program

typedef struct {
    int64_t onsetFrame;
    int64_t endFrame;
    int32_t midiNoteNumber;
    int32_t velocity;
} SynthRenderEvent;

typedef struct {
    int64_t startFrame;
    int64_t endFrame;
} SynthRenderPedalSpan;

typedef struct {
    SynthRenderEvent     *events;
    int32_t               eventCount;
    SynthRenderPedalSpan *pedalSpans;
    int32_t               pedalSpanCount;

    SynthLineVoice voice;

    /* Control thread writes, render thread reads. Each is one naturally
       aligned word; an update that lands a buffer late is inaudible. */
    _Atomic float   gain;
    _Atomic float   pan;
    _Atomic int32_t muted;
    _Atomic int32_t soloed;

    /* Render thread only. */
    int32_t nextEventIndex;
    int32_t nextPedalIndex;
    int32_t pedalDown;
    int32_t activeCount;
    int64_t activeEndFrame[SYNTH_MAX_POLYPHONY];
    int32_t activeNote[SYNTH_MAX_POLYPHONY];
} SynthRenderLine;

#pragma mark - Engine

struct SynthRenderEngine {
    SynthRenderLine *lines;
    int32_t          lineCount;

    /// One line's mono output for one sub-block.
    float   *scratchMono;
    int32_t  maximumFrameCount;

    double  sampleRate;
    int64_t totalFrames;

    /* Control thread writes, render thread reads — except `transportCommand`,
       which the render thread also writes in two places: the end-of-piece latch
       and the overload watchdog, both of which retire a stale play command so
       the engine does not immediately restart itself. Those writes are
       same-thread and relaxed; the control thread's are release stores that
       publish `requestedPauseReason` written just before them. */
    _Atomic int32_t  transportCommand;
    _Atomic int64_t  seekRequestFrame;
    _Atomic uint64_t seekGeneration;
    _Atomic int32_t  realtimeMode;
    _Atomic float    masterGain;
    _Atomic int32_t  requestedPauseReason;

    /* Render thread writes, control thread reads. */
    _Atomic int64_t  playheadFrame;
    _Atomic int32_t  transportState;
    _Atomic int32_t  pauseReason;
    _Atomic int64_t  renderedBlocks;
    _Atomic int64_t  overloadBlocks;
    _Atomic int64_t  overloadPauses;
    _Atomic uint64_t appliedSeekGeneration;
    _Atomic float    peakLevel;

    /* Render thread only. */
    int64_t cursorFrame;
    float   declickGain;
    float   declickTarget;
    float   declickStep;
    /// Set when a discontinuity is waiting for the fade-out to finish.
    int32_t pendingDiscontinuity;
    int64_t pendingSeekFrame;
    int32_t pendingTransportState;
    int32_t pendingPauseReason;
    uint64_t pendingSeekGeneration;
    int32_t consecutiveOverloads;
    /// mach_absolute_time units to nanoseconds.
    double  timebaseScale;
};

/// Shared sine table, filled once on the control thread by
/// `synth_audio_core_prepare_tables`. Read-only from the render thread.
extern float synth_sine_table[SYNTH_SINE_TABLE_SIZE];

void synth_audio_core_prepare_tables(void);

/// Recompute the envelope deltas for the current sample rate.
void synth_default_voice_update_rate(SynthDefaultVoiceState *state, double sampleRate);

#endif /* SYNTH_AUDIO_CORE_INTERNAL_H */
