/*
 SynthAudioSetup.c — control-thread construction and teardown.

 Split out from `SynthAudioCore.c` for one reason: this file is allowed to
 allocate and that one is not. Keeping the boundary at a file boundary is what
 makes the real-time-safety guard in `RealtimeSafetyTests` a mechanical check
 on a whole file rather than a judgement call about which function runs where.

 Nothing here may be called while the engine is rendering. Loading a program is
 the one control-thread operation that publishes non-scalar state to the render
 thread, and the caller (`PlaybackEngine`) stops the AVAudioEngine first — the
 render thread's teardown and restart is the synchronisation edge.
 */

#include "SynthAudioCoreInternal.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>

static int32_t synth_tables_ready = 0;

void synth_audio_core_prepare_tables(void) {
    if (synth_tables_ready) { return; }
    for (int32_t i = 0; i < SYNTH_SINE_TABLE_SIZE; i++) {
        synth_sine_table[i] = (float)sin(2.0 * M_PI * (double)i / (double)SYNTH_SINE_TABLE_SIZE);
    }
    synth_tables_ready = 1;
}

SynthRenderEngine *synth_engine_create(int32_t lineCount,
                                       int32_t maximumFrameCount,
                                       double sampleRate) {
    if (lineCount < 0 || maximumFrameCount <= 0 || sampleRate <= 0.0) { return NULL; }

    synth_audio_core_prepare_tables();

    SynthRenderEngine *engine = (SynthRenderEngine *)calloc(1, sizeof(SynthRenderEngine));
    if (engine == NULL) { return NULL; }

    engine->lineCount = lineCount;
    engine->maximumFrameCount = maximumFrameCount;
    engine->sampleRate = sampleRate;

    if (lineCount > 0) {
        engine->lines = (SynthRenderLine *)calloc((size_t)lineCount, sizeof(SynthRenderLine));
        if (engine->lines == NULL) { free(engine); return NULL; }
    }

    engine->scratchMono = (float *)calloc((size_t)maximumFrameCount, sizeof(float));
    if (engine->scratchMono == NULL) {
        free(engine->lines);
        free(engine);
        return NULL;
    }

    for (int32_t l = 0; l < lineCount; l++) {
        atomic_store_explicit(&engine->lines[l].gain, 1.0f, memory_order_relaxed);
        atomic_store_explicit(&engine->lines[l].pan, 0.0f, memory_order_relaxed);
        atomic_store_explicit(&engine->lines[l].muted, 0, memory_order_relaxed);
        atomic_store_explicit(&engine->lines[l].soloed, 0, memory_order_relaxed);
    }

    atomic_store_explicit(&engine->masterGain, 1.0f, memory_order_relaxed);
    atomic_store_explicit(&engine->transportCommand, SynthTransportStopped, memory_order_relaxed);
    atomic_store_explicit(&engine->transportState, SynthTransportStopped, memory_order_relaxed);
    atomic_store_explicit(&engine->pauseReason, SynthPauseReasonNone, memory_order_relaxed);
    atomic_store_explicit(&engine->realtimeMode, 1, memory_order_relaxed);
    atomic_store_explicit(&engine->seekRequestFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&engine->seekGeneration, 0, memory_order_relaxed);
    atomic_store_explicit(&engine->appliedSeekGeneration, 0, memory_order_relaxed);

    engine->declickGain = 0.0f;
    engine->declickTarget = 0.0f;
    engine->declickStep = (float)(1.0 / (SYNTH_DECLICK_SECONDS * sampleRate));

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    engine->timebaseScale = (double)timebase.numer / (double)timebase.denom;

    return engine;
}

void synth_engine_destroy(SynthRenderEngine *engine) {
    if (engine == NULL) { return; }
    for (int32_t l = 0; l < engine->lineCount; l++) {
        free(engine->lines[l].events);
        free(engine->lines[l].pedalSpans);
    }
    free(engine->lines);
    free(engine->scratchMono);
    free(engine);
}

int32_t synth_engine_reserve_line(SynthRenderEngine *engine,
                                  int32_t lineIndex,
                                  int32_t eventCount,
                                  int32_t pedalSpanCount) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return 0; }
    if (eventCount < 0 || pedalSpanCount < 0) { return 0; }

    SynthRenderLine *line = &engine->lines[lineIndex];

    free(line->events);
    line->events = NULL;
    line->eventCount = 0;
    free(line->pedalSpans);
    line->pedalSpans = NULL;
    line->pedalSpanCount = 0;

    if (eventCount > 0) {
        line->events = (SynthRenderEvent *)calloc((size_t)eventCount, sizeof(SynthRenderEvent));
        if (line->events == NULL) { return 0; }
    }
    if (pedalSpanCount > 0) {
        line->pedalSpans =
            (SynthRenderPedalSpan *)calloc((size_t)pedalSpanCount, sizeof(SynthRenderPedalSpan));
        if (line->pedalSpans == NULL) {
            free(line->events);
            line->events = NULL;
            return 0;
        }
    }

    line->eventCount = eventCount;
    line->pedalSpanCount = pedalSpanCount;
    line->nextEventIndex = 0;
    line->nextPedalIndex = 0;
    line->pedalDown = 0;
    line->activeCount = 0;
    return 1;
}

void synth_engine_set_event(SynthRenderEngine *engine,
                            int32_t lineIndex,
                            int32_t eventIndex,
                            int64_t onsetFrame,
                            int64_t endFrame,
                            int32_t midiNoteNumber,
                            int32_t velocity) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return; }
    SynthRenderLine *line = &engine->lines[lineIndex];
    if (eventIndex < 0 || eventIndex >= line->eventCount) { return; }

    /* A zero-length note would be scheduled on and off in the same frame and
       never sound. The timeline can legitimately contain one after a very
       short ornament division rounds down, so give it a single frame. */
    if (endFrame <= onsetFrame) { endFrame = onsetFrame + 1; }

    line->events[eventIndex].onsetFrame = onsetFrame;
    line->events[eventIndex].endFrame = endFrame;
    line->events[eventIndex].midiNoteNumber = midiNoteNumber;
    line->events[eventIndex].velocity = velocity;
}

void synth_engine_set_pedal_span(SynthRenderEngine *engine,
                                 int32_t lineIndex,
                                 int32_t spanIndex,
                                 int64_t startFrame,
                                 int64_t endFrame) {
    if (engine == NULL || lineIndex < 0 || lineIndex >= engine->lineCount) { return; }
    SynthRenderLine *line = &engine->lines[lineIndex];
    if (spanIndex < 0 || spanIndex >= line->pedalSpanCount) { return; }
    line->pedalSpans[spanIndex].startFrame = startFrame;
    line->pedalSpans[spanIndex].endFrame = endFrame;
}

void synth_engine_set_line_voice(SynthRenderEngine *engine,
                                 int32_t lineIndex,
                                 const SynthLineVoice *voice) {
    if (engine == NULL || voice == NULL) { return; }
    if (lineIndex < 0 || lineIndex >= engine->lineCount) { return; }
    memcpy(&engine->lines[lineIndex].voice, voice, sizeof(SynthLineVoice));
    if (voice->prepare) { voice->prepare(voice->state, engine->sampleRate); }
}

void synth_engine_set_total_frames(SynthRenderEngine *engine, int64_t totalFrames) {
    if (engine == NULL) { return; }
    engine->totalFrames = totalFrames < 0 ? 0 : totalFrames;
}

void synth_engine_set_sample_rate(SynthRenderEngine *engine, double sampleRate) {
    if (engine == NULL || sampleRate <= 0.0) { return; }
    engine->sampleRate = sampleRate;
    engine->declickStep = (float)(1.0 / (SYNTH_DECLICK_SECONDS * sampleRate));
    for (int32_t l = 0; l < engine->lineCount; l++) {
        const SynthLineVoice *voice = &engine->lines[l].voice;
        if (voice->prepare) { voice->prepare(voice->state, sampleRate); }
    }
}
