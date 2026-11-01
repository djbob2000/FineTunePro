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

    private var _currentCrossoverFrequency: Double = 1000.0

    /// Read-only access to current settings
    var currentSettings: EQSettings? { _currentSettings }

    init(sampleRate: Double) {
        super.init(
            sampleRate: sampleRate,
            maxSections: EQSettings.bandCount,
            category: "EQProcessor",
            initiallyEnabled: true
        )
        updateCrossoverCoefficients(frequency: 1000.0)
        // Initialize with flat EQ
        updateSettings(EQSettings.flat)
    }

    // MARK: - Settings Update

    /// Update EQ settings (call from main thread).
    func updateSettings(_ settings: EQSettings) {
        setEnabled(settings.isEnabled)
        let oldFreq = _currentSettings?.trebleExciterFrequency ?? 1000.0
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

            let sibilantDucking = 1.0 / (1.0 + max(0.0, _hfEnvelope - 0.25) * 2.0)
            let effectiveDrive = highDrive * sibilantDucking

            // Treble excitation: True Harmonic-Only Exciter (Fundamental Subtraction, zero phase cancellation)
            // Pre-gain 2.5x drives high-frequency band into musical saturation
            let drivenHighL = softKnee(highL * effectiveDrive * 2.5)
            let drivenHighR = softKnee(highR * effectiveDrive * 2.5)
            let harmHighL = generateTrebleHarmonics(drivenHighL)
            let harmHighR = generateTrebleHarmonics(drivenHighR)

            // Post-HPF (1000 Hz) cleans up DC offset and sub-1kHz intermodulation difference products
            let cleanHarmHighL = _hpPostL.process(harmHighL)
            let cleanHarmHighR = _hpPostR.process(harmHighR)

            // Sum Dry + Pure Treble Harmonics directly
            output[idxL] = xL + cleanHarmHighL
            output[idxR] = xR + cleanHarmHighR
        }
    }

    private func updateCrossoverCoefficients(frequency: Double? = nil) {
        let freq = frequency ?? _currentSettings?.trebleExciterFrequency ?? 1000.0
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
    private func softKnee(_ u: Float) -> Float {
        let a = abs(u)
        if a <= 0.8 {
            return u
        }

        let v = (a - 0.8) / 0.2
        let shaped = 0.8 + 0.2 * v / sqrt(1.0 + v * v)
        return u < 0 ? -shaped : shaped
    }

    @inline(__always)
    private func generateTrebleHarmonics(_ u: Float) -> Float {
        // True Harmonic-Only Exciter with fundamental cancellation:
        // Even-harmonic component (+0.80 * u^2) adds brilliant 2nd harmonic (octave-up sheen/air).
        // Pure odd-harmonic component (-0.25 * (u^3 - 0.75 * u)) adds 3rd harmonic edge with 0% fundamental.
        // Positive/negative asymmetry provides warm analog presence.
        let u2 = u * u
        let u3_pure = u2 * u - 0.75 * u
        if u > 0 {
            return 0.80 * u2 - 0.25 * u3_pure
        } else {
            return 0.60 * u2 - 0.15 * u3_pure
        }
    }
}
