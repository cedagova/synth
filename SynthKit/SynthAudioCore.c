/*
 SynthAudioCore.c — everything the render thread executes, and nothing else.

 THIS FILE MUST NOT ALLOCATE, LOCK, OR CALL INTO THE OBJECTIVE-C RUNTIME.
 `RealtimeSafetyTests.testRenderCoreContainsNoRealtimeUnsafeCall` reads this
 file and fails if a name from its forbidden list appears. Construction and
 teardown live in `SynthAudioSetup.c`, which is allowed to malloc precisely
 because it never runs while audio is playing.

 The only functions here that are not called from the render thread are the
 scalar accessors at the bottom. They are single atomic operations, so they are
 safe from either side and are kept beside the state they touch.
 */

#include "SynthAudioCoreInternal.h"
#include <math.h>
#include <mach/mach_time.h>

#pragma mark - Small helpers

static inline float synth_clampf(float value, float low, float high) {
    return value < low ? low : (value > high ? high : value);
}

static inline int64_t synth_min64(int64_t a, int64_t b) { return a < b ? a : b; }

/// Flush denormals, which are how a reverb tail quietly turns into a CPU spike.
static inline float synth_room_flush(float value) {
    return (value < 1.0e-25f && value > -1.0e-25f) ? 0.0f : value;
}

/// Replace a non-finite sample with silence before it enters a feedback loop.
///
/// A NaN in a comb filter is permanent: it feeds back into itself and every
/// line's reverb is silent from then on. The lines themselves already sanitise
/// their own output, so this is the second lock on the one path in the mixer
/// with memory.
static inline float synth_room_finite(float value) {
    return (value == value && value * 0.0f == 0.0f) ? value : 0.0f;
}

/*
 One channel of the hall, one frame.

 Freeverb: eight damped comb filters in parallel into four allpasses in series.
 The same topology as the per-patch reverb in `SynthPatchEngine.c`, with two
 differences that follow from this being a shared bus rather than an insert —
 there is no dry path (the caller adds the return to the dry mix itself) and no
 pre-delay (a hall the whole orchestra shares wants its first reflection at the
 same moment for every line, which is what a common bus already gives).
 */
static inline float synth_room_step(SynthRoomState *room, int32_t channel, float input) {
    /* Input scaled by (1 - feedback) so the eight combs sum to roughly unity
       whatever the decay length; otherwise a longer hall would simply be louder
       rather than longer. */
    const float driven = synth_room_finite(input) * 0.12f * (1.0f - SYNTH_ROOM_FEEDBACK);

    float summed = 0.0f;
    for (int32_t index = 0; index < SYNTH_ROOM_COMB_COUNT; index++) {
        const int32_t cursor = room->combIndex[channel][index];
        const float tap = room->comb[channel][index][cursor];
        room->combStore[channel][index] = synth_room_flush(
            tap + (room->combStore[channel][index] - tap) * SYNTH_ROOM_DAMPING);
        room->comb[channel][index][cursor] = synth_room_flush(
            synth_room_finite(driven + room->combStore[channel][index] * SYNTH_ROOM_FEEDBACK));
        room->combIndex[channel][index] = cursor + 1 >= room->combLength[channel][index]
            ? 0 : cursor + 1;
        summed += tap;
    }

    float wet = summed;
    for (int32_t index = 0; index < SYNTH_ROOM_ALLPASS_COUNT; index++) {
        const int32_t cursor = room->allpassIndex[channel][index];
        const float tap = room->allpass[channel][index][cursor];
        const float output = tap - wet;
        room->allpass[channel][index][cursor] = synth_room_flush(
            synth_room_finite(wet + tap * 0.5f));
        room->allpassIndex[channel][index] = cursor + 1 >= room->allpassLength[channel][index]
            ? 0 : cursor + 1;
        wet = output;
    }

    return wet;
}

/// Clear the hall without resizing it. Render thread, on a faded-out buffer.
///
/// A seek that left the previous passage ringing in the room would put audio
/// from before the jump on top of the audio after it, which is exactly the
/// discontinuity the declick fade exists to remove.
static void synth_room_silence(SynthRoomState *room) {
    if (room == NULL) { return; }
    for (int32_t channel = 0; channel < 2; channel++) {
        for (int32_t index = 0; index < SYNTH_ROOM_COMB_COUNT; index++) {
            for (int32_t frame = 0; frame < room->combLength[channel][index]; frame++) {
                room->comb[channel][index][frame] = 0.0f;
            }
            room->combStore[channel][index] = 0.0f;
            room->combIndex[channel][index] = 0;
        }
        for (int32_t index = 0; index < SYNTH_ROOM_ALLPASS_COUNT; index++) {
            for (int32_t frame = 0; frame < room->allpassLength[channel][index]; frame++) {
                room->allpass[channel][index][frame] = 0.0f;
            }
            room->allpassIndex[channel][index] = 0;
        }
    }
}

#pragma mark - The produced master

/*
 The master stage, one frame at a time. Layout, constants and the reason the
 ceiling looks ahead are in `SynthAudioCoreInternal.h`.

 Everything below is per *sample* rather than per buffer, and every piece of
 state it needs lives in the engine. That is what makes the stage independent of
 the host's buffer size, which `OfflineRenderTests.testTheRenderIsIndependent‐
 OfTheHostBufferSize` asserts by rendering the same program in 64-frame and
 4096-frame blocks and comparing bytes.
*/

/// Which program frame the engine is currently *emitting*, as opposed to
/// rendering into the ceiling's lookahead.
///
/// The one place the two cursors are reconciled. Everything owner-visible — the
/// playhead, where a pause resumes from, when the piece has ended — is a
/// statement about the frame being heard, and `cursorFrame` runs a lookahead
/// ahead of that from the moment the stage is primed.
static inline int64_t synth_output_frame(const SynthRenderEngine *engine) {
    const int64_t frame = engine->cursorFrame - (int64_t)engine->masterLookaheadFilled;
    return frame < 0 ? 0 : frame;
}

/// Hold the ceiling's target for one frame of the lookahead down to `target`.
///
/// Only ever downwards, because several passes contribute: the frame's own
/// sample peak, and then the interpolated peaks of the two intervals it sits
/// between. The counter is what lets the steady state skip the window scan.
static inline void synth_master_hold(SynthRenderEngine *engine,
                                     int32_t index,
                                     float target) {
    if (target < engine->masterTarget[index]) {
        if (engine->masterTarget[index] >= 1.0f) { engine->masterNonUnity++; }
        engine->masterTarget[index] = target;
    }
}

/*
 Third-order Lagrange weights for the three quarter-points between two samples,
 over a stencil centred on them.

 This is the inter-sample part of "true peak". A ceiling that only looked at
 samples would let a signal whose every sample sits at −1.1 dBFS reconstruct
 above −1 dBFS on the way out of a converter, and REQ-005 is a claim about that
 reconstruction rather than about the stored numbers. Four taps rather than the
 dozen a metering standard uses because this is a control signal for a limiter
 that then measures its own result: the cost is three multiply-adds a sample and
 the residual error is an order of magnitude below the ceiling itself.
*/
static const float synth_master_interpolation[3][4] = {
    /* ¼ */ { -0.0546875f, 0.8203125f, 0.2734375f, -0.0390625f },
    /* ½ */ { -0.0625f,    0.5625f,    0.5625f,    -0.0625f    },
    /* ¾ */ { -0.0390625f, 0.2734375f, 0.8203125f, -0.0546875f }
};

/// Look between the two frames behind `write` — the newest interval whose
/// right-hand stencil tap has arrived — and hold both of them down far enough
/// that nothing reconstructs above the ceiling.
static inline void synth_master_interval_peak(SynthRenderEngine *engine, int32_t write) {
    const int32_t mask = SYNTH_MASTER_LOOKAHEAD_FRAMES - 1;
    const int32_t base = write + SYNTH_MASTER_LOOKAHEAD_FRAMES - 3;

    for (int32_t point = 0; point < 3; point++) {
        float left = 0.0f;
        float right = 0.0f;
        for (int32_t tap = 0; tap < 4; tap++) {
            const float weight = synth_master_interpolation[point][tap];
            const int32_t index = (base + tap) & mask;
            left += weight * engine->masterDelayLeft[index];
            right += weight * engine->masterDelayRight[index];
        }
        float peak = fabsf(left);
        const float other = fabsf(right);
        if (other > peak) { peak = other; }
        if (peak > SYNTH_MASTER_CEILING) {
            const float target = (SYNTH_MASTER_CEILING * SYNTH_MASTER_SAFETY) / peak;
            synth_master_hold(engine, (base + 1) & mask, target);
            synth_master_hold(engine, (base + 2) & mask, target);
        }
    }
}

/// Push one frame into the ceiling's lookahead and take the frame that falls
/// out of the far end, scaled so it cannot exceed the ceiling.
///
/// The gain is the smallest thing the window asks for, with each frame's demand
/// eased in over the distance still to run: a reduction wanted `j` frames from
/// now pulls the gain `j`-th of the way there, so what the emitted frame sees is
/// a linear ramp that arrives exactly on the peak instead of a step. Coming back
/// up is rate-limited instead, because a ceiling that snapped back to unity the
/// frame after a peak would be audible on every one.
static inline void synth_master_step(SynthRenderEngine *engine,
                                     float inLeft,
                                     float inRight,
                                     float *outLeft,
                                     float *outRight) {
    const int32_t mask = SYNTH_MASTER_LOOKAHEAD_FRAMES - 1;
    const int32_t write = engine->masterWrite;

    /* The frame leaving the lookahead and the target that belongs to it, both
       read before the slot is reused. */
    const float emitLeft = engine->masterDelayLeft[write];
    const float emitRight = engine->masterDelayRight[write];
    float wanted = engine->masterTarget[write];

    if (engine->masterTarget[write] < 1.0f) { engine->masterNonUnity--; }
    engine->masterDelayLeft[write] = inLeft;
    engine->masterDelayRight[write] = inRight;
    engine->masterTarget[write] = 1.0f;

    float peak = fabsf(inLeft);
    const float other = fabsf(inRight);
    if (other > peak) { peak = other; }
    if (peak > SYNTH_MASTER_CEILING) {
        synth_master_hold(engine, write,
                          (SYNTH_MASTER_CEILING * SYNTH_MASTER_SAFETY) / peak);
    }
    synth_master_interval_peak(engine, write);

    if (engine->masterNonUnity > 0) {
        const float scale = 1.0f / (float)SYNTH_MASTER_LOOKAHEAD_FRAMES;
        int32_t index = (write + 1) & mask;
        for (int32_t ahead = 1; ahead <= SYNTH_MASTER_LOOKAHEAD_FRAMES; ahead++) {
            const float target = engine->masterTarget[index];
            if (target < 1.0f) {
                const float eased = target + (1.0f - target) * ((float)ahead * scale);
                if (eased < wanted) { wanted = eased; }
            }
            index = (index + 1) & mask;
        }
    }

    engine->masterWrite = (write + 1) & mask;

    float gain = engine->masterGainState;
    if (wanted < gain) {
        gain = wanted;
    } else {
        gain += engine->masterReleaseStep;
        if (gain > wanted) { gain = wanted; }
    }
    engine->masterGainState = gain;

    /* Unity is exactly `1.0f` here, never nearly, so a mix that never
       approaches the ceiling leaves through this multiply unchanged. */
    *outLeft = emitLeft * gain;
    *outRight = emitRight * gain;
}

/// One frame through bus cohesion: a slow, gentle compressor over the whole mix.
static inline void synth_master_cohesion(SynthRenderEngine *engine,
                                         float *left,
                                         float *right,
                                         float threshold) {
    float magnitude = fabsf(*left);
    const float other = fabsf(*right);
    if (other > magnitude) { magnitude = other; }

    const float coefficient = magnitude > engine->cohesionEnvelope
        ? engine->cohesionAttackCoefficient
        : engine->cohesionReleaseCoefficient;
    float envelope = engine->cohesionEnvelope
        + coefficient * (magnitude - engine->cohesionEnvelope);
    envelope = synth_room_flush(envelope);
    engine->cohesionEnvelope = envelope;

    if (envelope > threshold) {
        const float gain =
            expf(SYNTH_MASTER_COHESION_EXPONENT * logf(threshold / envelope));
        *left *= gain;
        *right *= gain;
    }
}

/// Forget everything the master stage was holding, and arrange for the
/// lookahead to be filled again before the next frame is emitted.
///
/// Called at every relocate, while the output is already faded out, for the
/// reason the room is silenced there: state carried across a jump is audio from
/// before it arriving after the fade is over.
static inline void synth_master_silence(SynthRenderEngine *engine) {
    for (int32_t frame = 0; frame < SYNTH_MASTER_LOOKAHEAD_FRAMES; frame++) {
        engine->masterDelayLeft[frame] = 0.0f;
        engine->masterDelayRight[frame] = 0.0f;
        engine->masterTarget[frame] = 1.0f;
    }
    engine->masterWrite = 0;
    engine->masterNonUnity = 0;
    engine->masterGainState = 1.0f;
    engine->cohesionEnvelope = 0.0f;
    engine->masterLookaheadFilled = 0;
    engine->masterNeedsPrime = 1;
}

#pragma mark - Scheduler

/// Put every line back to its state at `frame`: cursors rewound, voices
/// silenced, pedal state recomputed. Called only while the mix is faded out.
static void synth_engine_relocate(SynthRenderEngine *engine, int64_t frame) {
    /* The hall goes with the playhead. A seek that left the previous passage
       ringing would lay audio from before the jump over the audio after it —
       the one discontinuity the declick fade cannot hide, because it arrives
       after the fade is over. */
    synth_room_silence(engine->room);
    engine->roomTailFrames = 0;

    /* And so does the master stage's lookahead, for the same reason, plus one
       of its own: the lookahead is refilled from the new position before
       anything is emitted, which is what keeps the emitted frame and the
       program frame the same number across a jump. */
    synth_master_silence(engine);

    for (int32_t l = 0; l < engine->lineCount; l++) {
        SynthRenderLine *line = &engine->lines[l];

        line->activeCount = 0;
        line->depthLowpassState = 0.0f;
        if (line->voice.reset) { line->voice.reset(line->voice.state); }

        /* Linear scan rather than a binary search: this runs once per seek, on
           a faded-out buffer, and a straight walk cannot get the boundary
           condition subtly wrong. */
        int32_t eventIndex = 0;
        while (eventIndex < line->eventCount
               && line->events[eventIndex].onsetFrame < frame) {
            eventIndex++;
        }
        line->nextEventIndex = eventIndex;

        int32_t pedalIndex = 0;
        int32_t down = 0;
        while (pedalIndex < line->pedalSpanCount
               && line->pedalSpans[pedalIndex].startFrame <= frame) {
            if (line->pedalSpans[pedalIndex].endFrame > frame) { down = 1; }
            pedalIndex++;
        }
        /* Step back onto a span that is still open so its end is not missed. */
        if (down && pedalIndex > 0) { pedalIndex--; }
        line->nextPedalIndex = pedalIndex;
        line->pedalDown = down;
        if (line->voice.setSustainPedal) {
            line->voice.setSustainPedal(line->voice.state, down);
        }
    }
    engine->cursorFrame = frame;
}

/* Depth cue tuning. At depth 1 the line loses SYNTH_DEPTH_ATTENUATION of its
   direct level, its air-absorption lowpass falls from inaudible to
   SYNTH_DEPTH_FAR_CUTOFF_HZ, and up to SYNTH_DEPTH_ROOM_LEAN of extra send
   reaches the shared room. Constants in one place so staging taste is tuned
   here and nowhere else. */
#define SYNTH_DEPTH_ATTENUATION 0.45f
#define SYNTH_DEPTH_NEAR_CUTOFF_HZ 18000.0f
#define SYNTH_DEPTH_FAR_CUTOFF_HZ 3200.0f
#define SYNTH_DEPTH_ROOM_LEAN 0.4f

/*
 Render one line across `frameCount` frames starting at `blockStart`, splitting
 at every note-on, note-off and pedal edge so the voice never sees a call that
 straddles an event. This is what makes scheduling sample-accurate, and it is
 also why the rendered output does not depend on the host's buffer size — a
 property the offline tests assert directly.
 */
static void synth_render_line(SynthRenderEngine *engine,
                              SynthRenderLine *line,
                              int64_t blockStart,
                              int32_t frameCount,
                              float gainLeft,
                              float gainRight,
                              float roomGain,
                              float depthLowpassCoefficient,
                              float *outLeft,
                              float *outRight,
                              float *roomOut) {
    int32_t offset = 0;

    while (offset < frameCount) {
        const int64_t now = blockStart + offset;

        /* Apply every transition that falls exactly on `now`. */
        while (line->nextEventIndex < line->eventCount
               && line->events[line->nextEventIndex].onsetFrame <= now) {
            const SynthRenderEvent *event = &line->events[line->nextEventIndex];

            if (line->activeCount >= SYNTH_MAX_POLYPHONY) {
                /* Steal the slot that ends soonest so the scheduler's table
                   never overflows. The voice makes its own stealing decision;
                   this only keeps the note-off bookkeeping bounded. */
                int32_t victim = 0;
                for (int32_t i = 1; i < line->activeCount; i++) {
                    if (line->activeEndFrame[i] < line->activeEndFrame[victim]) { victim = i; }
                }
                if (line->voice.noteOff) {
                    line->voice.noteOff(line->voice.state, line->activeNote[victim]);
                }
                line->activeEndFrame[victim] = line->activeEndFrame[line->activeCount - 1];
                line->activeNote[victim] = line->activeNote[line->activeCount - 1];
                line->activeCount--;
            }

            if (line->voice.noteOn) {
                line->voice.noteOn(line->voice.state, event->midiNoteNumber, event->velocity);
            }
            line->activeEndFrame[line->activeCount] = event->endFrame;
            line->activeNote[line->activeCount] = event->midiNoteNumber;
            line->activeCount++;
            line->nextEventIndex++;
        }

        for (int32_t i = 0; i < line->activeCount; ) {
            if (line->activeEndFrame[i] <= now) {
                if (line->voice.noteOff) {
                    line->voice.noteOff(line->voice.state, line->activeNote[i]);
                }
                line->activeEndFrame[i] = line->activeEndFrame[line->activeCount - 1];
                line->activeNote[i] = line->activeNote[line->activeCount - 1];
                line->activeCount--;
            } else {
                i++;
            }
        }

        while (line->nextPedalIndex < line->pedalSpanCount) {
            const SynthRenderPedalSpan *span = &line->pedalSpans[line->nextPedalIndex];
            if (!line->pedalDown && span->startFrame <= now && span->endFrame > now) {
                line->pedalDown = 1;
                if (line->voice.setSustainPedal) {
                    line->voice.setSustainPedal(line->voice.state, 1);
                }
                break;
            }
            if (span->endFrame <= now) {
                if (line->pedalDown) {
                    line->pedalDown = 0;
                    if (line->voice.setSustainPedal) {
                        line->voice.setSustainPedal(line->voice.state, 0);
                    }
                }
                line->nextPedalIndex++;
                continue;
            }
            break;
        }

        /* How far can we render before the next transition? */
        int64_t boundary = blockStart + frameCount;
        if (line->nextEventIndex < line->eventCount) {
            boundary = synth_min64(boundary, line->events[line->nextEventIndex].onsetFrame);
        }
        for (int32_t i = 0; i < line->activeCount; i++) {
            boundary = synth_min64(boundary, line->activeEndFrame[i]);
        }
        if (line->nextPedalIndex < line->pedalSpanCount) {
            const SynthRenderPedalSpan *span = &line->pedalSpans[line->nextPedalIndex];
            boundary = synth_min64(boundary, line->pedalDown ? span->endFrame : span->startFrame);
        }

        int32_t chunk = (int32_t)(boundary - now);
        if (chunk <= 0) { chunk = 1; }
        if (offset + chunk > frameCount) { chunk = frameCount - offset; }

        if (line->voice.render) {
            line->voice.render(line->voice.state, engine->scratchMono, chunk);
            /* Air absorption for a line placed at depth: a one-pole lowpass
               over the voice output, ahead of both the dry mix and the room
               send, so distance darkens the line everywhere it is heard.
               Skipped entirely at depth zero, which keeps the front of the
               stage bit-identical to rendering before depth existed. */
            if (depthLowpassCoefficient < 1.0f) {
                float state = line->depthLowpassState;
                for (int32_t f = 0; f < chunk; f++) {
                    /* Flushed per sample, the room's own convention: a flush
                       at chunk boundaries would zero the decaying state at a
                       frame that depends on the host buffer size, and the
                       byte-identity across block sizes is the acceptance. */
                    state = synth_room_flush(
                        state + depthLowpassCoefficient * (engine->scratchMono[f] - state));
                    engine->scratchMono[f] = state;
                }
                line->depthLowpassState = state;
            }
            for (int32_t f = 0; f < chunk; f++) {
                const float sample = engine->scratchMono[f];
                outLeft[offset + f]  += sample * gainLeft;
                outRight[offset + f] += sample * gainRight;
            }
            /* The room send is post-fader and post-mute: a line the owner
               silenced is silent in the hall too, and pulling a fader down
               takes its reverb with it. Sending pre-fader would leave a muted
               line audible as its own reverb, which is the surprising answer.
               `roomGain` is already zero when the line is muted or unsoloed,
               so the guard below is the send itself. */
            if (roomGain > 0.0f) {
                for (int32_t f = 0; f < chunk; f++) {
                    roomOut[offset + f] += engine->scratchMono[f] * roomGain;
                }
            }
        }

        offset += chunk;
    }
}

#pragma mark - The summed bus

/*
 Every line, the shared room, and nothing after them: `count` frames of the raw
 sum, written over whatever was in `spanLeft`/`spanRight`.

 Extracted from the render entry point so the master stage can prime its
 lookahead with real program instead of silence — `synth_master_prime` below is
 the only other caller, and it wants exactly this and none of the transport,
 declick or ceiling work that surrounds it.
*/
static void synth_render_bus(SynthRenderEngine *engine,
                             int32_t count,
                             float *spanLeft,
                             float *spanRight,
                             int32_t anySolo,
                             int32_t anyRoomSend,
                             int32_t anySend) {
    const int32_t separate = (spanRight != spanLeft);
    for (int32_t f = 0; f < count; f++) { spanLeft[f] = 0.0f; }
    if (separate) {
        for (int32_t f = 0; f < count; f++) { spanRight[f] = 0.0f; }
    }
    if (anyRoomSend) {
        for (int32_t f = 0; f < count; f++) { engine->scratchRoom[f] = 0.0f; }
    }

    for (int32_t l = 0; l < engine->lineCount; l++) {
        SynthRenderLine *line = &engine->lines[l];

        float gain = atomic_load_explicit(&line->gain, memory_order_relaxed);
        const int32_t muted = atomic_load_explicit(&line->muted, memory_order_relaxed);
        const int32_t soloed = atomic_load_explicit(&line->soloed, memory_order_relaxed);
        if (muted || (anySolo && !soloed)) { gain = 0.0f; }

        /* Equal-power pan: -1 maps to 0 radians, +1 to a quarter turn, so a
           centred line sits at -3 dB in both channels and total power stays
           constant as it moves. */
        const float pan = atomic_load_explicit(&line->pan, memory_order_relaxed);
        const float theta = (pan + 1.0f) * 0.25f * (float)M_PI;

        /* Depth: distance attenuates the direct sound, air absorption darkens
           it (the lowpass below), and the line leans further into the shared
           room. At zero every factor is exactly unity and the lowpass is
           bypassed, so the front of the stage is the pre-depth engine, bit for
           bit. */
        const float depth = atomic_load_explicit(&line->depth, memory_order_relaxed);
        const float distanceGain = 1.0f - SYNTH_DEPTH_ATTENUATION * depth;
        float depthLowpassCoefficient = 1.0f;
        if (depth > 0.0f) {
            const float cutoff = SYNTH_DEPTH_NEAR_CUTOFF_HZ
                - depth * (SYNTH_DEPTH_NEAR_CUTOFF_HZ - SYNTH_DEPTH_FAR_CUTOFF_HZ);
            depthLowpassCoefficient =
                1.0f - expf(-2.0f * (float)M_PI * cutoff / (float)engine->sampleRate);
            if (depthLowpassCoefficient > 1.0f) { depthLowpassCoefficient = 1.0f; }
        } else {
            /* Depth just returned to the front: clear the filter so a later
               raise starts from silence, not a stale sample. */
            line->depthLowpassState = 0.0f;
        }

        const float gainLeft = cosf(theta) * gain * distanceGain;
        const float gainRight = sinf(theta) * gain * distanceGain;

        float send = anyRoomSend
            ? atomic_load_explicit(&line->roomSend, memory_order_relaxed)
            : 0.0f;
        if (anyRoomSend && depth > 0.0f) {
            send += SYNTH_DEPTH_ROOM_LEAN * depth * (1.0f - send);
        }

        synth_render_line(engine, line,
                          engine->cursorFrame, count,
                          gainLeft, gainRight, send * gain,
                          depthLowpassCoefficient,
                          spanLeft, spanRight,
                          engine->scratchRoom);
    }

    /* The hall, once, over everything that was sent to it. Added to the dry mix
       before the master stage and the declick, so a fade takes the reverb with
       it rather than leaving a tail hanging over a silenced transport. */
    if (anyRoomSend) {
        for (int32_t f = 0; f < count; f++) {
            const float input = engine->scratchRoom[f];
            const float left = synth_room_step(engine->room, 0, input);
            const float right = separate
                ? synth_room_step(engine->room, 1, input)
                : left;
            spanLeft[f] += left * SYNTH_ROOM_RETURN_GAIN;
            if (separate) { spanRight[f] += right * SYNTH_ROOM_RETURN_GAIN; }
        }
    }

    if (anyRoomSend && !anySend) {
        engine->roomTailFrames -= count;
        if (engine->roomTailFrames < 0) { engine->roomTailFrames = 0; }
    }

    engine->cursorFrame += count;
}

/*
 Fill the ceiling's lookahead before the first frame is emitted.

 This is what makes the lookahead free of consequence. The alternative — letting
 the delay line start full of silence — would push everything the engine ever
 plays a lookahead later than the program says, so a seek would land 1.3 ms
 short, an export would lose the end of its own release tail, and every test
 that checks where a note sounds would be measuring the delay instead. Instead
 the stage renders the first lookahead's worth of program into the delay line
 and emits nothing, so the frame it hands out is the frame the program asked
 for.

 Control of the level is deliberately identical to the emitting path — the same
 cohesion, calibration and master gain — because these frames are emitted, one
 lookahead later, and a different gain here would be a step in the output.
*/
static void synth_master_prime(SynthRenderEngine *engine,
                               int32_t anySolo,
                               int32_t anyRoomSend,
                               int32_t anySend,
                               int32_t producedMaster,
                               float calibration,
                               float cohesionThreshold,
                               float master) {
    int32_t filled = 0;
    while (filled < SYNTH_MASTER_LOOKAHEAD_FRAMES) {
        int32_t count = SYNTH_MASTER_LOOKAHEAD_FRAMES - filled;
        if (count > engine->maximumFrameCount) { count = engine->maximumFrameCount; }

        synth_render_bus(engine, count,
                         engine->primeLeft, engine->primeRight,
                         anySolo, anyRoomSend, anySend);

        for (int32_t f = 0; f < count; f++) {
            float left = engine->primeLeft[f];
            float right = engine->primeRight[f];
            if (producedMaster) {
                if (cohesionThreshold > 0.0f) {
                    synth_master_cohesion(engine, &left, &right, cohesionThreshold);
                }
                left *= calibration;
                right *= calibration;
            }
            left *= master;
            right *= master;
            float discardedLeft = 0.0f;
            float discardedRight = 0.0f;
            synth_master_step(engine, left, right, &discardedLeft, &discardedRight);
            (void)discardedLeft;
            (void)discardedRight;
        }
        filled += count;
    }
    engine->masterLookaheadFilled = SYNTH_MASTER_LOOKAHEAD_FRAMES;
    engine->masterNeedsPrime = 0;
}

#pragma mark - Render entry point

int32_t synth_audio_core_render(SynthRenderEngine *engine,
                                AudioBufferList *bufferList,
                                int32_t frameCount,
                                int32_t *isSilence) {
    const uint64_t startTicks = mach_absolute_time();

    if (engine == NULL || bufferList == NULL || frameCount <= 0) {
        if (isSilence) { *isSilence = 1; }
        return 0;
    }
    if (frameCount > engine->maximumFrameCount) {
        /* The graph asked for more than was reserved. Silence is the only safe
           answer: rendering would write past the scratch buffer. */
        for (UInt32 b = 0; b < bufferList->mNumberBuffers; b++) {
            float *data = (float *)bufferList->mBuffers[b].mData;
            if (data == NULL) { continue; }
            const int32_t capacity = (int32_t)(bufferList->mBuffers[b].mDataByteSize / sizeof(float));
            for (int32_t f = 0; f < capacity; f++) { data[f] = 0.0f; }
        }
        if (isSilence) { *isSilence = 1; }
        return 0;
    }

    /* Resolve the output pointers. Deinterleaved stereo is the format the
       engine connects with; a mono destination gets the left channel. */
    float *outLeft = NULL;
    float *outRight = NULL;
    if (bufferList->mNumberBuffers >= 2) {
        outLeft = (float *)bufferList->mBuffers[0].mData;
        outRight = (float *)bufferList->mBuffers[1].mData;
    } else if (bufferList->mNumberBuffers == 1) {
        outLeft = (float *)bufferList->mBuffers[0].mData;
        outRight = outLeft;
    }
    if (outLeft == NULL || outRight == NULL) {
        if (isSilence) { *isSilence = 1; }
        return 0;
    }

    for (int32_t f = 0; f < frameCount; f++) { outLeft[f] = 0.0f; }
    if (outRight != outLeft) {
        for (int32_t f = 0; f < frameCount; f++) { outRight[f] = 0.0f; }
    }

    /* --- Fold in whatever the control thread asked for since last time --- */

    /*
     A command and a seek can arrive in the same gap between two buffers, so
     they are resolved together rather than one overriding the other: the
     command decides the state to end up in, the seek decides the frame. Doing
     it the other way round is how "seek, then press play" ends up playing from
     the beginning.

     Nothing new is taken on board while a discontinuity is still fading; it is
     picked up on the block after that one lands, which is a few milliseconds
     later and inaudible.
    */
    /* Acquire, to pair with the release store in the transport setters. The
       pause reason is written before the command and read after it, so the
       reason the render thread sees is always the one that belongs to the
       command it acted on. Relaxed on both sides would let arm64 pair a new
       command with the previous reason — a one-buffer window that no test can
       reproduce, and that would report a device loss as an ordinary pause. */
    const int32_t command = atomic_load_explicit(&engine->transportCommand, memory_order_acquire);
    int32_t currentState = atomic_load_explicit(&engine->transportState, memory_order_relaxed);

    if (!engine->pendingDiscontinuity) {
        const uint64_t wantedSeek =
            atomic_load_explicit(&engine->seekGeneration, memory_order_acquire);
        const int32_t hasSeek =
            wantedSeek != atomic_load_explicit(&engine->appliedSeekGeneration, memory_order_relaxed);

        int32_t wantsDiscontinuity = 0;
        /* Every target below is a frame the listener is at, so it is the
           emitted frame rather than the program cursor the ceiling's lookahead
           runs ahead of. Resuming from the cursor would silently skip the
           lookahead's worth of music that had been rendered but not heard. */
        int64_t targetFrame = synth_output_frame(engine);
        int32_t targetState = currentState;
        int32_t targetReason =
            atomic_load_explicit(&engine->pauseReason, memory_order_relaxed);

        if (command != currentState) {
            if (command == SynthTransportStopped) {
                wantsDiscontinuity = 1;
                targetFrame = 0;
                targetState = SynthTransportStopped;
                targetReason = SynthPauseReasonNone;
            } else if (command == SynthTransportPaused) {
                wantsDiscontinuity = 1;
                targetFrame = synth_output_frame(engine);
                targetState = SynthTransportPaused;
                targetReason =
                    atomic_load_explicit(&engine->requestedPauseReason, memory_order_relaxed);
            } else if (command == SynthTransportPlaying) {
                targetState = SynthTransportPlaying;
                targetReason = SynthPauseReasonNone;
                /* Playing on from the end means starting again. Without this,
                   pressing play after a piece finishes would sit silently at
                   the last frame, which is never what was meant. */
                if (engine->totalFrames > 0
                    && synth_output_frame(engine) >= engine->totalFrames && !hasSeek) {
                    wantsDiscontinuity = 1;
                    targetFrame = 0;
                }
            }
        }

        if (hasSeek) {
            wantsDiscontinuity = 1;
            targetFrame = atomic_load_explicit(&engine->seekRequestFrame, memory_order_relaxed);
            engine->pendingSeekGeneration = wantedSeek;
        }

        if (wantsDiscontinuity) {
            engine->pendingDiscontinuity = 1;
            engine->pendingSeekFrame = targetFrame;
            engine->pendingTransportState = targetState;
            engine->pendingPauseReason = targetReason;
            engine->declickTarget = 0.0f;
        } else if (targetState != currentState) {
            /* Starting from a standstill is not a discontinuity: there is
               nothing to fade out of, and the fade-in alone removes the step. */
            currentState = targetState;
            atomic_store_explicit(&engine->transportState, targetState, memory_order_relaxed);
            atomic_store_explicit(&engine->pauseReason, targetReason, memory_order_relaxed);
        }
    }

    if (currentState == SynthTransportPlaying && !engine->pendingDiscontinuity) {
        engine->declickTarget = 1.0f;
    }

    /* --- Which lines are audible this block --- */

    int32_t anySolo = 0;
    for (int32_t l = 0; l < engine->lineCount; l++) {
        if (atomic_load_explicit(&engine->lines[l].soloed, memory_order_relaxed)) { anySolo = 1; break; }
    }

    /* --- Is the room in use at all this block? --- */

    /* The whole bus is skipped when nothing is sent to it, which is every mix
       until the owner turns a send up. That is what keeps D7's room send from
       costing REQ-013's budget anything by merely existing.

       The hall goes on being rendered for its own tail after the last send
       reaches zero, though: stopping the moment the control passes zero would
       cut a ringing room off with a step, and it would do it exactly while the
       owner had hold of the fader. */
    int32_t anySend = 0;
    for (int32_t l = 0; l < engine->lineCount; l++) {
        /* A nonzero depth leans the line into the room even with its explicit
           send at zero — far away in a room the listener cannot hear would be
           a contradiction — so it engages the bus the same way a send does. */
        if (atomic_load_explicit(&engine->lines[l].roomSend, memory_order_relaxed) > 0.0f
            || atomic_load_explicit(&engine->lines[l].depth, memory_order_relaxed) > 0.0f) {
            anySend = 1;
            break;
        }
    }
    if (anySend) {
        engine->roomTailFrames = (int64_t)(SYNTH_ROOM_TAIL_SECONDS * engine->sampleRate);
    }
    const int32_t anyRoomSend = anySend || engine->roomTailFrames > 0;

    /* --- Render, stopping at the fade-out point if one is pending --- */

    int32_t offset = 0;
    while (offset < frameCount) {
        int32_t chunk = frameCount - offset;

        /* If a discontinuity is waiting, only render as far as the fade needs. */
        if (engine->pendingDiscontinuity) {
            const float distance = engine->declickGain;
            if (distance <= 0.0f) {
                /* Fade complete: apply the jump. */
                synth_engine_relocate(engine, engine->pendingSeekFrame);
                atomic_store_explicit(&engine->transportState,
                                      engine->pendingTransportState, memory_order_relaxed);
                atomic_store_explicit(&engine->pauseReason,
                                      engine->pendingPauseReason, memory_order_relaxed);
                atomic_store_explicit(&engine->appliedSeekGeneration,
                                      engine->pendingSeekGeneration, memory_order_release);
                atomic_store_explicit(&engine->playheadFrame,
                                      synth_output_frame(engine), memory_order_relaxed);
                engine->pendingDiscontinuity = 0;
                engine->consecutiveOverloads = 0;
                currentState = atomic_load_explicit(&engine->transportState, memory_order_relaxed);
                engine->declickTarget =
                    (currentState == SynthTransportPlaying) ? 1.0f : 0.0f;
                continue;
            }
            const int32_t framesToSilence =
                (int32_t)ceilf(distance / (engine->declickStep > 0.0f ? engine->declickStep : 1.0f));
            if (framesToSilence < chunk) { chunk = framesToSilence > 0 ? framesToSilence : 1; }
        }

        const int32_t rendering =
            (atomic_load_explicit(&engine->transportState, memory_order_relaxed) == SynthTransportPlaying);

        /* On a mono destination both channel pointers are the same buffer, so
           scaling "both" would square the gain — a wrong declick curve and a
           wrong level. Unreachable today, because the graph always connects
           stereo, but a defensive path that is silently wrong is worse than
           none. */
        const int32_t separateChannels = (outRight != outLeft);

        /* The owner's master gain and the produced master's two figures, read
           once for the span. All three only move while the engine is stopped —
           they are program state, not a live control — so reading them per span
           rather than per frame cannot make the render depend on how the host
           chopped up time. */
        const float master = atomic_load_explicit(&engine->masterGain, memory_order_relaxed);
        const int32_t producedMaster =
            atomic_load_explicit(&engine->producedMaster, memory_order_relaxed);
        const float calibration = producedMaster
            ? atomic_load_explicit(&engine->calibrationGain, memory_order_relaxed)
            : 1.0f;
        const float cohesionThreshold = producedMaster
            ? atomic_load_explicit(&engine->cohesionThreshold, memory_order_relaxed)
            : 0.0f;
        if (producedMaster != engine->cohesionWasEnabled) {
            /* Turning the setting on must not inherit whatever level the
               follower was left holding when it was turned off. */
            engine->cohesionEnvelope = 0.0f;
            engine->cohesionWasEnabled = producedMaster;
        }

        if (rendering) {
            if (engine->masterNeedsPrime) {
                synth_master_prime(engine, anySolo, anyRoomSend, anySend,
                                   producedMaster, calibration, cohesionThreshold, master);
            }

            synth_render_bus(engine, chunk,
                             outLeft + offset, outRight + offset,
                             anySolo, anyRoomSend, anySend);

            /* The master stage, in the order the header states: cohesion, the
               calibration gain, the owner's master gain, then the ceiling. The
               master gain goes *inside* the ceiling deliberately — a bus pushed
               above the ceiling by a gain the ceiling could not see would make
               REQ-005's "in every state" untrue. */
            for (int32_t f = 0; f < chunk; f++) {
                float left = outLeft[offset + f];
                float right = separateChannels ? outRight[offset + f] : left;

                if (producedMaster) {
                    if (cohesionThreshold > 0.0f) {
                        synth_master_cohesion(engine, &left, &right, cohesionThreshold);
                    }
                    left *= calibration;
                    right *= calibration;
                }
                left *= master;
                right *= master;

                float emitLeft = 0.0f;
                float emitRight = 0.0f;
                synth_master_step(engine, left, right, &emitLeft, &emitRight);
                outLeft[offset + f] = emitLeft;
                if (separateChannels) { outRight[offset + f] = emitRight; }
            }
        }

        /* Declick last, over the same span.
           **After the master stage rather than before it**, for two reasons
           that pull the same way: a fade has to take the ceiling's output with
           it, and clearing the lookahead at a jump has to happen while the
           output is already at zero — which it is only if the fade is applied
           on this side of the delay line. Multiplying the finished mix also
           keeps per-line mixing exactly linear, which is what lets the mute and
           solo tests assert bit equality rather than a tolerance. */
        float declick = engine->declickGain;
        const float target = engine->declickTarget;
        const float step = engine->declickStep;
        for (int32_t f = 0; f < chunk; f++) {
            if (declick < target) {
                declick += step;
                if (declick > target) { declick = target; }
            } else if (declick > target) {
                declick -= step;
                if (declick < target) { declick = target; }
            }
            outLeft[offset + f] *= declick;
            if (separateChannels) { outRight[offset + f] *= declick; }
        }
        engine->declickGain = declick;

        offset += chunk;

        /* The end of the piece is a statement about the frame being *heard*, so
           it is the emitted frame that is compared, not the program cursor the
           ceiling's lookahead runs ahead of. */
        if (rendering && engine->totalFrames > 0
            && synth_output_frame(engine) >= engine->totalFrames
            && !engine->pendingDiscontinuity) {
            engine->pendingDiscontinuity = 1;
            engine->pendingSeekFrame = engine->totalFrames;
            engine->pendingTransportState = SynthTransportPaused;
            engine->pendingPauseReason = SynthPauseReasonReachedEnd;
            engine->declickTarget = 0.0f;
            /* Retire the play command as well. Leaving it set would make the
               next block see "commanded to play, currently paused" and start
               the piece over — the engine would refuse to stay finished. */
            atomic_store_explicit(&engine->transportCommand, SynthTransportPaused, memory_order_relaxed);
        }
    }

    atomic_store_explicit(&engine->playheadFrame, synth_output_frame(engine), memory_order_relaxed);

    /* --- Peak, for headroom claims --- */

    float peak = atomic_load_explicit(&engine->peakLevel, memory_order_relaxed);
    for (int32_t f = 0; f < frameCount; f++) {
        const float a = fabsf(outLeft[f]);
        const float b = fabsf(outRight[f]);
        if (a > peak) { peak = a; }
        if (b > peak) { peak = b; }
    }
    atomic_store_explicit(&engine->peakLevel, peak, memory_order_relaxed);

    if (isSilence) {
        *isSilence = (atomic_load_explicit(&engine->transportState, memory_order_relaxed)
                      != SynthTransportPlaying && engine->declickGain <= 0.0f) ? 1 : 0;
    }

    atomic_fetch_add_explicit(&engine->renderedBlocks, 1, memory_order_relaxed);

    /* --- Overload watchdog --- */

    if (atomic_load_explicit(&engine->realtimeMode, memory_order_relaxed)) {
        const uint64_t elapsedTicks = mach_absolute_time() - startTicks;
        const double elapsedNanos = (double)elapsedTicks * engine->timebaseScale;
        const double deadlineNanos = ((double)frameCount / engine->sampleRate) * 1.0e9;
        if (elapsedNanos > deadlineNanos * SYNTH_OVERLOAD_DEADLINE_FRACTION) {
            atomic_fetch_add_explicit(&engine->overloadBlocks, 1, memory_order_relaxed);
            engine->consecutiveOverloads++;
            if (engine->consecutiveOverloads >= SYNTH_OVERLOAD_PAUSE_BLOCKS
                && !engine->pendingDiscontinuity
                && atomic_load_explicit(&engine->transportState, memory_order_relaxed)
                    == SynthTransportPlaying) {
                /* Give up cleanly rather than keep missing deadlines: fade out,
                   pause, keep the playhead. Corrupted audio is the one outcome
                   this must never produce. */
                engine->pendingDiscontinuity = 1;
                engine->pendingSeekFrame = synth_output_frame(engine);
                engine->pendingTransportState = SynthTransportPaused;
                engine->pendingPauseReason = SynthPauseReasonOverload;
                engine->declickTarget = 0.0f;
                atomic_store_explicit(&engine->transportCommand, SynthTransportPaused, memory_order_relaxed);
                atomic_fetch_add_explicit(&engine->overloadPauses, 1, memory_order_relaxed);
                engine->consecutiveOverloads = 0;
            }
        } else {
            engine->consecutiveOverloads = 0;
        }
    }

    return 0;
}

#pragma mark - Accessors

void synth_engine_set_line_gain(SynthRenderEngine *engine, int32_t lineIndex, float gain) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return; }
    atomic_store_explicit(&engine->lines[lineIndex].gain,
                          synth_clampf(gain, 0.0f, 8.0f), memory_order_relaxed);
}

void synth_engine_set_line_pan(SynthRenderEngine *engine, int32_t lineIndex, float pan) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return; }
    atomic_store_explicit(&engine->lines[lineIndex].pan,
                          synth_clampf(pan, -1.0f, 1.0f), memory_order_relaxed);
}

void synth_engine_set_line_muted(SynthRenderEngine *engine, int32_t lineIndex, int32_t muted) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return; }
    atomic_store_explicit(&engine->lines[lineIndex].muted, muted ? 1 : 0, memory_order_relaxed);
}

void synth_engine_set_line_soloed(SynthRenderEngine *engine, int32_t lineIndex, int32_t soloed) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return; }
    atomic_store_explicit(&engine->lines[lineIndex].soloed, soloed ? 1 : 0, memory_order_relaxed);
}

float synth_engine_line_gain(const SynthRenderEngine *engine, int32_t lineIndex) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return 0.0f; }
    return atomic_load_explicit(&engine->lines[lineIndex].gain, memory_order_relaxed);
}

float synth_engine_line_pan(const SynthRenderEngine *engine, int32_t lineIndex) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return 0.0f; }
    return atomic_load_explicit(&engine->lines[lineIndex].pan, memory_order_relaxed);
}

int32_t synth_engine_line_muted(const SynthRenderEngine *engine, int32_t lineIndex) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return 0; }
    return atomic_load_explicit(&engine->lines[lineIndex].muted, memory_order_relaxed);
}

void synth_engine_set_line_room_send(SynthRenderEngine *engine, int32_t lineIndex, float send) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return; }
    atomic_store_explicit(&engine->lines[lineIndex].roomSend,
                          synth_clampf(send, 0.0f, 1.0f), memory_order_relaxed);
}

float synth_engine_line_room_send(const SynthRenderEngine *engine, int32_t lineIndex) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return 0.0f; }
    return atomic_load_explicit(&engine->lines[lineIndex].roomSend, memory_order_relaxed);
}

void synth_engine_set_line_depth(SynthRenderEngine *engine, int32_t lineIndex, float depth) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return; }
    atomic_store_explicit(&engine->lines[lineIndex].depth,
                          synth_clampf(depth, 0.0f, 1.0f), memory_order_relaxed);
}

float synth_engine_line_depth(const SynthRenderEngine *engine, int32_t lineIndex) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return 0.0f; }
    return atomic_load_explicit(&engine->lines[lineIndex].depth, memory_order_relaxed);
}

int32_t synth_engine_line_soloed(const SynthRenderEngine *engine, int32_t lineIndex) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return 0; }
    return atomic_load_explicit(&engine->lines[lineIndex].soloed, memory_order_relaxed);
}

void synth_engine_set_master_gain(SynthRenderEngine *engine, float gain) {
    if (engine == NULL) { return; }
    atomic_store_explicit(&engine->masterGain, synth_clampf(gain, 0.0f, 8.0f), memory_order_relaxed);
}

void synth_engine_set_produced_master(SynthRenderEngine *engine, int32_t enabled) {
    if (engine == NULL) { return; }
    atomic_store_explicit(&engine->producedMaster, enabled ? 1 : 0, memory_order_relaxed);
}

int32_t synth_engine_produced_master(const SynthRenderEngine *engine) {
    if (engine == NULL) { return 0; }
    return atomic_load_explicit(&engine->producedMaster, memory_order_relaxed);
}

void synth_engine_set_master_calibration(SynthRenderEngine *engine,
                                         float gain,
                                         float cohesionThreshold) {
    if (engine == NULL) { return; }
    /* Clamped at the same 0…8 the owner's master gain is, and both values are
       checked for NaN rather than only clamped: the analysis that produces them
       already bounds them, but `synth_clampf` passes a NaN straight through —
       and a NaN multiplied into the bus is silence for the rest of the piece.
       A second bound here means a future caller cannot do that. */
    const float bounded = (gain == gain) ? synth_clampf(gain, 0.0f, 8.0f) : 1.0f;
    atomic_store_explicit(&engine->calibrationGain, bounded, memory_order_relaxed);
    const float threshold = (cohesionThreshold > 0.0f && cohesionThreshold == cohesionThreshold)
        ? cohesionThreshold : 0.0f;
    atomic_store_explicit(&engine->cohesionThreshold, threshold, memory_order_relaxed);
}

float synth_engine_master_calibration_gain(const SynthRenderEngine *engine) {
    if (engine == NULL) { return 1.0f; }
    return atomic_load_explicit(&engine->calibrationGain, memory_order_relaxed);
}

float synth_engine_master_cohesion_threshold(const SynthRenderEngine *engine) {
    if (engine == NULL) { return 0.0f; }
    return atomic_load_explicit(&engine->cohesionThreshold, memory_order_relaxed);
}

float synth_master_ceiling(void) { return SYNTH_MASTER_CEILING; }

int32_t synth_master_lookahead_frames(void) { return SYNTH_MASTER_LOOKAHEAD_FRAMES; }

float synth_engine_master_gain(const SynthRenderEngine *engine) {
    if (engine == NULL) { return 0.0f; }
    return atomic_load_explicit(&engine->masterGain, memory_order_relaxed);
}

void synth_engine_play(SynthRenderEngine *engine) {
    if (engine == NULL) { return; }
    atomic_store_explicit(&engine->requestedPauseReason, SynthPauseReasonNone, memory_order_relaxed);
    atomic_store_explicit(&engine->transportCommand, SynthTransportPlaying, memory_order_release);
}

void synth_engine_pause(SynthRenderEngine *engine) {
    if (engine == NULL) { return; }
    atomic_store_explicit(&engine->requestedPauseReason, SynthPauseReasonNone, memory_order_relaxed);
    atomic_store_explicit(&engine->transportCommand, SynthTransportPaused, memory_order_release);
}

void synth_engine_pause_for_device_loss(SynthRenderEngine *engine) {
    if (engine == NULL) { return; }
    atomic_store_explicit(&engine->requestedPauseReason, SynthPauseReasonDeviceLost, memory_order_relaxed);
    atomic_store_explicit(&engine->transportCommand, SynthTransportPaused, memory_order_release);
}

void synth_engine_stop(SynthRenderEngine *engine) {
    if (engine == NULL) { return; }
    atomic_store_explicit(&engine->requestedPauseReason, SynthPauseReasonNone, memory_order_relaxed);
    atomic_store_explicit(&engine->transportCommand, SynthTransportStopped, memory_order_release);
}

void synth_engine_seek(SynthRenderEngine *engine, int64_t frame) {
    if (engine == NULL) { return; }
    if (frame < 0) { frame = 0; }
    atomic_store_explicit(&engine->seekRequestFrame, frame, memory_order_relaxed);
    atomic_fetch_add_explicit(&engine->seekGeneration, 1, memory_order_release);
}

int32_t synth_engine_seek_settled(const SynthRenderEngine *engine) {
    if (engine == NULL) { return 1; }
    return atomic_load_explicit(&engine->seekGeneration, memory_order_acquire)
        == atomic_load_explicit(&engine->appliedSeekGeneration, memory_order_acquire);
}

int64_t synth_engine_playhead_frame(const SynthRenderEngine *engine) {
    if (engine == NULL) { return 0; }
    return atomic_load_explicit(&engine->playheadFrame, memory_order_relaxed);
}

int32_t synth_engine_transport_state(const SynthRenderEngine *engine) {
    if (engine == NULL) { return SynthTransportStopped; }
    return atomic_load_explicit(&engine->transportState, memory_order_relaxed);
}

int32_t synth_engine_pause_reason(const SynthRenderEngine *engine) {
    if (engine == NULL) { return SynthPauseReasonNone; }
    return atomic_load_explicit(&engine->pauseReason, memory_order_relaxed);
}

int64_t synth_engine_rendered_blocks(const SynthRenderEngine *engine) {
    if (engine == NULL) { return 0; }
    return atomic_load_explicit(&engine->renderedBlocks, memory_order_relaxed);
}

int64_t synth_engine_overload_blocks(const SynthRenderEngine *engine) {
    if (engine == NULL) { return 0; }
    return atomic_load_explicit(&engine->overloadBlocks, memory_order_relaxed);
}

int64_t synth_engine_overload_pauses(const SynthRenderEngine *engine) {
    if (engine == NULL) { return 0; }
    return atomic_load_explicit(&engine->overloadPauses, memory_order_relaxed);
}

float synth_engine_peak_level(const SynthRenderEngine *engine) {
    if (engine == NULL) { return 0.0f; }
    return atomic_load_explicit(&engine->peakLevel, memory_order_relaxed);
}

void synth_engine_reset_telemetry(SynthRenderEngine *engine) {
    if (engine == NULL) { return; }
    atomic_store_explicit(&engine->renderedBlocks, 0, memory_order_relaxed);
    atomic_store_explicit(&engine->overloadBlocks, 0, memory_order_relaxed);
    atomic_store_explicit(&engine->overloadPauses, 0, memory_order_relaxed);
    atomic_store_explicit(&engine->peakLevel, 0.0f, memory_order_relaxed);
}

void synth_engine_set_realtime_mode(SynthRenderEngine *engine, int32_t isRealtime) {
    if (engine == NULL) { return; }
    atomic_store_explicit(&engine->realtimeMode, isRealtime ? 1 : 0, memory_order_relaxed);
}
