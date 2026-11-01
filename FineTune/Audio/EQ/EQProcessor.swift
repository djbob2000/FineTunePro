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

    private var _currentCrossoverFrequency: Double = 3000.0

    /// Read-only access to current settings
    var currentSettings: EQSettings? { _currentSettings }

    init(sampleRate: Double) {
        super.init(
            sampleRate: sampleRate,
            maxSections: EQSettings.bandCount,
            category: "EQProcessor",
            initiallyEnabled: true
        )
        updateCrossoverCoefficients(frequency: 3000.0)
        // Initialize with flat EQ
        updateSettings(EQSettings.flat)
    }

    // MARK: - Settings Update

    /// Update EQ settings (call from main thread).
    func updateSettings(_ settings: EQSettings) {
        setEnabled(settings.isEnabled)
        let oldFreq = _currentSettings?.trebleExciterFrequency ?? 3000.0
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

            let sibilantDucking = 1.0 / (1.0 + max(0.0, _hfEnvelope - 0.30) * 2.5)
            let effectiveDrive = highDrive * sibilantDucking

            // Treble excitation: Pure Harmonic Exciter (Fundamental Subtraction, zero phase cancellation)
            // Drive directly scales high-frequency band into smooth asymmetric saturator
            let drivenHighL = highL * effectiveDrive
            let drivenHighR = highR * effectiveDrive
            let harmHighL = generateTrebleHarmonics(drivenHighL)
            let harmHighR = generateTrebleHarmonics(drivenHighR)

            // Post-HPF cleans up DC offset and sub-cutoff intermodulation difference products
            let cleanHarmHighL = _hpPostL.process(harmHighL)
            let cleanHarmHighR = _hpPostR.process(harmHighR)

            // Sum Dry + Pure Treble Harmonics directly
            output[idxL] = xL + cleanHarmHighL
            output[idxR] = xR + cleanHarmHighR
        }
    }

    private func updateCrossoverCoefficients(frequency: Double? = nil) {
        let freq = frequency ?? _currentSettings?.trebleExciterFrequency ?? 3000.0
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
        // Pure Harmonic Exciter with Fundamental Subtraction (h(u) = u - f(u)):
        // Asymmetric smooth saturation models vintage tube / diode exciter non-linearity:
        // - Positive swing saturates at +1.0 (softer knee, rich 2nd and 3rd harmonics)
        // - Negative swing saturates at -2.0 (firmer knee, preserves negative transient depth)
        // - C2 continuous at u = 0 (h(0)=0, h'(0)=0, h''(0)=0) eliminating zero-crossing clicks/fuzz
        // - Strictly monotonic (no full-wave rectification or octave buzzing)
        // - Generates warm 2nd harmonic sheen and crisp 3rd harmonic air
        if u > 0.0 {
            let s = u / sqrt(1.0 + u * u)
            return u - s
        } else {
            let v = u * 0.5
            let s = u / sqrt(1.0 + v * v)
            return u - s
        }
    }
}
