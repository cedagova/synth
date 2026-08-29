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

#pragma mark - Scheduler

/// Put every line back to its state at `frame`: cursors rewound, voices
/// silenced, pedal state recomputed. Called only while the mix is faded out.
static void synth_engine_relocate(SynthRenderEngine *engine, int64_t frame) {
    /* The hall goes with the playhead. A seek that left the previous passage
       ringing would lay audio from before the jump over the audio after it —
       the one discontinuity the declick fade cannot hide, because it arrives
       after the fade is over. */
    synth_room_silence(engine->room);

    for (int32_t l = 0; l < engine->lineCount; l++) {
        SynthRenderLine *line = &engine->lines[l];

        line->activeCount = 0;
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
        int64_t targetFrame = engine->cursorFrame;
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
                targetFrame = engine->cursorFrame;
                targetState = SynthTransportPaused;
                targetReason =
                    atomic_load_explicit(&engine->requestedPauseReason, memory_order_relaxed);
            } else if (command == SynthTransportPlaying) {
                targetState = SynthTransportPlaying;
                targetReason = SynthPauseReasonNone;
                /* Playing on from the end means starting again. Without this,
                   pressing play after a piece finishes would sit silently at
                   the last frame, which is never what was meant. */
                if (engine->totalFrames > 0 && engine->cursorFrame >= engine->totalFrames && !hasSeek) {
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
       costing REQ-013's budget anything by merely existing. */
    int32_t anyRoomSend = 0;
    for (int32_t l = 0; l < engine->lineCount; l++) {
        if (atomic_load_explicit(&engine->lines[l].roomSend, memory_order_relaxed) > 0.0f) {
            anyRoomSend = 1;
            break;
        }
    }

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
                atomic_store_explicit(&engine->playheadFrame, engine->cursorFrame, memory_order_relaxed);
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

        if (rendering) {
            if (anyRoomSend) {
                for (int32_t f = 0; f < chunk; f++) { engine->scratchRoom[f] = 0.0f; }
            }

            for (int32_t l = 0; l < engine->lineCount; l++) {
                SynthRenderLine *line = &engine->lines[l];

                float gain = atomic_load_explicit(&line->gain, memory_order_relaxed);
                const int32_t muted = atomic_load_explicit(&line->muted, memory_order_relaxed);
                const int32_t soloed = atomic_load_explicit(&line->soloed, memory_order_relaxed);
                if (muted || (anySolo && !soloed)) { gain = 0.0f; }

                /* Equal-power pan: -1 maps to 0 radians, +1 to a quarter turn,
                   so a centred line sits at -3 dB in both channels and total
                   power stays constant as it moves. */
                const float pan = atomic_load_explicit(&line->pan, memory_order_relaxed);
                const float theta = (pan + 1.0f) * 0.25f * (float)M_PI;
                const float gainLeft = cosf(theta) * gain;
                const float gainRight = sinf(theta) * gain;

                const float send = anyRoomSend
                    ? atomic_load_explicit(&line->roomSend, memory_order_relaxed)
                    : 0.0f;

                synth_render_line(engine, line,
                                  engine->cursorFrame, chunk,
                                  gainLeft, gainRight, send * gain,
                                  outLeft + offset, outRight + offset,
                                  engine->scratchRoom);
            }

            /* The hall, once, over everything that was sent to it. Added to the
               dry mix before the declick and master gain below, so a fade takes
               the reverb with it rather than leaving a tail hanging over a
               silenced transport. */
            if (anyRoomSend) {
                const int32_t separate = (outRight != outLeft);
                for (int32_t f = 0; f < chunk; f++) {
                    const float input = engine->scratchRoom[f];
                    const float left = synth_room_step(engine->room, 0, input);
                    const float right = separate
                        ? synth_room_step(engine->room, 1, input)
                        : left;
                    outLeft[offset + f] += left * SYNTH_ROOM_RETURN_GAIN;
                    if (separate) { outRight[offset + f] += right * SYNTH_ROOM_RETURN_GAIN; }
                }
            }

            engine->cursorFrame += chunk;
        }

        /* Declick and master gain over the same span. Multiplying the summed
           mix keeps per-line mixing exactly linear, which is what lets the
           mute and solo tests assert bit equality rather than a tolerance. */
        const float master = atomic_load_explicit(&engine->masterGain, memory_order_relaxed);
        /* On a mono destination both channel pointers are the same buffer, so
           scaling "both" would square the gain — a wrong declick curve and a
           wrong level. Unreachable today, because the graph always connects
           stereo, but a defensive path that is silently wrong is worse than
           none. */
        const int32_t separateChannels = (outRight != outLeft);
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
            const float scale = declick * master;
            outLeft[offset + f] *= scale;
            if (separateChannels) { outRight[offset + f] *= scale; }
        }
        engine->declickGain = declick;

        offset += chunk;

        if (rendering && engine->totalFrames > 0 && engine->cursorFrame >= engine->totalFrames
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

    atomic_store_explicit(&engine->playheadFrame, engine->cursorFrame, memory_order_relaxed);

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
                engine->pendingSeekFrame = engine->cursorFrame;
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

int32_t synth_engine_line_soloed(const SynthRenderEngine *engine, int32_t lineIndex) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return 0; }
    return atomic_load_explicit(&engine->lines[lineIndex].soloed, memory_order_relaxed);
}

void synth_engine_set_master_gain(SynthRenderEngine *engine, float gain) {
    if (engine == NULL) { return; }
    atomic_store_explicit(&engine->masterGain, synth_clampf(gain, 0.0f, 8.0f), memory_order_relaxed);
}

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
