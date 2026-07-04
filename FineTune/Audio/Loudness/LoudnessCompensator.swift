import Foundation
import Accelerate

/// RT-safe loudness compensation processor based on ISO 226:2023 equal-loudness contours.
///
/// Applies frequency-dependent gain to counteract the human ear's reduced sensitivity
/// to bass and treble at low listening levels. At the reference level (~80 phon),
/// compensation is flat (bypassed). At lower levels, the contour difference is
/// normalized around 1 kHz so only spectral balance is corrected. The app then fits
/// that target curve with a low-cost four-section shelf/bell cascade.
/// Headroom is computed from the realized cascade response and subtracted from all
/// band gains so the cascade peak never exceeds 0 dBFS.
///
/// Subclass of `BiquadProcessor` — inherits atomic setup swaps, stereo biquad processing,
/// delay buffer management, and NaN safety. Follows the same pattern as `EQProcessor`.
final class LoudnessCompensator: BiquadProcessor, @unchecked Sendable {

    // MARK: - Configuration

    /// Four-section topology chosen to approximate the ISO-derived loudness target with
    /// minimal runtime DSP cost: low shelf, low-mid bell, upper-mid bell, high shelf.
    private enum LoudnessFilterKind {
        case lowShelf
        case peaking
        case highShelf
    }

    private struct LoudnessFilterDefinition {
        let kind: LoudnessFilterKind
        let frequency: Double
        let q: Double
    }

    private static let filterDefinitions: [LoudnessFilterDefinition] = [
        .init(kind: .lowShelf, frequency: 80, q: 0.707),
        .init(kind: .peaking, frequency: 180, q: 0.7),
        .init(kind: .peaking, frequency: 3200, q: 0.7),
        .init(kind: .highShelf, frequency: 10000, q: 0.85),
    ]
    static let bandFrequencies = filterDefinitions.map(\.frequency)
    static let bandCount = filterDefinitions.count

    private static let fitGridPointCount = 96
    private static let fitIterationCount = 3

    // MARK: - State

    /// Phon level used for the last coefficient computation.
    private var _currentPhon: Double = ISO226Contours.defaultReferencePhon
    /// Reference phon level used for the last coefficient computation.
    private var _currentReferencePhon: Double = ISO226Contours.defaultReferencePhon
    /// System volume used for the last coefficient computation.
    private var _currentSystemVolume: Float = 1.0
    /// Digital volume used for the last coefficient computation.
    private var _currentDigitalVolume: Float = 1.0
    /// Gain scale used for the last coefficient computation.
    private var _currentGainScale: Float = 1.0
    /// Mode used for the last coefficient computation.
    private var _currentMode: LoudnessMode? = nil
    /// Crossover frequency for low-frequency band (Hz).
    private var _bassCrossoverFrequency: Double = 67.0
    /// Crossover frequency for high-frequency band (Hz).
    private var _trebleCrossoverFrequency: Double = 3000.0
    /// Treble gain scale (amount) for the exciter.
    private var _trebleGainScale: Float = 1.0
    /// Maximum DB for the target curve.
    private var _currentMaxDB: Double = -30.0
    /// Bass exciter wet amount (0.0 to 1.0).
    private var _currentBassExciterWet: Float = 0.20
    /// Bass linear EQ amount (0.0 to 1.0).
    private var _currentBassLinearWet: Float = 1.0

    // Crossover Filter States (RT-Safe)
    private nonisolated(unsafe) var _lpL = BiquadState()
    private nonisolated(unsafe) var _lpR = BiquadState()
    private nonisolated(unsafe) var _hpL = BiquadState()
    private nonisolated(unsafe) var _hpR = BiquadState()
    private nonisolated(unsafe) var _hpPostL = BiquadState()
    private nonisolated(unsafe) var _hpPostR = BiquadState()
    private nonisolated(unsafe) var _lowPostHPFL = BiquadState()
    private nonisolated(unsafe) var _lowPostHPFR = BiquadState()

    private nonisolated(unsafe) var _lowExciterWet: Float = 0.0
    private nonisolated(unsafe) var _highExciterWet: Float = 0.0
    private nonisolated(unsafe) var _outputGainCorrection: Float = 1.0
    private nonisolated(unsafe) var _hfEnvelope: Float = 0.0
    var lowExciterWet: Float { _lowExciterWet }
    var highExciterWet: Float { _highExciterWet }
    var outputGainCorrection: Float { _outputGainCorrection }

    // MARK: - Init

    init(sampleRate: Double) {
        super.init(
            sampleRate: sampleRate,
            maxSections: Self.bandCount,
            category: "LoudnessCompensator",
            initiallyEnabled: false
        )
        updateCrossoverCoefficients()
    }

    // MARK: - Volume Update

    /// Update compensation coefficients for a new system volume level.
    ///
    /// Converts volume → estimated phon, skips recomputation if phon changed by less
    /// than 1.0 (coalesces rapid slider drags), bypasses processor when at reference level.
    ///
    /// - Important: **Main thread only.** This method mutates `_eqSetup` and `_isEnabled`
    ///   which the RT audio callback reads via `nonisolated(unsafe)`. Calling from any other
    ///   thread creates a data race. Not annotated `@MainActor` because `BiquadProcessor`
    ///   is not actor-isolated and test call sites run on arbitrary Swift Testing threads.
    func updateForVolume(_ systemVolume: Float, digitalVolume: Float = 1.0, referencePhon: Double = 0.0, maxDB: Double = -30.0, gainScale: Float = 1.0, mode: LoudnessMode = .modern, bassCrossoverFrequency: Double = 70.0, trebleCrossoverFrequency: Double = 3000.0, trebleGainScale: Float = 1.0, bassExciterWet: Float = 0.20, bassLinearWet: Float = 1.0) {
        // Volume-based phon estimation (primary — tracks user's intended listening level,
        // matching Dolby Volume Modeler / THX Loudness Plus architecture).
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: systemVolume, referencePhon: referencePhon)

        // Coalesce rapid updates, but never skip a disabled processor because re-enabling
        // loudness from the UI must rebuild coefficients immediately even at the same volume.
        guard !isEnabled || _currentMode != mode || _bassCrossoverFrequency != bassCrossoverFrequency || _trebleCrossoverFrequency != trebleCrossoverFrequency || _trebleGainScale != trebleGainScale || abs(phon - _currentPhon) >= 1.0 || abs(referencePhon - _currentReferencePhon) >= 0.1 || abs(digitalVolume - _currentDigitalVolume) >= 0.05 || abs(gainScale - _currentGainScale) >= 0.01 || _currentMaxDB != maxDB || _currentBassExciterWet != bassExciterWet || _currentBassLinearWet != bassLinearWet else { return }
        
        var crossoverChanged = false
        if _bassCrossoverFrequency != bassCrossoverFrequency {
            _bassCrossoverFrequency = bassCrossoverFrequency
            crossoverChanged = true
        }
        if _trebleCrossoverFrequency != trebleCrossoverFrequency {
            _trebleCrossoverFrequency = trebleCrossoverFrequency
            crossoverChanged = true
        }
        if crossoverChanged {
            updateCrossoverCoefficients()
        }
        _trebleGainScale = trebleGainScale
        
        _currentPhon = phon
        _currentReferencePhon = referencePhon
        _currentSystemVolume = systemVolume
        _currentDigitalVolume = digitalVolume
        _currentGainScale = gainScale
        _currentMode = mode
        _currentMaxDB = maxDB
        _currentBassExciterWet = bassExciterWet
        _currentBassLinearWet = bassLinearWet

        // Calculate raw ISO-226 gains
        let rawGains = Self.fittedSectionGains(forPhon: phon, referencePhon: referencePhon, amount: 1.0, sampleRate: sampleRate)
        let scaledGains = [
            rawGains[0] * gainScale,
            rawGains[1] * gainScale,
            rawGains[2] * _trebleGainScale,
            rawGains[3] * _trebleGainScale
        ]

        // RME ADI-2 Style Dual-Point Decibel-Linear Loudness Transition (needed for treble)
        let linearVol = max(Double(systemVolume), 0.0001)
        let volDB = 40.0 * (linearVol - 1.0) // 100% -> 0 dB, 50% -> -20 dB, 0% -> -40 dB
        let mDB = (maxDB >= -40.0 && maxDB <= -20.0) ? maxDB : -30.0
        let K_linear = min(1.0, max(0.0, -volDB / abs(mDB)))
        let K = pow(K_linear, 1.8)

        let eqGains: [Double]
        if mode == .classic {
            eqGains = scaledGains.map(Double.init)
            _lowExciterWet = 0.0
            _highExciterWet = 0.0
            _outputGainCorrection = 1.0
        } else {
            // Clean ISO 226 low-frequency EQ curve (+5.0 dB shelf / +1.0 dB peak at max K)
            let bassEQ0 = 5.0 * Double(bassLinearWet) * K
            let bassEQ1 = 1.0 * Double(bassLinearWet) * K
            
            eqGains = [
                bassEQ0,
                bassEQ1,
                Double(scaledGains[2] * Float(K)),
                Double(scaledGains[3] * Float(K))
            ]

            // Multi-harmonic exciter capped at 30% wet mix, linearly scaled by bassExciterWet slider (0..1)
            let lowBoostDB = 12.0 * Double(gainScale) * K
            let lowLinear = pow(10.0, lowBoostDB / 20.0)
            let maxHarmonicWet: Float = 0.30
            let exciterRatio = min(1.0, Float((lowLinear - 1.0) / 2.981))
            _lowExciterWet = maxHarmonicWet * bassExciterWet * exciterRatio

            // High exciter and treble boost capped at +3.0 dB
            let highBoostDB = 3.0 * Double(_trebleGainScale) * K
            let highLinear = pow(10.0, highBoostDB / 20.0)
            _highExciterWet = Float(highLinear - 1.0) * 0.05
            
            // Dynamic headroom correction factor
            let maxPotentialHarmonicPeak = 1.0 + (0.35 * Double(_lowExciterWet)) + (0.4 * Double(_highExciterWet))
            _outputGainCorrection = Float(1.0 / max(1.0, maxPotentialHarmonicPeak))
        }

        // Calculate realized response and headroom based on actual EQ gains
        let realized = Self.realizedResponseDB(sectionGains: eqGains, sampleRate: sampleRate)
        let frequencies = Self.fitGridFrequencies()
        var peakDB = 0.0
        for (index, freq) in frequencies.enumerated() {
            if freq >= 30.0 {
                peakDB = max(peakDB, realized[index])
            }
        }
        
        let linearVolume = max(Double(digitalVolume), 1e-4)
        let volumeAttenuationDB = -20.0 * log10(linearVolume)
        
        // In modern mode, we do NOT subtract headroom from the EQ gains to allow a standard bass boost behavior
        // (the downstream SoftLimiter handles any digital clipping).
        // In classic mode, we preserve the 0 dBFS peak constraint.
        let headroomToSubtract = mode == .classic ? max(0.0, peakDB - volumeAttenuationDB) : 0.0

        let gains = eqGains.map { Float($0) - Float(headroomToSubtract) }

        // Bypass when all gains are negligible (near reference level) and exciter is off
        let allNegligible = gains.allSatisfy { abs($0) < 0.1 } && _lowExciterWet == 0.0 && _highExciterWet == 0.0
        if allNegligible {
            setEnabled(false)
            swapSetup(nil)
            return
        }

        let coefficients = Self.coefficientsForBands(gains: gains, sampleRate: sampleRate)
        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(Self.bandCount))
        }
        swapSetup(newSetup)
        setEnabled(true)
    }

    #if DEBUG
    var testHighExciterWet: Float { _highExciterWet }
    var testLowExciterWet: Float { _lowExciterWet }
    var testBassLinearWet: Float { _currentBassLinearWet }
    #endif

    // MARK: - Coefficient Computation

    /// Compute per-section gains (dB) for the fixed four-filter loudness topology.
    ///
    /// Post-processes the fitted gains by computing the realized cascade response,
    /// finding its peak (the "headroom" needed), and subtracting that peak from all
    /// band gains so the cascade never clips.
    private func computeBandGains(phon: Double, referencePhon: Double, digitalVolume: Float, gainScale: Float = 1.0, amount: Double = 0.5) -> [Float] {
        let gains = Self.fittedSectionGains(forPhon: phon, referencePhon: referencePhon, amount: amount, sampleRate: sampleRate)
        let scaledGains = gains.map { $0 * gainScale }
        let realized = Self.realizedResponseDB(sectionGains: scaledGains.map(Double.init), sampleRate: sampleRate)
        
        // Exclude infrasound frequencies below 30 Hz from the headroom calculation
        // to maximize dynamic range, since most output devices cannot reproduce them.
        let frequencies = Self.fitGridFrequencies()
        var peakDB = 0.0
        for (index, freq) in frequencies.enumerated() {
            if freq >= 30.0 {
                peakDB = max(peakDB, realized[index])
            }
        }
        
        // Calculate digital headroom from actual digital volume attenuation in the pipeline
        let linearVolume = max(Double(digitalVolume), 1e-4)
        let volumeAttenuationDB = -20.0 * log10(linearVolume)
        
        // Dynamic headroom subtraction (only subtract boost exceeding the digital attenuation)
        let headroomToSubtract = max(0.0, peakDB - volumeAttenuationDB)
        
        return scaledGains.map { $0 - Float(headroomToSubtract) }
    }

    /// Fit the fixed four-section loudness topology to the ISO-derived target curve.
    static func fittedSectionGains(forPhon phon: Double, referencePhon: Double = ISO226Contours.defaultReferencePhon, amount: Double = 0.5, sampleRate: Double) -> [Float] {
        let targetCurve = targetCurveDB(forPhon: phon, referencePhon: referencePhon, amount: amount)
        let basisResponses = basisResponsesDB(sampleRate: sampleRate)
        let gramMatrix = gramMatrix(for: basisResponses)

        var sectionGains = [Double](repeating: 0.0, count: bandCount)
        for _ in 0..<fitIterationCount {
            let realized = realizedResponseDB(sectionGains: sectionGains, sampleRate: sampleRate)
            let residual = zip(targetCurve, realized).map { target, fitted in
                target - fitted
            }
            let rhs = basisResponses.map { basis in
                zip(basis, residual).reduce(0.0) { partial, pair in
                    partial + pair.0 * pair.1
                }
            }
            guard let delta = solveLinearSystem(gramMatrix, rhs: rhs) else { break }
            for index in 0..<bandCount {
                sectionGains[index] += delta[index]
            }
        }

        return sectionGains.map(Float.init)
    }

    /// Build the flat coefficient array for `vDSP_biquad_CreateSetup`.
    static func coefficientsForBands(gains: [Float], sampleRate: Double) -> [Double] {
        guard gains.count == bandCount else {
            return (0..<bandCount).flatMap { _ in [1.0, 0.0, 0.0, 0.0, 0.0] }
        }

        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(bandCount * 5)
        for (index, filter) in filterDefinitions.enumerated() {
            guard filter.frequency < sampleRate / 2.0 else {
                allCoeffs.append(contentsOf: [1.0, 0.0, 0.0, 0.0, 0.0])
                continue
            }
            let coeffs: [Double]
            switch filter.kind {
            case .lowShelf:
                coeffs = BiquadMath.lowShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: gains[index],
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .peaking:
                coeffs = BiquadMath.peakingEQCoefficients(
                    frequency: filter.frequency,
                    gainDB: gains[index],
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .highShelf:
                coeffs = BiquadMath.highShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: gains[index],
                    q: filter.q,
                    sampleRate: sampleRate
                )
            }
            allCoeffs.append(contentsOf: coeffs)
        }
        return allCoeffs
    }

    // MARK: - BiquadProcessor Overrides

    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        let gains = computeBandGains(phon: _currentPhon, referencePhon: _currentReferencePhon, digitalVolume: _currentDigitalVolume, gainScale: _currentGainScale, amount: 1.0)
        let allNegligible = gains.allSatisfy { abs($0) < 0.1 } && _lowExciterWet == 0.0 && _highExciterWet == 0.0
        guard !allNegligible else { return nil }
        let coefficients = Self.coefficientsForBands(gains: gains, sampleRate: sampleRate)
        return (coefficients, Self.bandCount)
    }

    override func updateSampleRate(_ newRate: Double) {
        super.updateSampleRate(newRate)
        updateCrossoverCoefficients()
    }

    override func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        // 1. Process linear loudness biquad filters first
        super.process(input: input, output: output, frameCount: frameCount)
        
        let lowWet = _lowExciterWet
        let highWet = _highExciterWet
        let correction = _outputGainCorrection
        
        guard isEnabled, (lowWet > 0.0 || highWet > 0.0) else {
            // Apply linear correction headroom even if exciter is off
            if correction != 1.0 {
                var scale = correction
                vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(frameCount * 2))
            }
            return
        }
        
        // Crossover and non-linear processing (Stereo Interleaved)
        for frame in 0..<frameCount {
            let idxL = frame * 2
            let idxR = frame * 2 + 1
            
            let xL = output[idxL]
            let xR = output[idxR]
            
            // Crossover split
            let lowL = _lpL.process(xL)
            let lowR = _lpR.process(xR)
            
            let highL = _hpL.process(xL)
            let highR = _hpR.process(xR)
            
            // Fast De-Esser / Sibilant Tamer: track peak envelope of high frequencies (>3 kHz)
            let hfInstant = max(abs(highL), abs(highR))
            // Fast attack (~1 ms), medium release (~30 ms) envelope follower
            if hfInstant > _hfEnvelope {
                _hfEnvelope = _hfEnvelope * 0.8 + hfInstant * 0.2
            } else {
                _hfEnvelope = _hfEnvelope * 0.998
            }
            
            // Smoothly duck high exciter wet gain on sharp sibilant bursts ('S', 'TS', 'SH') above 0.25 peak
            let sibilantDucking = 1.0 / (1.0 + max(0.0, _hfEnvelope - 0.25) * 3.0)
            let effectiveHighWet = highWet * sibilantDucking
            
            // Saturations
            let satLowL = softClipLow(lowL)
            let satLowR = softClipLow(lowR)
            
            let satHighL = softClipHigh(highL)
            let satHighR = softClipHigh(highR)
            
            // Post-HPF to keep only harmonics above crossover and block DC
            let filteredSatLowL = _lowPostHPFL.process(satLowL)
            let filteredSatLowR = _lowPostHPFR.process(satLowR)
            
            // HPF post-processing to clean up low/mid harmonics from ВЧ
            let filteredSatHighL = _hpPostL.process(satHighL)
            let filteredSatHighR = _hpPostR.process(satHighR)
            
            // Sum Dry + Wet, and apply gain correction factor to guarantee peak <= 0 dBFS
            output[idxL] = (xL + (filteredSatLowL * lowWet) + (filteredSatHighL * effectiveHighWet)) * correction
            output[idxR] = (xR + (filteredSatLowR * lowWet) + (filteredSatHighR * effectiveHighWet)) * correction
        }
    }

    private func updateCrossoverCoefficients() {
        let lpCoeffs = BiquadMath.lowPassCoefficients(frequency: _bassCrossoverFrequency, q: 0.707, sampleRate: sampleRate)
        let hpCoeffs = BiquadMath.highPassCoefficients(frequency: _trebleCrossoverFrequency, q: 0.707, sampleRate: sampleRate)
        let lpPostCoeffs = BiquadMath.highPassCoefficients(frequency: 25.0, q: 0.707, sampleRate: sampleRate)

        _lpL.updateCoefficients(b0: lpCoeffs[0], b1: lpCoeffs[1], b2: lpCoeffs[2], a1: lpCoeffs[3], a2: lpCoeffs[4])
        _lpR.updateCoefficients(b0: lpCoeffs[0], b1: lpCoeffs[1], b2: lpCoeffs[2], a1: lpCoeffs[3], a2: lpCoeffs[4])
        _hpL.updateCoefficients(b0: hpCoeffs[0], b1: hpCoeffs[1], b2: hpCoeffs[2], a1: hpCoeffs[3], a2: hpCoeffs[4])
        _hpR.updateCoefficients(b0: hpCoeffs[0], b1: hpCoeffs[1], b2: hpCoeffs[2], a1: hpCoeffs[3], a2: hpCoeffs[4])
        _hpPostL.updateCoefficients(b0: hpCoeffs[0], b1: hpCoeffs[1], b2: hpCoeffs[2], a1: hpCoeffs[3], a2: hpCoeffs[4])
        _hpPostR.updateCoefficients(b0: hpCoeffs[0], b1: hpCoeffs[1], b2: hpCoeffs[2], a1: hpCoeffs[3], a2: hpCoeffs[4])
        
        _lowPostHPFL.updateCoefficients(b0: lpPostCoeffs[0], b1: lpPostCoeffs[1], b2: lpPostCoeffs[2], a1: lpPostCoeffs[3], a2: lpPostCoeffs[4])
        _lowPostHPFR.updateCoefficients(b0: lpPostCoeffs[0], b1: lpPostCoeffs[1], b2: lpPostCoeffs[2], a1: lpPostCoeffs[3], a2: lpPostCoeffs[4])

        _lpL.reset()
        _lpR.reset()
        _hpL.reset()
        _hpR.reset()
        _hpPostL.reset()
        _hpPostR.reset()
        _lowPostHPFL.reset()
        _lowPostHPFR.reset()
    }

    private static func cascadeMagnitude(coefficients: [Double], sectionCount: Int, omega: Double) -> Double {
        let cosW = cos(omega)
        let sinW = sin(omega)
        let cos2W = cos(2.0 * omega)
        let sin2W = sin(2.0 * omega)

        var magnitude = 1.0
        for offset in stride(from: 0, to: sectionCount * 5, by: 5) {
            let numeratorReal = coefficients[offset] + coefficients[offset + 1] * cosW + coefficients[offset + 2] * cos2W
            let numeratorImag = -(coefficients[offset + 1] * sinW + coefficients[offset + 2] * sin2W)
            let denominatorReal = 1.0 + coefficients[offset + 3] * cosW + coefficients[offset + 4] * cos2W
            let denominatorImag = -(coefficients[offset + 3] * sinW + coefficients[offset + 4] * sin2W)

            let numeratorMagnitudeSquared = numeratorReal * numeratorReal + numeratorImag * numeratorImag
            let denominatorMagnitudeSquared = denominatorReal * denominatorReal + denominatorImag * denominatorImag
            magnitude *= sqrt(numeratorMagnitudeSquared / denominatorMagnitudeSquared)
        }

        return magnitude
    }

    private static func targetCurveDB(forPhon phon: Double, referencePhon: Double, amount: Double = 0.5) -> [Double] {
        let compensation = ISO226Contours.compensationGains(atPhon: phon, referencePhon: referencePhon, amount: amount)
        let fitFrequencies = fitGridFrequencies()
        return fitFrequencies.map { frequency in
            ISO226Contours.interpolateCompensation(compensation, atFrequency: frequency)
        }
    }

    @inline(__always)
    private func softClipLow(_ x: Float) -> Float {
        // Multi-harmonic saturator generating 2nd, 3rd, 4th, and 5th harmonics
        let c = max(-1.0, min(1.0, x * 1.2))
        let c2 = c * c
        let c3 = c2 * c
        let c4 = c3 * c
        let c5 = c4 * c
        return c - 0.25 * c2 - 0.15 * c3 + 0.10 * c4 - 0.05 * c5
    }

    @inline(__always)
    private func softClipHigh(_ x: Float) -> Float {
        // Multi-harmonic HF exciter (2nd, 3rd, 4th, and 5th harmonics)
        // Even harmonics (2nd, 4th) add silky warmth and air; odd harmonics (3rd, 5th) are
        // heavily attenuated to prevent harsh sibilance ("зиканье/песок").
        let c = max(-1.0, min(1.0, x * 1.1))
        let c2 = c * c
        let c3 = c2 * c
        let c4 = c3 * c
        let c5 = c4 * c
        return c - 0.20 * c2 - 0.06 * c3 + 0.08 * c4 - 0.02 * c5
    }

    static func basisResponsesDB(sampleRate: Double) -> [[Double]] {
        let fitFrequencies = fitGridFrequencies()
        return filterDefinitions.map { filter in
            let coefficients: [Double]
            switch filter.kind {
            case .lowShelf:
                coefficients = BiquadMath.lowShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: 1.0,
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .peaking:
                coefficients = BiquadMath.peakingEQCoefficients(
                    frequency: filter.frequency,
                    gainDB: 1.0,
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .highShelf:
                coefficients = BiquadMath.highShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: 1.0,
                    q: filter.q,
                    sampleRate: sampleRate
                )
            }

            return fitFrequencies.map { frequency in
                let omega = 2.0 * Double.pi * frequency / sampleRate
                return 20.0 * log10(cascadeMagnitude(coefficients: coefficients, sectionCount: 1, omega: omega))
            }
        }
    }

    static func realizedResponseDB(sectionGains: [Double], sampleRate: Double) -> [Double] {
        let coefficients = coefficientsForBands(gains: sectionGains.map(Float.init), sampleRate: sampleRate)
        return fitGridFrequencies().map { frequency in
            let omega = 2.0 * Double.pi * frequency / sampleRate
            return 20.0 * log10(cascadeMagnitude(coefficients: coefficients, sectionCount: bandCount, omega: omega))
        }
    }

    static func fitGridFrequencies() -> [Double] {
        (0..<fitGridPointCount).map { index in
            20.0 * pow(20_000.0 / 20.0, Double(index) / Double(fitGridPointCount - 1))
        }
    }

    static func gramMatrix(for basisResponses: [[Double]]) -> [[Double]] {
        (0..<bandCount).map { row in
            (0..<bandCount).map { column in
                zip(basisResponses[row], basisResponses[column]).reduce(0.0) { partial, pair in
                    partial + pair.0 * pair.1
                }
            }
        }
    }

    static func solveLinearSystem(_ matrix: [[Double]], rhs: [Double]) -> [Double]? {
        var augmented = matrix.enumerated().map { index, row in
            row + [rhs[index]]
        }
        let size = rhs.count

        for pivotIndex in 0..<size {
            let bestPivotIndex = (pivotIndex..<size).max { lhs, rhsIndex in
                abs(augmented[lhs][pivotIndex]) < abs(augmented[rhsIndex][pivotIndex])
            } ?? pivotIndex

            guard abs(augmented[bestPivotIndex][pivotIndex]) > 1e-12 else {
                return nil
            }

            if bestPivotIndex != pivotIndex {
                augmented.swapAt(bestPivotIndex, pivotIndex)
            }

            let pivot = augmented[pivotIndex][pivotIndex]
            for column in pivotIndex...size {
                augmented[pivotIndex][column] /= pivot
            }

            for row in 0..<size where row != pivotIndex {
                let factor = augmented[row][pivotIndex]
                guard factor != 0 else { continue }
                for column in pivotIndex...size {
                    augmented[row][column] -= factor * augmented[pivotIndex][column]
                }
            }
        }

        return (0..<size).map { augmented[$0][size] }
    }

}

// MARK: - RT-Safe Biquad State Struct

struct BiquadState {
    var b0: Double = 1.0, b1: Double = 0.0, b2: Double = 0.0
    var a1: Double = 0.0, a2: Double = 0.0
    
    var x1: Float = 0.0, x2: Float = 0.0
    var y1: Float = 0.0, y2: Float = 0.0
    
    mutating func updateCoefficients(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }
    
    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = Float(b0) * x + Float(b1) * x1 + Float(b2) * x2 - Float(a1) * y1 - Float(a2) * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
    
    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }
}
