/*
 SynthAudioCore.h — the audio thread's entire public surface.

 Everything the render thread touches lives behind this header, in C, for one
 reason: the render thread may not allocate, take a lock, or send an
 Objective-C message, and C is the only language in this project where that is
 checkable by looking at the file. `SynthAudioCore.c` holds the render path and
 contains no allocation at all; `SynthAudioSetup.c` holds the control-thread
 construction and is the only place that mallocs. `RealtimeSafetyTests` scans
 the first file and fails the build if an allocator, lock, or runtime call
 appears in it.

 Every struct that carries `_Atomic` state is opaque here. That is deliberate
 twice over: Swift's clang importer cannot represent `_Atomic` fields, and
 keeping the layout private means the render state can only be reached through
 the accessors below, each of which performs the correct atomic operation.

 Threading contract, stated once and relied on everywhere:

   - Control thread: create, configure, load a program, destroy. Free to
     allocate and block.
   - Render thread: `synth_audio_core_render` and nothing else.
   - Crossing the boundary while rendering: only the scalar accessors marked
     "control thread, safe while rendering". They are single-word atomics whose
     effect may land one buffer late, which is inaudible and intended.
   - Loading a program is NOT safe while rendering. The caller stops the engine
     first; engine stop/start is the synchronisation edge that publishes the
     program's contents to the render thread.
 */

#ifndef SYNTH_AUDIO_CORE_H
#define SYNTH_AUDIO_CORE_H

#include <stdint.h>
#include <CoreAudioTypes/CoreAudioTypes.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Line voice interface

/*
 The line-voice rendering interface: how one sound renders one line's events.

 This is the surface increment 003's synthesizer (SYN001) implements in
 `SynthPatchEngine.h`, and increment 005's sampled instruments (INS002) will
 implement next. Increment 002 shipped a fixed built-in voice behind it so
 playback was audible before the synth existed; AD7 said increment 003 would
 replace that voice, and it has. The interface itself is unchanged.

 It is a plain vtable of C function pointers rather than a Swift protocol
 because every one of these calls happens on the render thread, where a
 protocol witness lookup on a Swift class would mean ARC traffic and a
 potential allocation.

 Contract for an implementor:

   - `state` is yours. Allocate it, and everything it points to, on the control
     thread before the voice is handed to the engine. None of the callbacks may
     allocate, free, lock, or call into the Objective-C runtime.
   - `render` OVERWRITES `frameCount` mono samples in `monoOut`; it does not
     add to them. The engine owns gain, pan, mute and solo, so a voice must not
     apply its own level.
   - The engine splits every buffer at note and pedal boundaries, so a call to
     `render` never straddles an event. `noteOn`, `noteOff` and
     `setSustainPedal` therefore always land exactly on the frame the timeline
     asked for.
   - `reset` must return the voice to silence immediately. The engine calls it
     on stop and on seek, while the output is already faded out.
 */
typedef struct SynthLineVoice {
    /// Voice-owned, preallocated. Opaque to the engine.
    void *state;

    /// Called once on the control thread before rendering begins, and again
    /// whenever the sample rate changes (a device switch, or entering offline
    /// rendering). May not allocate: size everything for the worst case in
    /// advance.
    void (*prepare)(void *state, double sampleRate);

    /// Start a note. `velocity` is the timeline's 1…127.
    void (*noteOn)(void *state, int32_t midiNoteNumber, int32_t velocity);

    /// Release a note. If the sustain pedal is down the voice is expected to
    /// hold it until the pedal lifts.
    void (*noteOff)(void *state, int32_t midiNoteNumber);

    /// Sustain pedal state changed. Non-zero means down.
    void (*setSustainPedal)(void *state, int32_t isDown);

    /// Overwrite `frameCount` mono samples.
    void (*render)(void *state, float *monoOut, int32_t frameCount);

    /// Immediate silence, all notes and envelopes cleared.
    void (*reset)(void *state);
} SynthLineVoice;

#pragma mark - Tuning (TUN001, REQ-006)

/// Pitch classes in a tuning table: the twelve of a chromatic octave, indexed
/// by `midiNoteNumber % 12`, so index 0 is C and index 9 is A.
#define SYNTH_TUNING_PITCH_CLASS_COUNT 12

/*
 One program's tuning, already resolved into what a voice engine multiplies by.

 **A table of ratios, not of cents, and that is the whole design.** A
 temperament is written in cents and a reference pitch in hertz; turning either
 into a playback ratio means a `pow`, and the control thread is where this
 repository does that conversion (the `SampleVoiceCustomization` precedent:
 "cents become a playback-rate ratio here, on the control thread, so the audio
 thread never converts"). `TuningSettings.renderTable` is the one place it
 happens. A voice then applies tuning as a single multiply by the entry for the
 note's pitch class, and the two engines apply *the same number* — the
 synthesizer to the frequency it derives, the sampler to the playback rate it
 derives — which is what makes one setting mean one thing across both.

 **The default is exactly 1.0, and that is load-bearing.** Equal temperament at
 A=440 resolves to twelve ratios of exactly one, and a multiply by exactly one
 is the identity in IEEE-754 — not an approximation of it. So a program at
 default tuning renders bit-identically to one built before this table existed,
 which is REQ-006's "default tuning renders bit-identical to pre-feature
 output", proven by construction rather than by a tolerance.

 Installed on the control thread before a voice is handed to the engine and
 never written again, so it needs no atomics: the edge that publishes the
 program publishes this with it. `synth_patch_voice_init` and
 `sample_voice_create` install the default, so a caller that says nothing about
 tuning gets the identity rather than a zeroed table — which would be silence.
 */
typedef struct SynthTuningTable {
    /// Multiplier on the frequency (or playback rate) of a note of this pitch
    /// class. 1.0 leaves the note exactly where equal temperament at A=440 puts
    /// it.
    double ratioByPitchClass[SYNTH_TUNING_PITCH_CLASS_COUNT];
} SynthTuningTable;

/// Equal temperament at A=440: every ratio exactly 1.0.
void synth_tuning_table_default(SynthTuningTable *table);

/// `table` with every entry known finite and inside the range a tuning can
/// reach, so a hand-edited document or a NaN can never reach the multiply.
///
/// The bound is deliberately wider than the product's own settings need — a
/// reference shift of 415/440 is 0.943 and the widest temperament offset is a
/// few cents on top — and narrow enough that nothing here can transpose a note
/// into another octave.
void synth_tuning_table_sanitize(SynthTuningTable *table);

#pragma mark - Transport

typedef enum SynthTransportState {
    SynthTransportStopped = 0,
    SynthTransportPlaying = 1,
    SynthTransportPaused  = 2
} SynthTransportState;

/// Why the engine last left `SynthTransportPlaying` on its own.
typedef enum SynthPauseReason {
    SynthPauseReasonNone            = 0,
    /// The program ran out; playback finished normally.
    SynthPauseReasonReachedEnd      = 1,
    /// Sustained render overload. The engine faded out and paused rather than
    /// emitting torn audio (issue #15's stated failure behaviour).
    SynthPauseReasonOverload        = 2,
    /// The output device went away and no fallback was taken.
    SynthPauseReasonDeviceLost      = 3
} SynthPauseReason;

#pragma mark - Engine

typedef struct SynthRenderEngine SynthRenderEngine;

/*
 Construction (control thread, `SynthAudioSetup.c`).

 An engine is built once for a program and then configured. `lineCount` and
 `maximumFrameCount` are fixed at creation because the render thread must never
 discover that a buffer grew.
 */
SynthRenderEngine *synth_engine_create(int32_t lineCount,
                                       int32_t maximumFrameCount,
                                       double sampleRate);
void synth_engine_destroy(SynthRenderEngine *engine);

/// Reserve storage for one line's events and pedal spans. Call once per line
/// before filling them in. Returns 0 on failure.
int32_t synth_engine_reserve_line(SynthRenderEngine *engine,
                                  int32_t lineIndex,
                                  int32_t eventCount,
                                  int32_t pedalSpanCount);

/// Fill one scheduled note. Events must be supplied in non-decreasing
/// `onsetFrame` order — the scheduler walks them with a cursor and never sorts.
void synth_engine_set_event(SynthRenderEngine *engine,
                            int32_t lineIndex,
                            int32_t eventIndex,
                            int64_t onsetFrame,
                            int64_t endFrame,
                            int32_t midiNoteNumber,
                            int32_t velocity);

/// Fill one sustain-pedal span, in non-decreasing `startFrame` order.
void synth_engine_set_pedal_span(SynthRenderEngine *engine,
                                 int32_t lineIndex,
                                 int32_t spanIndex,
                                 int64_t startFrame,
                                 int64_t endFrame);

/// Attach the voice that renders this line. The engine copies the vtable; the
/// caller keeps ownership of `voice->state` and must outlive the engine.
void synth_engine_set_line_voice(SynthRenderEngine *engine,
                                 int32_t lineIndex,
                                 const SynthLineVoice *voice);

/// Total length of the program in frames, including release tails the caller
/// wants rendered. Playback pauses at this point with `SynthPauseReasonReachedEnd`.
void synth_engine_set_total_frames(SynthRenderEngine *engine, int64_t totalFrames);

/// Re-prepare every voice for a new sample rate and rebuild rate-derived
/// constants. Control thread, engine stopped.
///
/// Event positions are stored in frames, so they are rate-dependent: a caller
/// that changes the rate on an engine that already holds a program must reload
/// that program at the new rate. `PlaybackEngine` sidesteps this entirely by
/// building a fresh engine whenever the graph's format changes, which is why a
/// device switch and entering offline rendering take exactly the same path.
void synth_engine_set_sample_rate(SynthRenderEngine *engine, double sampleRate);

/// Real-time mode arms the overload watchdog. Offline manual rendering must
/// turn it off: an offline block has no deadline to miss, and leaving the
/// watchdog armed would pause a perfectly good export.
void synth_engine_set_realtime_mode(SynthRenderEngine *engine, int32_t isRealtime);

#pragma mark - Per-line mixer (control thread, safe while rendering)

/// Linear gain, clamped to 0…8.
void synth_engine_set_line_gain(SynthRenderEngine *engine, int32_t lineIndex, float gain);
/// -1 hard left, 0 centre, +1 hard right. Equal-power law.
void synth_engine_set_line_pan(SynthRenderEngine *engine, int32_t lineIndex, float pan);
void synth_engine_set_line_muted(SynthRenderEngine *engine, int32_t lineIndex, int32_t muted);
void synth_engine_set_line_soloed(SynthRenderEngine *engine, int32_t lineIndex, int32_t soloed);

/*
 How much of this line reaches the shared room, 0…1 (D7's per-line room send).

 **One hall for the whole mix, not one per line.** Every line sends into the
 same room and the room answers once, which is both the sound an orchestra
 makes and the affordable arrangement: eighteen private reverbs would be
 eighteen different acoustics and three orders of magnitude more delay memory.
 The room is fixed — there is no size or damping control — because D7's set is
 a send, and a full reverb section would be the sampler-editor drift the issue
 rules out.

 The send is post-fader and post-mute, so silencing a line silences it in the
 room too. Zero on every line until something asks otherwise, and the whole bus
 is skipped while that is true, so a mix that does not use the room costs
 exactly what it did before the room existed.
 */
void synth_engine_set_line_room_send(SynthRenderEngine *engine, int32_t lineIndex, float send);

float   synth_engine_line_gain(const SynthRenderEngine *engine, int32_t lineIndex);
float   synth_engine_line_pan(const SynthRenderEngine *engine, int32_t lineIndex);
int32_t synth_engine_line_muted(const SynthRenderEngine *engine, int32_t lineIndex);
int32_t synth_engine_line_soloed(const SynthRenderEngine *engine, int32_t lineIndex);
float   synth_engine_line_room_send(const SynthRenderEngine *engine, int32_t lineIndex);

/*
 How far back in the room the line sits, 0…1. Zero is the front and renders
 bit-identically to an engine without depth. Raising it attenuates and darkens
 the line's direct sound (distance and air absorption) and leans it into the
 shared room, so a far line is heard as far, not merely quiet. Like the send it
 is post-fader and post-mute, and a nonzero depth engages the room bus even
 when every explicit send is zero.
 */
void  synth_engine_set_line_depth(SynthRenderEngine *engine, int32_t lineIndex, float depth);
float synth_engine_line_depth(const SynthRenderEngine *engine, int32_t lineIndex);

/// Applies to the summed mix, after per-line gain and pan.
void  synth_engine_set_master_gain(SynthRenderEngine *engine, float gain);
float synth_engine_master_gain(const SynthRenderEngine *engine);

#pragma mark - The produced master (control thread, safe while rendering)

/*
 The master stage after the line sum (MST001): bus cohesion, the per-piece
 loudness calibration gain, and the always-on true-peak ceiling.

 **One switch covers two of the three** (owner decision D65-2, option A).
 Cohesion and calibration are the "Produced master" setting; the ceiling has no
 control and is always in the graph, because an export that clips is a defect
 and not a matter of taste (AD-P6). With the setting off the stage multiplies by
 exactly `1.0f` for any material that stays under the ceiling, so the output is
 the raw line sum bit for bit — REQ-004's composed bypass.

 The stage is program state, not an owner-facing mix control: the calibration
 figures come from `MasterCalibration`'s bounded analysis of this exact program
 and are rewritten whenever the program is rebuilt. Nothing here adapts while
 the piece is playing.
*/

/// Turn bus cohesion and the calibration gain on or off together.
void    synth_engine_set_produced_master(SynthRenderEngine *engine, int32_t enabled);
int32_t synth_engine_produced_master(const SynthRenderEngine *engine);

/// Publish the analysis pass's two figures: the gain that brings this piece to
/// the fixed loudness target, and where "loud for this piece" sits so cohesion
/// has something piece-relative to work against. A `cohesionThreshold` of zero
/// or less turns cohesion off; a `gain` of 1 is the no-calibration answer a
/// silent piece and a failed analysis both take.
void synth_engine_set_master_calibration(SynthRenderEngine *engine,
                                         float gain,
                                         float cohesionThreshold);
float synth_engine_master_calibration_gain(const SynthRenderEngine *engine);
float synth_engine_master_cohesion_threshold(const SynthRenderEngine *engine);

/// The ceiling, in linear amplitude. One definition, readable from Swift, so a
/// test asserting REQ-005's −1 dBFS cannot drift from the value the render
/// thread enforces.
float synth_master_ceiling(void);

/// Frames of lookahead the ceiling uses. Reported for the record rather than
/// for correction: the stage primes its own delay line, so output frame *k* is
/// program frame *k* and no caller has to compensate for anything.
int32_t synth_master_lookahead_frames(void);

#pragma mark - Transport (control thread, safe while rendering)

void synth_engine_play(SynthRenderEngine *engine);
void synth_engine_pause(SynthRenderEngine *engine);
void synth_engine_stop(SynthRenderEngine *engine);

/// Request a seek. The render thread fades out, jumps, resets every voice and
/// fades back in, so a seek is inaudible rather than a click. It therefore
/// takes effect a few milliseconds late; `synth_engine_seek_settled` reports
/// when it has landed.
void synth_engine_seek(SynthRenderEngine *engine, int64_t frame);
int32_t synth_engine_seek_settled(const SynthRenderEngine *engine);

/// Pause the engine because its output device disappeared, preserving the
/// playhead so resuming on another device continues where this left off.
void synth_engine_pause_for_device_loss(SynthRenderEngine *engine);

#pragma mark - Telemetry (render thread writes, control thread reads)

int64_t synth_engine_playhead_frame(const SynthRenderEngine *engine);
int32_t synth_engine_transport_state(const SynthRenderEngine *engine);
int32_t synth_engine_pause_reason(const SynthRenderEngine *engine);
int64_t synth_engine_rendered_blocks(const SynthRenderEngine *engine);
/// Blocks whose render took more than 85% of their real-time deadline.
int64_t synth_engine_overload_blocks(const SynthRenderEngine *engine);
/// How many times sustained overload forced a clean pause.
int64_t synth_engine_overload_pauses(const SynthRenderEngine *engine);
/// Largest absolute output sample seen since the last reset. Lets a caller
/// prove headroom rather than assume it.
float synth_engine_peak_level(const SynthRenderEngine *engine);
void  synth_engine_reset_telemetry(SynthRenderEngine *engine);

#pragma mark - The render entry point

/*
 The whole audio thread, in one call.

 Writes `frameCount` frames of stereo float into `bufferList` and returns 0.
 Sets `*isSilence` non-zero when it wrote silence, so the graph downstream can
 skip work. Allocates nothing, takes no lock, sends no message.
 */
int32_t synth_audio_core_render(SynthRenderEngine *engine,
                                AudioBufferList *bufferList,
                                int32_t frameCount,
                                int32_t *isSilence);

#ifdef __cplusplus
}
#endif

#endif /* SYNTH_AUDIO_CORE_H */
