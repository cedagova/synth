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

/// How long the hall keeps being rendered after the last send reaches zero, in
/// seconds.
///
/// Long enough to cover the decay above. Without it, pulling the last send down
/// would stop rendering the room mid-tail and cut a ringing hall off with a
/// step — the one audible artefact this bus could introduce, and it would
/// happen precisely while the owner was moving the control.
#define SYNTH_ROOM_TAIL_SECONDS 2.5

typedef struct {
    float   comb[2][SYNTH_ROOM_COMB_COUNT][SYNTH_ROOM_COMB_MAX_FRAMES];
    int32_t combIndex[2][SYNTH_ROOM_COMB_COUNT];
    int32_t combLength[2][SYNTH_ROOM_COMB_COUNT];
    float   combStore[2][SYNTH_ROOM_COMB_COUNT];

    float   allpass[2][SYNTH_ROOM_ALLPASS_COUNT][SYNTH_ROOM_ALLPASS_MAX_FRAMES];
    int32_t allpassIndex[2][SYNTH_ROOM_ALLPASS_COUNT];
    int32_t allpassLength[2][SYNTH_ROOM_ALLPASS_COUNT];
} SynthRoomState;

#pragma mark - The produced master

/*
 The master stage after the line sum (MST001, AD-P2), in the order it runs:
 gentle bus cohesion, the per-piece loudness calibration gain, the owner's
 master gain, and then the always-on true-peak ceiling. The declick fade is
 applied *after* all of it — see `synth_audio_core_render`.

 **Two of the four are switchable and one is not.** Cohesion and calibration
 are the "Produced master" setting (owner decision D65-2, option A); the
 ceiling has no control, because an export that clips is a defect rather than a
 taste (AD-P6). With the setting off, cohesion is skipped and the calibration
 gain is unity, so the stage is the ceiling alone and the ceiling multiplies by
 exactly `1.0f` for any material that stays under it — which is what makes
 REQ-004's composed bypass bit-identical to the raw line sum rather than
 identical-to-a-tolerance.

 **Why the ceiling looks ahead, and why that costs no alignment.** True peak is
 an inter-sample quantity: a signal whose every sample sits under the ceiling
 can still reconstruct above it, so the detector interpolates between samples
 (`synth_master_interval_peak`) and therefore cannot know a peak's height until
 the samples after it have arrived. The signal is delayed by
 `SYNTH_MASTER_LOOKAHEAD_FRAMES` so the reduction can ramp in and land exactly
 on the peak. That delay is then given back: the first lookahead's worth of
 program is rendered into the delay line before any output frame is emitted
 (`synth_master_prime`, re-run after every relocate), so output frame *k* is
 still program frame *k*. `synth_output_frame` is the one place that
 conversion lives.
*/

/// Ceiling in linear amplitude: −1.0 dBFS, the REQ-005 figure.
#define SYNTH_MASTER_CEILING 0.891250938f

/// How far below the ceiling a reduction actually aims, as a linear factor:
/// −0.09 dB.
///
/// The detector's four-tap interpolation is an estimate, and a measurement made
/// with a longer filter reads a few thousandths of a decibel higher — enough to
/// make "true peak ≤ −1 dBFS" false by a rounding error rather than by a defect.
/// This is the allowance for that difference, and it is deliberately applied to
/// the *target* of a reduction and not to the threshold that triggers one, so
/// material under the ceiling is still passed through untouched and bit-exact.
#define SYNTH_MASTER_SAFETY 0.99f

/// Lookahead, in frames, fixed rather than derived from the rate so that a
/// render is bit-identical at 44.1 and 48 kHz for the same reason the event
/// scheduler is: nothing about the stage may depend on how time was chopped up.
/// Must be a power of two — the ring index is masked.
#define SYNTH_MASTER_LOOKAHEAD_FRAMES 64

/// How long the ceiling takes to give a full reduction back, in seconds. Long
/// enough not to pump on a tutti, short enough not to duck the bar after one.
#define SYNTH_MASTER_RELEASE_SECONDS 0.150

/*
 Bus cohesion: one gentle, slow wideband compressor over the whole mix.

 Gentle on purpose. The point is that a tutti and a solo line belong to the same
 record, not that the dynamic range is flattened — so the ratio is barely over
 one, the threshold sits well above the piece's own measured loudness
 (`synth_engine_set_master_calibration` carries it, because where "loud for this
 piece" is can only be known from the analysis pass), and the timing is slower
 than any note.
*/
#define SYNTH_MASTER_COHESION_RATIO 1.4f
/// `1 − 1/ratio`: the exponent that turns an over-threshold ratio into a gain.
#define SYNTH_MASTER_COHESION_EXPONENT 0.285714286f
#define SYNTH_MASTER_COHESION_ATTACK_SECONDS 0.015
#define SYNTH_MASTER_COHESION_RELEASE_SECONDS 0.220

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
    /// How far back in the room this line sits, 0…1. Zero — the front, and
    /// bit-identical to rendering before depth existed — until staging asks
    /// otherwise. Depth darkens and attenuates the line (air absorption and
    /// distance) and leans it into the shared room, so near and far are
    /// audible and not merely quieter.
    _Atomic float   depth;

    /* Render thread only. */
    int32_t nextEventIndex;
    int32_t nextPedalIndex;
    /// One-pole air-absorption state for the depth cue. Continuous across
    /// sub-blocks, so rendering is independent of the host buffer size.
    float   depthLowpassState;
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
    /// The "Produced master" setting (D65-2): cohesion and calibration
    /// together. The ceiling is not behind it.
    _Atomic int32_t  producedMaster;
    /// Per-piece loudness calibration, from the bounded analysis pass
    /// (`MasterCalibration`). Unity for a silent piece and for an analysis that
    /// could not run.
    _Atomic float    calibrationGain;
    /// Where "loud for this piece" is, in linear amplitude, for cohesion.
    /// Zero or less disables cohesion entirely.
    _Atomic float    cohesionThreshold;

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
    /// Frames of hall still to render after the last send reached zero.
    int64_t roomTailFrames;
    /// Set when a discontinuity is waiting for the fade-out to finish.
    int32_t pendingDiscontinuity;
    int64_t pendingSeekFrame;
    int32_t pendingTransportState;
    int32_t pendingPauseReason;
    uint64_t pendingSeekGeneration;
    int32_t consecutiveOverloads;
    /// mach_absolute_time units to nanoseconds.
    double  timebaseScale;

    /* --- The master stage. Render thread only, sized at compile time. --- */

    /// The ceiling's lookahead delay, one ring per channel.
    float   masterDelayLeft[SYNTH_MASTER_LOOKAHEAD_FRAMES];
    float   masterDelayRight[SYNTH_MASTER_LOOKAHEAD_FRAMES];
    /// The gain each delayed frame may not exceed, in step with the rings
    /// above: `1.0f` for a frame that needs nothing, and that exact value is
    /// what keeps the stage bit-transparent.
    float   masterTarget[SYNTH_MASTER_LOOKAHEAD_FRAMES];
    int32_t masterWrite;
    /// How many entries of `masterTarget` are below unity, so the common case —
    /// a mix nowhere near the ceiling — skips the window scan entirely.
    int32_t masterNonUnity;
    /// Frames of program sitting in the delay line: zero until the stage is
    /// primed, `SYNTH_MASTER_LOOKAHEAD_FRAMES` after. The difference between
    /// the program cursor and the frame being emitted.
    int32_t masterLookaheadFilled;
    int32_t masterNeedsPrime;
    /// The reduction currently applied by the ceiling.
    float   masterGainState;
    float   masterReleaseStep;
    /// Bus cohesion's level follower and its rate-derived timing.
    float   cohesionEnvelope;
    float   cohesionAttackCoefficient;
    float   cohesionReleaseCoefficient;
    /// Last produced-master state the render thread saw, so turning the setting
    /// on does not inherit a stale envelope.
    int32_t cohesionWasEnabled;
    /// Where the priming render puts the bus it is not going to emit.
    float   primeLeft[SYNTH_MASTER_LOOKAHEAD_FRAMES];
    float   primeRight[SYNTH_MASTER_LOOKAHEAD_FRAMES];
};

#pragma mark - Room construction

/// Size the hall's delay lines for `sampleRate` and clear them.
///
/// Control thread only, and defined in `SynthAudioSetup.c` beside the rest of
/// the construction — the same split that lets `RealtimeSafetyTests` scan the
/// render core as a whole file.
void synth_room_prepare(SynthRoomState *room, double sampleRate);

#pragma mark - Master stage construction

/// Derive the master stage's rate-dependent timing and clear its state.
///
/// Control thread, beside `synth_room_prepare` and for the same reason: it runs
/// when the engine is built and again on a rate change.
void synth_master_prepare(SynthRenderEngine *engine, double sampleRate);

#endif /* SYNTH_AUDIO_CORE_INTERNAL_H */
