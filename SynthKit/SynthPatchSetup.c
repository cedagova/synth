/*
 SynthPatchSetup.c — everything the synthesizer does on the control thread.

 Table generation, parameter clamping, sample-rate-derived constants and biquad
 coefficients. All of it is slow, none of it runs while audio is playing, and
 none of it allocates: the caller owns the voice's storage, and the wavetables
 are static.

 The split mirrors `SynthAudioCore.c` / `SynthAudioSetup.c` for the same
 reason — it makes the render file's real-time claim a property of a whole
 file, which `RealtimeSafetyTests` can check mechanically.
 */

#include "SynthPatchEngineInternal.h"

#include <math.h>

float synth_patch_sine_table[SYNTH_WAVE_TABLE_SIZE];
float synth_patch_analog_tables[SYNTH_ANALOG_TABLE_COUNT]
                               [SYNTH_WAVE_MIPMAP_COUNT]
                               [SYNTH_WAVE_TABLE_SIZE];
float synth_patch_wavetables[SYNTH_WAVETABLE_BANK_COUNT]
                            [SYNTH_WAVETABLE_FRAME_COUNT]
                            [SYNTH_WAVE_MIPMAP_COUNT]
                            [SYNTH_WAVE_TABLE_SIZE];

static int32_t synth_patch_tables_ready = 0;

#pragma mark - Small helpers

static float synth_patch_clampf(float value, float low, float high) {
    if (!(value == value)) { return low; }   /* NaN */
    return value < low ? low : (value > high ? high : value);
}

static int32_t synth_patch_clampi(int32_t value, int32_t low, int32_t high) {
    return value < low ? low : (value > high ? high : value);
}

/*
 Harmonics a mipmap may contain.

 Mipmap `m` is used for fundamentals up to 20 × 2^(m+1) Hz, so the highest
 harmonic that still fits under the band limit is that divided into it. Capped
 at half the table length, which is the most a table of this size can represent
 at all.
 */
static int32_t synth_patch_harmonic_limit(int32_t mipmap) {
    const double topFundamental = SYNTH_WAVE_MIPMAP_BASE_HERTZ * pow(2.0, (double)(mipmap + 1));
    int32_t limit = (int32_t)(SYNTH_WAVE_BAND_LIMIT_HERTZ / topFundamental);
    return synth_patch_clampi(limit, 1, SYNTH_WAVE_TABLE_SIZE / 2 - 1);
}

#pragma mark - Table generation

/*
 Analogue waveforms, built additively.

 Additive rather than "sample the ideal shape and hope": a naively sampled saw
 contains every harmonic including the ones above Nyquist, and those fold back
 as inharmonic tones that no amount of later filtering removes. Summing only
 the harmonics that fit is the whole point of the mipmaps.

 Each waveform is normalised by the peak of its *fullest* mipmap, so all eleven
 share one scale factor. Normalising each mipmap to its own peak would make a
 held note change loudness as it crossed an octave boundary, and would make the
 spectral assertions in `SynthEngineRenderTests` depend on which octave the
 fixture happened to use.
 */
static void synth_patch_build_analog_tables(void) {
    const double twoPi = 2.0 * M_PI;

    for (int32_t table = 0; table < SYNTH_ANALOG_TABLE_COUNT; table++) {
        float scale = 1.0f;

        for (int32_t mipmap = 0; mipmap < SYNTH_WAVE_MIPMAP_COUNT; mipmap++) {
            const int32_t limit = synth_patch_harmonic_limit(mipmap);
            float *destination = synth_patch_analog_tables[table][mipmap];

            for (int32_t index = 0; index < SYNTH_WAVE_TABLE_SIZE; index++) {
                const double x = twoPi * (double)index / (double)SYNTH_WAVE_TABLE_SIZE;
                double total = 0.0;

                for (int32_t k = 1; k <= limit; k++) {
                    switch (table) {
                        case SynthAnalogTableSaw:
                            /* (2/pi) * sum (-1)^(k+1) sin(kx)/k */
                            total += ((k % 2) ? 1.0 : -1.0) * sin((double)k * x) / (double)k;
                            break;
                        case SynthAnalogTableSquare:
                            if (k % 2) { total += sin((double)k * x) / (double)k; }
                            break;
                        case SynthAnalogTableTriangle:
                            if (k % 2) {
                                const double sign = (((k - 1) / 2) % 2) ? -1.0 : 1.0;
                                total += sign * sin((double)k * x) / ((double)k * (double)k);
                            }
                            break;
                        default:
                            break;
                    }
                }

                switch (table) {
                    case SynthAnalogTableSaw:      total *= 2.0 / M_PI; break;
                    case SynthAnalogTableSquare:   total *= 4.0 / M_PI; break;
                    case SynthAnalogTableTriangle: total *= 8.0 / (M_PI * M_PI); break;
                    default: break;
                }
                destination[index] = (float)total;
            }

            /* The first mipmap has the most harmonics and therefore the
               largest Gibbs overshoot; its peak sets the scale for all of
               them. */
            if (mipmap == 0) {
                float peak = 0.0f;
                for (int32_t index = 0; index < SYNTH_WAVE_TABLE_SIZE; index++) {
                    const float magnitude = fabsf(destination[index]);
                    if (magnitude > peak) { peak = magnitude; }
                }
                scale = peak > 0.0f ? 1.0f / peak : 1.0f;
            }
            for (int32_t index = 0; index < SYNTH_WAVE_TABLE_SIZE; index++) {
                destination[index] *= scale;
            }
        }
    }
}

/// Harmonic amplitude for one wavetable bank frame.
static double synth_patch_wavetable_amplitude(int32_t bank, int32_t frame, int32_t harmonic) {
    const double k = (double)harmonic;
    const double f = (double)frame;

    switch (bank) {
        case SynthWavetableBankHarmonic: {
            /* Frame 0 is nearly a sine; frame 3 is close to a saw. */
            const double exponent = 3.0 - f * 0.7;
            return pow(k, -exponent);
        }
        case SynthWavetableBankFormant: {
            /* A resonant peak climbing the series: 2nd, 5th, 9th, 14th. */
            static const double centre[SYNTH_WAVETABLE_FRAME_COUNT] = { 2.0, 5.0, 9.0, 14.0 };
            const double width = 1.5 + f;
            const double offset = k - centre[frame];
            return exp(-(offset * offset) / (2.0 * width * width)) / sqrt(k);
        }
        case SynthWavetableBankMetallic: {
            /* Sparse upper partials — 1, 3, 7, 11, 15 … — so the spectrum
               reads as inharmonic even though a single-cycle table cannot be. */
            if (harmonic != 1 && (harmonic % 4) != 3) { return 0.0; }
            const double reach = 3.0 + f * 9.0;
            if (k > reach) { return 0.0; }
            return pow(k, -0.5);
        }
        case SynthWavetableBankHollow: {
            if ((harmonic % 2) == 0) { return 0.0; }
            const double exponent = 2.5 - f * 0.6;
            return pow(k, -exponent);
        }
        default:
            return harmonic == 1 ? 1.0 : 0.0;
    }
}

/*
 Wavetable banks.

 Peak-normalised per frame rather than analytically scaled, because these
 spectra have no closed-form peak and an un-normalised metallic frame is many
 times louder than a hollow one. The normalisation uses the fullest mipmap's
 peak for the same reason as above: one scale per frame, not one per octave.
 */
static void synth_patch_build_wavetables(void) {
    const double twoPi = 2.0 * M_PI;

    for (int32_t bank = 0; bank < SYNTH_WAVETABLE_BANK_COUNT; bank++) {
        for (int32_t frame = 0; frame < SYNTH_WAVETABLE_FRAME_COUNT; frame++) {
            float scale = 1.0f;

            for (int32_t mipmap = 0; mipmap < SYNTH_WAVE_MIPMAP_COUNT; mipmap++) {
                const int32_t limit = synth_patch_harmonic_limit(mipmap);
                float *destination = synth_patch_wavetables[bank][frame][mipmap];

                for (int32_t index = 0; index < SYNTH_WAVE_TABLE_SIZE; index++) {
                    const double x = twoPi * (double)index / (double)SYNTH_WAVE_TABLE_SIZE;
                    double total = 0.0;
                    for (int32_t k = 1; k <= limit; k++) {
                        const double amplitude = synth_patch_wavetable_amplitude(bank, frame, k);
                        if (amplitude != 0.0) { total += amplitude * sin((double)k * x); }
                    }
                    destination[index] = (float)total;
                }

                if (mipmap == 0) {
                    float peak = 0.0f;
                    for (int32_t index = 0; index < SYNTH_WAVE_TABLE_SIZE; index++) {
                        const float magnitude = fabsf(destination[index]);
                        if (magnitude > peak) { peak = magnitude; }
                    }
                    scale = peak > 0.0f ? 1.0f / peak : 1.0f;
                }
                for (int32_t index = 0; index < SYNTH_WAVE_TABLE_SIZE; index++) {
                    destination[index] *= scale;
                }
            }
        }
    }
}

void synth_patch_prepare_tables(void) {
    if (synth_patch_tables_ready) { return; }

    for (int32_t index = 0; index < SYNTH_WAVE_TABLE_SIZE; index++) {
        synth_patch_sine_table[index] =
            (float)sin(2.0 * M_PI * (double)index / (double)SYNTH_WAVE_TABLE_SIZE);
    }
    synth_patch_build_analog_tables();
    synth_patch_build_wavetables();

    synth_patch_tables_ready = 1;
}

#pragma mark - Array element setters

void synth_patch_config_set_oscillator(SynthPatchConfig *config, int32_t index,
                                       const SynthOscillatorConfig *oscillator) {
    if (index < 0 || index >= SYNTH_PATCH_OSCILLATOR_COUNT) { return; }
    config->oscillators[index] = *oscillator;
}


void synth_patch_config_set_lfo(SynthPatchConfig *config, int32_t index,
                                const SynthLFOConfig *lfo) {
    if (index < 0 || index >= SYNTH_PATCH_LFO_COUNT) { return; }
    config->lfos[index] = *lfo;
}


void synth_patch_config_set_modulation(SynthPatchConfig *config, int32_t index,
                                       const SynthModulationSlotConfig *slot) {
    if (index < 0 || index >= SYNTH_PATCH_MOD_SLOT_COUNT) { return; }
    config->modulation[index] = *slot;
}


#pragma mark - Parameter clamping

static void synth_patch_sanitize_envelope(SynthEnvelopeConfig *envelope) {
    envelope->attackSeconds  = synth_patch_clampf(envelope->attackSeconds, 0.0005f, 10.0f);
    envelope->decaySeconds   = synth_patch_clampf(envelope->decaySeconds, 0.001f, 20.0f);
    envelope->sustainLevel   = synth_patch_clampf(envelope->sustainLevel, 0.0f, 1.0f);
    envelope->releaseSeconds = synth_patch_clampf(envelope->releaseSeconds, 0.001f, 20.0f);
    envelope->curve          = synth_patch_clampf(envelope->curve, 0.0f, 1.0f);
}

void synth_patch_config_sanitize(SynthPatchConfig *config) {
    for (int32_t index = 0; index < SYNTH_PATCH_OSCILLATOR_COUNT; index++) {
        SynthOscillatorConfig *oscillator = &config->oscillators[index];
        oscillator->type = synth_patch_clampi(oscillator->type,
                                              SynthOscillatorTypeAnalog,
                                              SynthOscillatorTypeFM);
        const int32_t shapeCeiling = (oscillator->type == SynthOscillatorTypeWavetable)
            ? SYNTH_WAVETABLE_BANK_COUNT - 1
            : SynthAnalogShapePulse;
        oscillator->shape           = synth_patch_clampi(oscillator->shape, 0, shapeCeiling);
        oscillator->level           = synth_patch_clampf(oscillator->level, 0.0f, 1.0f);
        oscillator->detuneSemitones = synth_patch_clampf(oscillator->detuneSemitones, -48.0f, 48.0f);
        oscillator->detuneCents     = synth_patch_clampf(oscillator->detuneCents, -100.0f, 100.0f);
        oscillator->shapeAmount     = synth_patch_clampf(oscillator->shapeAmount, 0.0f, 1.0f);
        oscillator->fmRatio         = synth_patch_clampf(oscillator->fmRatio, 0.25f, 16.0f);
        oscillator->startPhase      = synth_patch_clampf(oscillator->startPhase, 0.0f, 1.0f);
        oscillator->retriggersPhase = oscillator->retriggersPhase ? 1 : 0;
    }

    config->noiseLevel = synth_patch_clampf(config->noiseLevel, 0.0f, 1.0f);

    config->filter.isEnabled   = config->filter.isEnabled ? 1 : 0;
    config->filter.type        = synth_patch_clampi(config->filter.type,
                                                    SynthFilterTypeLowpass,
                                                    SynthFilterTypeNotch);
    config->filter.poles       = config->filter.poles >= 4 ? 4 : 2;
    config->filter.cutoffHertz = synth_patch_clampf(config->filter.cutoffHertz, 20.0f, 20000.0f);
    config->filter.resonance   = synth_patch_clampf(config->filter.resonance, 0.0f, 1.0f);
    config->filter.keyTracking = synth_patch_clampf(config->filter.keyTracking, 0.0f, 1.0f);

    synth_patch_sanitize_envelope(&config->amplitudeEnvelope);
    synth_patch_sanitize_envelope(&config->modulationEnvelope);

    for (int32_t index = 0; index < SYNTH_PATCH_LFO_COUNT; index++) {
        SynthLFOConfig *lfo = &config->lfos[index];
        lfo->shape             = synth_patch_clampi(lfo->shape,
                                                    SynthLFOShapeSine,
                                                    SynthLFOShapeSampleAndHold);
        lfo->rateHertz         = synth_patch_clampf(lfo->rateHertz, 0.01f, 40.0f);
        lfo->startPhase        = synth_patch_clampf(lfo->startPhase, 0.0f, 1.0f);
        lfo->retriggersPerNote = lfo->retriggersPerNote ? 1 : 0;
    }

    for (int32_t index = 0; index < SYNTH_PATCH_MOD_SLOT_COUNT; index++) {
        SynthModulationSlotConfig *slot = &config->modulation[index];
        slot->source      = synth_patch_clampi(slot->source, 0, SYNTH_MOD_SOURCE_COUNT - 1);
        slot->destination = synth_patch_clampi(slot->destination, 0, SYNTH_MOD_DESTINATION_COUNT - 1);
        slot->amount      = synth_patch_clampf(slot->amount, -1.0f, 1.0f);
    }

    config->equalizer.isEnabled        = config->equalizer.isEnabled ? 1 : 0;
    config->equalizer.lowGainDecibels  = synth_patch_clampf(config->equalizer.lowGainDecibels, -24.0f, 24.0f);
    config->equalizer.lowHertz         = synth_patch_clampf(config->equalizer.lowHertz, 30.0f, 1000.0f);
    config->equalizer.midGainDecibels  = synth_patch_clampf(config->equalizer.midGainDecibels, -24.0f, 24.0f);
    config->equalizer.midHertz         = synth_patch_clampf(config->equalizer.midHertz, 100.0f, 8000.0f);
    config->equalizer.midQ             = synth_patch_clampf(config->equalizer.midQ, 0.2f, 8.0f);
    config->equalizer.highGainDecibels = synth_patch_clampf(config->equalizer.highGainDecibels, -24.0f, 24.0f);
    config->equalizer.highHertz        = synth_patch_clampf(config->equalizer.highHertz, 1000.0f, 16000.0f);

    config->chorus.isEnabled         = config->chorus.isEnabled ? 1 : 0;
    config->chorus.rateHertz         = synth_patch_clampf(config->chorus.rateHertz, 0.01f, 8.0f);
    config->chorus.depthMilliseconds = synth_patch_clampf(config->chorus.depthMilliseconds, 0.5f, 20.0f);
    config->chorus.centreMilliseconds = synth_patch_clampf(config->chorus.centreMilliseconds, 1.0f, 30.0f);
    config->chorus.mix               = synth_patch_clampf(config->chorus.mix, 0.0f, 1.0f);
    config->chorus.feedback          = synth_patch_clampf(config->chorus.feedback, 0.0f, 0.7f);

    config->delay.isEnabled  = config->delay.isEnabled ? 1 : 0;
    config->delay.timeSeconds = synth_patch_clampf(config->delay.timeSeconds, 0.005f,
                                                   (float)SYNTH_DELAY_MAX_SECONDS);
    config->delay.feedback    = synth_patch_clampf(config->delay.feedback, 0.0f, 0.85f);
    config->delay.mix         = synth_patch_clampf(config->delay.mix, 0.0f, 1.0f);
    config->delay.dampening   = synth_patch_clampf(config->delay.dampening, 0.0f, 1.0f);

    config->reverb.isEnabled       = config->reverb.isEnabled ? 1 : 0;
    config->reverb.roomSize        = synth_patch_clampf(config->reverb.roomSize, 0.0f, 1.0f);
    config->reverb.dampening       = synth_patch_clampf(config->reverb.dampening, 0.0f, 1.0f);
    config->reverb.mix             = synth_patch_clampf(config->reverb.mix, 0.0f, 1.0f);
    config->reverb.preDelaySeconds = synth_patch_clampf(config->reverb.preDelaySeconds, 0.0f, 0.1f);

    config->maximumVoices       = synth_patch_clampi(config->maximumVoices, 1, SYNTH_PATCH_MAX_VOICES);
    config->outputLevel         = synth_patch_clampf(config->outputLevel, 0.0f, 1.0f);
    config->velocitySensitivity = synth_patch_clampf(config->velocitySensitivity, 0.2f, 4.0f);
}

#pragma mark - The shipped default voice (AD7)

/*
 Increment 002's built-in voice, expressed as a patch.

 Three sine partials at 1×, 2× and 3× with weights 1, 0.34 and 0.13, a linear
 8 ms / 120 ms / 0.60 / 220 ms ADSR, a velocity exponent of 1.6 and an output
 level of 0.14 — the same numbers `synth_default_voice_*` used, so the sound
 the app makes on the day this lands is the sound it made the day before, and
 any change in the offline suite's measurements is a real change rather than a
 new instrument.

 19.01955 semitones is 12 × log2(3): the third harmonic, expressed in the
 tuning units a patch actually has.
 */
void synth_patch_config_default(SynthPatchConfig *config) {
    for (int32_t index = 0; index < SYNTH_PATCH_OSCILLATOR_COUNT; index++) {
        SynthOscillatorConfig *oscillator = &config->oscillators[index];
        oscillator->type            = SynthOscillatorTypeAnalog;
        oscillator->shape           = SynthAnalogShapeSine;
        oscillator->level           = 0.0f;
        oscillator->detuneSemitones = 0.0f;
        oscillator->detuneCents     = 0.0f;
        oscillator->shapeAmount     = 0.5f;
        oscillator->fmRatio         = 1.0f;
        oscillator->retriggersPhase = 1;
        oscillator->startPhase      = 0.0f;
    }
    config->oscillators[0].level = 1.0f;
    config->oscillators[1].level = 0.34f;
    config->oscillators[1].detuneSemitones = 12.0f;
    config->oscillators[2].level = 0.13f;
    config->oscillators[2].detuneSemitones = 19.01955f;

    config->noiseLevel = 0.0f;

    config->filter.isEnabled   = 0;
    config->filter.type        = SynthFilterTypeLowpass;
    config->filter.poles       = 2;
    config->filter.cutoffHertz = 12000.0f;
    config->filter.resonance   = 0.0f;
    config->filter.keyTracking = 0.0f;

    config->amplitudeEnvelope.attackSeconds  = 0.008f;
    config->amplitudeEnvelope.decaySeconds   = 0.120f;
    config->amplitudeEnvelope.sustainLevel   = 0.60f;
    config->amplitudeEnvelope.releaseSeconds = 0.220f;
    config->amplitudeEnvelope.curve          = 0.0f;

    config->modulationEnvelope.attackSeconds  = 0.010f;
    config->modulationEnvelope.decaySeconds   = 0.400f;
    config->modulationEnvelope.sustainLevel   = 0.0f;
    config->modulationEnvelope.releaseSeconds = 0.300f;
    config->modulationEnvelope.curve          = 1.0f;

    for (int32_t index = 0; index < SYNTH_PATCH_LFO_COUNT; index++) {
        config->lfos[index].shape             = SynthLFOShapeSine;
        config->lfos[index].rateHertz         = 5.0f;
        config->lfos[index].startPhase        = 0.0f;
        config->lfos[index].retriggersPerNote = 0;
    }

    for (int32_t index = 0; index < SYNTH_PATCH_MOD_SLOT_COUNT; index++) {
        config->modulation[index].source      = SynthModSourceNone;
        config->modulation[index].destination = SynthModDestinationNone;
        config->modulation[index].amount      = 0.0f;
    }

    config->equalizer.isEnabled        = 0;
    config->equalizer.lowGainDecibels  = 0.0f;
    config->equalizer.lowHertz         = 200.0f;
    config->equalizer.midGainDecibels  = 0.0f;
    config->equalizer.midHertz         = 1000.0f;
    config->equalizer.midQ             = 1.0f;
    config->equalizer.highGainDecibels = 0.0f;
    config->equalizer.highHertz        = 6000.0f;

    config->chorus.isEnabled          = 0;
    config->chorus.rateHertz          = 0.6f;
    config->chorus.depthMilliseconds  = 4.0f;
    config->chorus.centreMilliseconds = 12.0f;
    config->chorus.mix                = 0.4f;
    config->chorus.feedback           = 0.15f;

    config->delay.isEnabled   = 0;
    config->delay.timeSeconds = 0.28f;
    config->delay.feedback    = 0.35f;
    config->delay.mix         = 0.25f;
    config->delay.dampening   = 0.4f;

    config->reverb.isEnabled       = 0;
    config->reverb.roomSize        = 0.6f;
    config->reverb.dampening       = 0.5f;
    config->reverb.mix             = 0.25f;
    config->reverb.preDelaySeconds = 0.02f;

    config->maximumVoices       = SYNTH_PATCH_MAX_VOICES;
    config->outputLevel         = 0.14f;
    config->velocitySensitivity = 1.6f;
    config->seed                = 0x5EED0000C0FFEEULL;
}

#pragma mark - Biquad coefficients (RBJ cookbook)

static void synth_patch_biquad_clear(SynthBiquad *biquad) {
    biquad->x1 = 0.0f; biquad->x2 = 0.0f;
    biquad->y1 = 0.0f; biquad->y2 = 0.0f;
}

static void synth_patch_biquad_bypass(SynthBiquad *biquad) {
    biquad->b0 = 1.0f; biquad->b1 = 0.0f; biquad->b2 = 0.0f;
    biquad->a1 = 0.0f; biquad->a2 = 0.0f;
    synth_patch_biquad_clear(biquad);
}

static void synth_patch_biquad_store(SynthBiquad *biquad,
                                     double b0, double b1, double b2,
                                     double a0, double a1, double a2) {
    if (a0 == 0.0) { synth_patch_biquad_bypass(biquad); return; }
    biquad->b0 = (float)(b0 / a0);
    biquad->b1 = (float)(b1 / a0);
    biquad->b2 = (float)(b2 / a0);
    biquad->a1 = (float)(a1 / a0);
    biquad->a2 = (float)(a2 / a0);
    synth_patch_biquad_clear(biquad);
}

static void synth_patch_low_shelf(SynthBiquad *biquad, double frequency, double decibels, double sampleRate) {
    const double A = pow(10.0, decibels / 40.0);
    const double w0 = 2.0 * M_PI * frequency / sampleRate;
    const double cosW = cos(w0);
    const double alpha = sin(w0) / 2.0 * sqrt(2.0);
    const double twoSqrtAAlpha = 2.0 * sqrt(A) * alpha;
    synth_patch_biquad_store(biquad,
        A * ((A + 1.0) - (A - 1.0) * cosW + twoSqrtAAlpha),
        2.0 * A * ((A - 1.0) - (A + 1.0) * cosW),
        A * ((A + 1.0) - (A - 1.0) * cosW - twoSqrtAAlpha),
        (A + 1.0) + (A - 1.0) * cosW + twoSqrtAAlpha,
        -2.0 * ((A - 1.0) + (A + 1.0) * cosW),
        (A + 1.0) + (A - 1.0) * cosW - twoSqrtAAlpha);
}

static void synth_patch_high_shelf(SynthBiquad *biquad, double frequency, double decibels, double sampleRate) {
    const double A = pow(10.0, decibels / 40.0);
    const double w0 = 2.0 * M_PI * frequency / sampleRate;
    const double cosW = cos(w0);
    const double alpha = sin(w0) / 2.0 * sqrt(2.0);
    const double twoSqrtAAlpha = 2.0 * sqrt(A) * alpha;
    synth_patch_biquad_store(biquad,
        A * ((A + 1.0) + (A - 1.0) * cosW + twoSqrtAAlpha),
        -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW),
        A * ((A + 1.0) + (A - 1.0) * cosW - twoSqrtAAlpha),
        (A + 1.0) - (A - 1.0) * cosW + twoSqrtAAlpha,
        2.0 * ((A - 1.0) - (A + 1.0) * cosW),
        (A + 1.0) - (A - 1.0) * cosW - twoSqrtAAlpha);
}

static void synth_patch_peaking(SynthBiquad *biquad, double frequency, double decibels,
                                double q, double sampleRate) {
    const double A = pow(10.0, decibels / 40.0);
    const double w0 = 2.0 * M_PI * frequency / sampleRate;
    const double cosW = cos(w0);
    const double alpha = sin(w0) / (2.0 * q);
    synth_patch_biquad_store(biquad,
        1.0 + alpha * A,
        -2.0 * cosW,
        1.0 - alpha * A,
        1.0 + alpha / A,
        -2.0 * cosW,
        1.0 - alpha / A);
}

#pragma mark - Sample-rate-derived state

/*
 Freeverb's comb and allpass tunings, in frames at 44.1 kHz.

 Kept as the published values and scaled rather than re-derived: they are
 mutually prime lengths chosen so the combs do not reinforce each other into a
 metallic ring, and inventing new ones would be a worse reverb for no reason.
 */
static const int32_t synth_reverb_comb_tuning[SYNTH_REVERB_COMB_COUNT] = {
    1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617
};
static const int32_t synth_reverb_allpass_tuning[SYNTH_REVERB_ALLPASS_COUNT] = {
    556, 441, 341, 225
};

/// The five coefficients of a designed biquad, without its history.
static void synth_patch_biquad_coefficients(const SynthBiquad *biquad, float out[5]) {
    out[0] = biquad->b0;
    out[1] = biquad->b1;
    out[2] = biquad->b2;
    out[3] = biquad->a1;
    out[4] = biquad->a2;
}

void synth_patch_derive(SynthPatchDerived *derived,
                        const SynthPatchConfig *config,
                        double sampleRate) {
    if (!(sampleRate > 0.0)) { sampleRate = 48000.0; }

    derived->config = *config;
    derived->sampleRate = sampleRate;

    /*
     Two rates, on purpose.

     Pitch, envelopes, LFOs and the filter are derived from the real rate,
     because a note has to sound at the frequency it was asked for however fast
     the device is running. The effect buffers are derived from `effectiveRate`
     instead, which is capped at the rate they were sized for.

     Without that cap a 192 kHz interface — ordinary hardware for this audience
     — would make every reverb comb saturate to the same maximum length, and
     eight identical combs are not a room, they are one metallic ring. Capping
     gives a room that is slightly smaller than the patch asked for, which is a
     far better answer than a broken one. The same cap keeps the chorus tap and
     the delay inside the buffers they actually have.
    */
    const double effectiveRate = sampleRate > SYNTH_PATCH_MAX_SAMPLE_RATE
        ? SYNTH_PATCH_MAX_SAMPLE_RATE
        : sampleRate;

    /* A patch's cutoff may be 20 kHz, which is above Nyquist at 44.1 kHz and
       would make the state-variable filter's tan() blow up. */
    derived->filterCutoffCeiling = (float)(sampleRate * 0.45);

    const double controlRate = sampleRate / (double)SYNTH_CONTROL_BLOCK_FRAMES;

    derived->amplitudeRate[0] = (float)(1.0 / (config->amplitudeEnvelope.attackSeconds * controlRate));
    derived->amplitudeRate[1] = (float)(1.0 / (config->amplitudeEnvelope.decaySeconds * controlRate));
    derived->amplitudeRate[2] = (float)(1.0 / (config->amplitudeEnvelope.releaseSeconds * controlRate));

    derived->modulationRate[0] = (float)(1.0 / (config->modulationEnvelope.attackSeconds * controlRate));
    derived->modulationRate[1] = (float)(1.0 / (config->modulationEnvelope.decaySeconds * controlRate));
    derived->modulationRate[2] = (float)(1.0 / (config->modulationEnvelope.releaseSeconds * controlRate));

    for (int32_t index = 0; index < SYNTH_PATCH_LFO_COUNT; index++) {
        derived->lfoIncrement[index] = (double)config->lfos[index].rateHertz / controlRate;
    }

    derived->activeVoiceLimit = config->maximumVoices;

    /* Equaliser. Designed into a scratch biquad and taken as coefficients: a
       snapshot must not carry a history, because installing one must not clear
       the history the voice already has. */
    {
        SynthBiquad low, mid, high;
        if (config->equalizer.isEnabled) {
            const double nyquist = sampleRate * 0.5;
            double lowHertz  = config->equalizer.lowHertz;
            double midHertz  = config->equalizer.midHertz;
            double highHertz = config->equalizer.highHertz;
            if (lowHertz  > nyquist * 0.9) { lowHertz  = nyquist * 0.9; }
            if (midHertz  > nyquist * 0.9) { midHertz  = nyquist * 0.9; }
            if (highHertz > nyquist * 0.9) { highHertz = nyquist * 0.9; }
            synth_patch_low_shelf(&low, lowHertz,
                                  config->equalizer.lowGainDecibels, sampleRate);
            synth_patch_peaking(&mid, midHertz,
                                config->equalizer.midGainDecibels,
                                config->equalizer.midQ, sampleRate);
            synth_patch_high_shelf(&high, highHertz,
                                   config->equalizer.highGainDecibels, sampleRate);
        } else {
            synth_patch_biquad_bypass(&low);
            synth_patch_biquad_bypass(&mid);
            synth_patch_biquad_bypass(&high);
        }
        synth_patch_biquad_coefficients(&low, derived->equalizerLow);
        synth_patch_biquad_coefficients(&mid, derived->equalizerMid);
        synth_patch_biquad_coefficients(&high, derived->equalizerHigh);
    }

    /* Chorus. */
    {
        const double limit = (double)(SYNTH_CHORUS_MAX_FRAMES - 4);
        double centre = config->chorus.centreMilliseconds * 0.001 * effectiveRate;
        if (centre > limit) { centre = limit; }
        double depth = config->chorus.depthMilliseconds * 0.001 * effectiveRate;

        /* The swept tap must stay inside the buffer at its far extreme and
           strictly behind the write head at its near one. Clamping the centre
           without clamping the depth to match would let the tap read *ahead* of
           the write pointer — in bounds, but audio from the previous pass
           rather than the signal the patch asked for. */
        if (centre + depth > limit) { centre = limit - depth; }
        if (centre < 2.0) { centre = 2.0; }
        if (depth > centre - 2.0) { depth = centre - 2.0; }
        if (depth < 0.0) { depth = 0.0; }

        derived->chorusCentreFrames = (float)centre;
        derived->chorusDepthFrames  = (float)depth;
        derived->chorusMix          = config->chorus.mix;
        derived->chorusFeedback     = config->chorus.feedback;
        derived->chorusLFOIncrement = (double)config->chorus.rateHertz / sampleRate;
    }

    /* Delay. */
    {
        int32_t length = (int32_t)(config->delay.timeSeconds * effectiveRate);
        derived->delayLengthFrames = synth_patch_clampi(length, 1, SYNTH_DELAY_MAX_FRAMES - 1);
        derived->delayFeedback = config->delay.feedback;
        derived->delayMix      = config->delay.mix;
        /* One-pole low pass in the feedback path. Even at zero dampening a
           little is kept, so a long feedback tail always loses energy. */
        derived->delayDampingCoefficient = 0.05f + 0.85f * config->delay.dampening;
    }

    /* Reverb. */
    {
        const double scale = effectiveRate / 44100.0;
        for (int32_t index = 0; index < SYNTH_REVERB_COMB_COUNT; index++) {
            derived->reverbCombLength[index] = synth_patch_clampi(
                (int32_t)((double)synth_reverb_comb_tuning[index] * scale),
                1, SYNTH_REVERB_COMB_MAX_FRAMES);
        }
        for (int32_t index = 0; index < SYNTH_REVERB_ALLPASS_COUNT; index++) {
            derived->reverbAllpassLength[index] = synth_patch_clampi(
                (int32_t)((double)synth_reverb_allpass_tuning[index] * scale),
                1, SYNTH_REVERB_ALLPASS_MAX_FRAMES);
        }
        derived->reverbPreDelayLength = synth_patch_clampi(
            (int32_t)(config->reverb.preDelaySeconds * effectiveRate),
            1, SYNTH_REVERB_PREDELAY_MAX_FRAMES - 1);
        /* 0.70…0.98 comb feedback. Never 1: the tail must always end. */
        derived->reverbFeedback = 0.70f + 0.28f * config->reverb.roomSize;
        derived->reverbDamping  = 0.10f + 0.60f * config->reverb.dampening;
        derived->reverbMix      = config->reverb.mix;
    }
}

/*
 The whole voice, re-derived at a new rate.

 Now a thin wrapper: derive the snapshot, install it, and clear the three
 equaliser histories that the previous coefficients belonged to. The clear is
 right here and not in `synth_patch_voice_install` on purpose — a rate change
 always ends in `synth_patch_voice_clear` and starts from silence anyway, while
 a live parameter edit must leave the filter's memory exactly where it is.
*/
void synth_patch_voice_update_rate(SynthPatchVoiceState *state, double sampleRate) {
    SynthPatchDerived derived;
    synth_patch_derive(&derived, &state->config, sampleRate);

    /* The rate is set here, on the control thread, and nowhere else.
       `synth_patch_voice_install` deliberately does not write it: install also
       runs on the render thread when a published patch is taken up, and a plain
       `double` written there and read by `synth_patch_voice_publish` here would
       be a data race — a value-benign one, since publish only proceeds when the
       two are already equal, but a race all the same and one a sanitiser would
       be right to flag. Keeping the write on one thread removes it rather than
       explaining it. */
    state->sampleRate = derived.sampleRate;
    synth_patch_voice_install(state, &derived);

    synth_patch_biquad_clear(&state->equalizer.low);
    synth_patch_biquad_clear(&state->equalizer.mid);
    synth_patch_biquad_clear(&state->equalizer.high);

    /*
     Anything staged for the old rate describes geometry this voice no longer
     has. Drop it rather than let the render thread install it.

     One atomic AND rather than a load followed by a store. The two-step version
     looks equivalent and is not: a `publish` or an `adopt` landing between the
     load and the store would be clobbered, and with it the invariant that
     `liveShared & 3`, `liveWriteIndex` and `liveReadIndex` are always three
     distinct slots. That permutation is the whole reason the triple buffer is
     safe; once two of them coincide the render thread can read a half-written
     snapshot. No shipped path reaches this concurrently today — see the header
     — but the fix costs one instruction and the failure it prevents would be
     close to undebuggable.
    */
    atomic_fetch_and_explicit(&state->liveShared, SYNTH_LIVE_INDEX_MASK,
                              memory_order_acq_rel);
}

#pragma mark - Live editing

int32_t synth_patch_voice_publish(SynthPatchVoiceState *state,
                                  const SynthPatchConfig *config,
                                  double sampleRate) {
    if (state == NULL || config == NULL) { return 0; }
    /* `state->sampleRate` is written only by `synth_patch_voice_update_rate`,
       which is control-thread and, per the header, exclusive of this call — so
       reading it here is a plain read rather than a race. A mismatch means the
       caller is holding a voice from a graph that has been rebuilt underneath
       it. */
    if (sampleRate != state->sampleRate) { return 0; }

    SynthPatchConfig sanitized = *config;
    synth_patch_config_sanitize(&sanitized);

    synth_patch_derive(&state->liveSlots[state->liveWriteIndex], &sanitized, sampleRate);

    const int32_t exchanged = atomic_exchange_explicit(
        &state->liveShared,
        state->liveWriteIndex | SYNTH_LIVE_FRESH,
        memory_order_acq_rel);
    state->liveWriteIndex = exchanged & SYNTH_LIVE_INDEX_MASK;
    return 1;
}

int64_t synth_patch_voice_adoptions(const SynthPatchVoiceState *state) {
    if (state == NULL) { return 0; }
    return atomic_load_explicit(&state->liveAdoptions, memory_order_relaxed);
}

int32_t synth_patch_voice_post_event(SynthPatchVoiceState *state,
                                     int32_t kind,
                                     int32_t midiNoteNumber,
                                     int32_t velocity) {
    if (state == NULL) { return 0; }

    const int64_t write = atomic_load_explicit(&state->liveNoteWrite, memory_order_relaxed);
    const int64_t read  = atomic_load_explicit(&state->liveNoteRead, memory_order_acquire);
    if (write - read >= (int64_t)SYNTH_LIVE_NOTE_CAPACITY) { return 0; }

    SynthLiveNoteEvent *slot = &state->liveNotes[write & SYNTH_LIVE_NOTE_MASK];
    slot->kind = kind;
    slot->note = midiNoteNumber;
    slot->velocity = velocity;

    atomic_store_explicit(&state->liveNoteWrite, write + 1, memory_order_release);
    return 1;
}

int32_t synth_patch_live_event_note_on(void)  { return SynthLiveEventNoteOn; }
int32_t synth_patch_live_event_note_off(void) { return SynthLiveEventNoteOff; }
int32_t synth_patch_live_event_pedal(void)    { return SynthLiveEventPedal; }
int32_t synth_patch_live_event_all_off(void)  { return SynthLiveEventAllOff; }

#pragma mark - Construction

size_t synth_patch_voice_state_size(void) {
    return sizeof(struct SynthPatchVoiceState);
}

size_t synth_patch_voice_state_alignment(void) {
    return _Alignof(struct SynthPatchVoiceState);
}

static void synth_patch_voice_prepare(void *opaque, double sampleRate) {
    SynthPatchVoiceState *state = (SynthPatchVoiceState *)opaque;
    synth_patch_voice_update_rate(state, sampleRate);
    /* A rate change invalidates every phase increment and every effect buffer
       length, and the engine only changes rate while faded out, so silence is
       the correct outcome. */
    synth_patch_voice_clear(state);
}

/* Defined in SynthPatchEngine.c — the render thread's callbacks. */
void synth_patch_voice_note_on(void *opaque, int32_t midiNoteNumber, int32_t velocity);
void synth_patch_voice_note_off(void *opaque, int32_t midiNoteNumber);
void synth_patch_voice_set_pedal(void *opaque, int32_t isDown);
void synth_patch_voice_render(void *opaque, float *monoOut, int32_t frameCount);
void synth_patch_voice_reset(void *opaque);

void synth_patch_voice_init(SynthPatchVoiceState *state,
                            SynthLineVoice *outVoice,
                            double sampleRate,
                            const SynthPatchConfig *config) {
    synth_patch_prepare_tables();

    if (config != NULL) {
        state->config = *config;
    } else {
        synth_patch_config_default(&state->config);
    }
    synth_patch_config_sanitize(&state->config);

    state->ageCounter = 0;
    state->noteCounter = 0;
    state->sustainPedalDown = 0;
    state->controlPhase = 0;
    state->rng = state->config.seed ? state->config.seed : 0x9E3779B97F4A7C15ULL;

    /* The triple buffer's three indices start out distinct and stay that way:
       one belongs to the publisher, one to the render thread, one is parked in
       `liveShared` with no fresh bit. Set before anything can publish. */
    atomic_store_explicit(&state->liveShared, 0, memory_order_relaxed);
    state->liveWriteIndex = 1;
    state->liveReadIndex = 2;
    atomic_store_explicit(&state->liveAdoptions, 0, memory_order_relaxed);
    atomic_store_explicit(&state->liveNoteWrite, 0, memory_order_relaxed);
    atomic_store_explicit(&state->liveNoteRead, 0, memory_order_relaxed);

    synth_patch_voice_update_rate(state, sampleRate);
    synth_patch_voice_clear(state);

    outVoice->state           = state;
    outVoice->prepare         = synth_patch_voice_prepare;
    outVoice->noteOn          = synth_patch_voice_note_on;
    outVoice->noteOff         = synth_patch_voice_note_off;
    outVoice->setSustainPedal = synth_patch_voice_set_pedal;
    outVoice->render          = synth_patch_voice_render;
    outVoice->reset           = synth_patch_voice_reset;
}
