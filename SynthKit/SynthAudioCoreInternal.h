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

#pragma mark - The room

/*
 One shared room for the whole mix (D7's per-line room send, REQ-021).

 **Shared rather than per line, because that is what a room is.** Every line
 sends into one hall and the hall answers once, which is the sound an orchestra
 makes and also the cheap answer: eighteen private reverbs would be eighteen
 different halls, three orders of magnitude more delay memory, and a mix in
 which nothing shares an acoustic. It lives beside `masterGain` for the same
 reason — it is a property of the mix, not of any one sound.

 Freeverb's mono topology, run twice with the published stereo spread, so the
 hall has a width rather than arriving down the middle. The tunings are the
 published values scaled to the render rate: they are mutually prime lengths
 chosen so the combs do not reinforce each other into a metallic ring, and
 `SynthPatchEngineInternal.h` uses the same ones for the per-patch reverb.

 **It costs nothing until a line sends to it.** `synth_audio_core_render` skips
 the whole bus while every line's send is zero, which is every piece nobody has
 sent to the room — so REQ-013's budget is unchanged for a mix that does not
 use this.
*/
#define SYNTH_ROOM_COMB_COUNT 8
#define SYNTH_ROOM_ALLPASS_COUNT 4
/// Longest comb (1617 frames at 44.1 kHz) scaled to the maximum sample rate,
/// plus the stereo spread.
#define SYNTH_ROOM_COMB_MAX_FRAMES 3648
#define SYNTH_ROOM_ALLPASS_MAX_FRAMES 1280
/// Highest rate the room's delay lines are sized for. Above this the room is
/// slightly smaller than it would otherwise be, which is a far better answer
/// than eight combs saturating to one length and ringing.
#define SYNTH_ROOM_MAX_SAMPLE_RATE 96000.0

/// How much of a line at full send reaches the hall. A send of 1 is "as much
/// as this line's own signal", so the wet return is scaled to sit under the
/// dry rather than swamping it.
#define SYNTH_ROOM_RETURN_GAIN 0.36f

/// Feedback and damping of the fixed hall. Around two seconds of decay at
/// 44.1 kHz, dark enough to sit behind an orchestra rather than in front of it.
#define SYNTH_ROOM_FEEDBACK 0.88f
#define SYNTH_ROOM_DAMPING 0.42f

typedef struct {
    float   comb[2][SYNTH_ROOM_COMB_COUNT][SYNTH_ROOM_COMB_MAX_FRAMES];
    int32_t combIndex[2][SYNTH_ROOM_COMB_COUNT];
    int32_t combLength[2][SYNTH_ROOM_COMB_COUNT];
    float   combStore[2][SYNTH_ROOM_COMB_COUNT];

    float   allpass[2][SYNTH_ROOM_ALLPASS_COUNT][SYNTH_ROOM_ALLPASS_MAX_FRAMES];
    int32_t allpassIndex[2][SYNTH_ROOM_ALLPASS_COUNT];
    int32_t allpassLength[2][SYNTH_ROOM_ALLPASS_COUNT];
} SynthRoomState;

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
    /// How much of this line reaches the shared room, 0…1. Zero for every line
    /// until the owner asks for otherwise (D7).
    _Atomic float   roomSend;

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

    /// Everything every line sent to the room this block, before the hall.
    /// Allocated with the engine, so the render thread never sizes it.
    float   *scratchRoom;

    /// The shared hall. Heap-allocated because it is about a third of a
    /// megabyte and `SynthRenderEngine` is not.
    SynthRoomState *room;

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

#pragma mark - Room construction

/// Size the hall's delay lines for `sampleRate` and clear them.
///
/// Control thread only, and defined in `SynthAudioSetup.c` beside the rest of
/// the construction — the same split that lets `RealtimeSafetyTests` scan the
/// render core as a whole file.
void synth_room_prepare(SynthRoomState *room, double sampleRate);

#endif /* SYNTH_AUDIO_CORE_INTERNAL_H */
