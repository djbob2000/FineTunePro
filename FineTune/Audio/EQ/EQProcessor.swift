// FineTune/Audio/EQ/EQProcessor.swift
import Foundation
import Accelerate

/// RT-safe 10-band graphic EQ processor using vDSP_biquad with optional Treble Exciter.
///
/// Subclass of `BiquadProcessor` — inherits delay buffer management, atomic setup swaps,
/// stereo biquad processing, and NaN safety. This class adds EQ-specific settings
/// management, coefficient computation, and non-linear Treble Exciter processing.
final class EQProcessor: BiquadProcessor, @unchecked Sendable {

    /// Currently applied EQ settings (needed for sample rate recalculation)
    private var _currentSettings: EQSettings?

    /// Crossover & Exciter Filter States (RT-Safe)
    private nonisolated(unsafe) var _hpL = BiquadState()
    private nonisolated(unsafe) var _hpR = BiquadState()
    private nonisolated(unsafe) var _hpPostL = BiquadState()
    private nonisolated(unsafe) var _hpPostR = BiquadState()
    private nonisolated(unsafe) var _hfEnvelope: Float = 0.0

    private var _currentCrossoverFrequency: Double = 1500.0

    /// Read-only access to current settings
    var currentSettings: EQSettings? { _currentSettings }

    init(sampleRate: Double) {
        super.init(
            sampleRate: sampleRate,
            maxSections: EQSettings.bandCount,
            category: "EQProcessor",
            initiallyEnabled: true
        )
        updateCrossoverCoefficients(frequency: 1500.0)
        // Initialize with flat EQ
        updateSettings(EQSettings.flat)
    }

    // MARK: - Settings Update

    /// Update EQ settings (call from main thread).
    func updateSettings(_ settings: EQSettings) {
        setEnabled(settings.isEnabled)
        let oldFreq = _currentSettings?.trebleExciterFrequency ?? 1500.0
        _currentSettings = settings

        if settings.trebleExciterFrequency != oldFreq {
            updateCrossoverCoefficients(frequency: settings.trebleExciterFrequency)
        }

        let coefficients = BiquadMath.coefficientsForAllBands(
            gains: settings.clampedGains,
            sampleRate: sampleRate
        )

        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(EQSettings.bandCount))
        }

        swapSetup(newSetup)
    }

    // MARK: - BiquadProcessor Overrides

    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        guard let settings = _currentSettings else { return nil }
        let coefficients = BiquadMath.coefficientsForAllBands(
            gains: settings.clampedGains,
            sampleRate: sampleRate
        )
        return (coefficients, EQSettings.bandCount)
    }

    override func updateSampleRate(_ newRate: Double) {
        super.updateSampleRate(newRate)
        updateCrossoverCoefficients()
    }

    override func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        // 1. Process linear 10-band graphic EQ biquads first
        super.process(input: input, output: output, frameCount: frameCount)

        guard isEnabled, let settings = _currentSettings, settings.trebleExciterWet > 0.0 else {
            return
        }

        let highDrive = settings.trebleExciterWet

        // 2. Apply Treble Exciter processing (Stereo Interleaved)
        for frame in 0..<frameCount {
            let idxL = frame * 2
            let idxR = frame * 2 + 1

            let xL = output[idxL]
            let xR = output[idxR]

            // HPF split at crossover frequency (default 1000 Hz)
            let highL = _hpL.process(xL)
            let highR = _hpR.process(xR)

            // Sibilant Tamer: envelope follower on high frequencies
            let hfInstant = max(abs(highL), abs(highR))
            if hfInstant > _hfEnvelope {
                _hfEnvelope = _hfEnvelope * 0.85 + hfInstant * 0.15
            } else {
                _hfEnvelope = _hfEnvelope * 0.998
            }

            let sibilantDucking = 1.0 / (1.0 + max(0.0, _hfEnvelope - 0.20) * 2.5)
            let effectiveWet = highDrive * sibilantDucking

            // Treble excitation: Studio-grade Asymmetric Harmonics (Triode/Tape saturation)
            // Input signal highL/highR is processed at nominal unity gain (no 16x clipping distortion)
            let harmHighL = generateTrebleHarmonics(highL)
            let harmHighR = generateTrebleHarmonics(highR)

            // Post-HPF cleans up DC offset and sub-cutoff intermodulation difference products
            let cleanHarmHighL = _hpPostL.process(harmHighL)
            let cleanHarmHighR = _hpPostR.process(harmHighR)

            // Sum Dry + Pure Treble Harmonics scaled by effective Wet Mix
            output[idxL] = xL + (cleanHarmHighL * effectiveWet)
            output[idxR] = xR + (cleanHarmHighR * effectiveWet)
        }
    }

    private func updateCrossoverCoefficients(frequency: Double? = nil) {
        let freq = frequency ?? _currentSettings?.trebleExciterFrequency ?? 1500.0
        _currentCrossoverFrequency = freq
        let hpCoeffs = BiquadMath.highPassCoefficients(frequency: freq, q: 0.707, sampleRate: sampleRate)
        let hpPostCoeffs = BiquadMath.highPassCoefficients(frequency: freq, q: 0.707, sampleRate: sampleRate)

        _hpL.updateCoefficients(b0: hpCoeffs[0], b1: hpCoeffs[1], b2: hpCoeffs[2], a1: hpCoeffs[3], a2: hpCoeffs[4])
        _hpR.updateCoefficients(b0: hpCoeffs[0], b1: hpCoeffs[1], b2: hpCoeffs[2], a1: hpCoeffs[3], a2: hpCoeffs[4])
        _hpPostL.updateCoefficients(b0: hpPostCoeffs[0], b1: hpPostCoeffs[1], b2: hpPostCoeffs[2], a1: hpPostCoeffs[3], a2: hpPostCoeffs[4])
        _hpPostR.updateCoefficients(b0: hpPostCoeffs[0], b1: hpPostCoeffs[1], b2: hpPostCoeffs[2], a1: hpPostCoeffs[3], a2: hpPostCoeffs[4])

        _hpL.reset()
        _hpR.reset()
        _hpPostL.reset()
        _hpPostR.reset()
    }

    @inline(__always)
    private func generateTrebleHarmonics(_ u: Float) -> Float {
        // Studio-grade gentle asymmetric harmonic generation (La Petite Excite style):
        // Models single-ended triode / tape saturation with strict monotonicity and zero-crossing smoothness:
        // - Positive half: gentle soft compression u / (1 + 1.0 * u), synthesizing warm 2nd and 3rd harmonics
        // - Negative half: milder curvature u / (1 - 0.3 * u), breaking waveform symmetry cleanly
        // - f'(0) = 1.0 from both sides -> zero crossover distortion or derivative kinks
        // - Strictly monotonic -> zero full-wave rectification, zero octave fuzz
        // - Pure harmonic component (u - shaped) with zero fundamental boost
        if u >= 0.0 {
            let shaped = u / (1.0 + 1.0 * u)
            return u - shaped
        } else {
            let shaped = u / (1.0 - 0.3 * u)
            return u - shaped
        }
    }
}
