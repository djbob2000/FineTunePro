import Foundation
import Accelerate

/// RT-safe hybrid loudness compensation: a four-section bass curve plus harmonic exciters.
///
/// The existing volume-dependent curve uses a low shelf and low-mid bell; treble lift
/// comes from the exciter. At full listening volume compensation is bypassed.
/// A global preamp reserves headroom for the realized cascade and the exciter wet mix.
/// Digital attenuation upstream supplies headroom; hardware device volume does not.
/// Filter gains retain their original shape. The final limiter guards upstream boost,
/// filter transients and the tap volume ramp during control changes.
///
/// Subclass of `BiquadProcessor` — inherits atomic setup swaps, stereo biquad processing,
/// delay buffer management, and NaN safety. Follows the same pattern as `EQProcessor`.
final class LoudnessCompensator: BiquadProcessor, @unchecked Sendable {

    // MARK: - Configuration

    /// Four-section topology chosen to approximate the ISO-derived loudness target with
    /// Fixed shelf filter topology for loudness compensation.
    private enum LoudnessFilterKind {
        case lowShelf
        case highShelf
    }

    private struct LoudnessFilterDefinition {
        let kind: LoudnessFilterKind
        let frequency: Double
        let q: Double
    }

    private static let filterDefinitions: [LoudnessFilterDefinition] = [
        .init(kind: .lowShelf, frequency: 80, q: 0.707),
        .init(kind: .highShelf, frequency: 6000, q: 0.707)
    ]
    static let bandFrequencies = filterDefinitions.map(\.frequency)
    static let bandCount = filterDefinitions.count

    private static let fitGridPointCount = 96
    private static let fitIterationCount = 3

    // MARK: - State

    /// Reference phon level used for the last coefficient computation.
    private var _currentReferencePhon: Double = ISO226Contours.defaultReferencePhon
    /// System volume used for the last coefficient computation.
    private var _currentSystemVolume: Float = 1.0
    /// Digital volume used for the last coefficient computation.
    private var _currentDigitalVolume: Float = 1.0
    /// Gain scale used for the last coefficient computation.
    private var _currentGainScale: Float = 1.0
    /// Crossover frequency for low-frequency band (Hz).
    private var _bassCrossoverFrequency: Double = 70.0
    /// Upper cutoff frequency for bass harmonics post-LPF (Hz).
    private var _bassPostLPFFrequency: Double = 200.0
    /// Corner frequency for high-frequency shelf (Hz) - 6000 Hz industry standard (RME, Yamaha, ISO 226).
    private var _trebleCrossoverFrequency: Double = 6000.0
    /// Treble gain scale (amount) for high-shelf boost.
    private var _trebleGainScale: Float = 1.0
    /// Maximum DB for the target curve.
    private var _currentMaxDB: Double = -30.0
    /// Bass exciter wet amount (0.0 to 4.0, locked to 1.0).
    private var _currentBassExciterWet: Float = 1.0
    /// Bass linear EQ amount (0.0 to 1.0).
    private var _currentBassLinearWet: Float = 1.0

    // Crossover Filter States (RT-Safe)
    private nonisolated(unsafe) var _lpL = BiquadState()
    private nonisolated(unsafe) var _lpR = BiquadState()
    private nonisolated(unsafe) var _lowPostHPFL = BiquadState()
    private nonisolated(unsafe) var _lowPostHPFR = BiquadState()

    private nonisolated(unsafe) var _lowExciterWet: Float = 0.0
    private nonisolated(unsafe) var _highExciterWet: Float = 0.0
    private nonisolated(unsafe) var _bassEQ0DB: Double = 0.0
    private nonisolated(unsafe) var _preampGain: Float = 1.0
    /// Cached gain budget; digital-volume-only updates need no coefficient rebuild.
    private var _peakGainDB: Double = 0.0
    var lowExciterWet: Float { _lowExciterWet }
    var highExciterWet: Float { _highExciterWet }

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
    /// Rebuilds the hybrid curve when its controls change. Digital-gain-only changes
    /// always refresh the preamp, without rebuilding the biquad cascade.
    ///
    /// - Important: **Main thread only.** This method mutates `_eqSetup` and `_isEnabled`
    ///   which the RT audio callback reads via `nonisolated(unsafe)`. Calling from any other
    ///   thread creates a data race. Not annotated `@MainActor` because `BiquadProcessor`
    ///   is not actor-isolated and test call sites run on arbitrary Swift Testing threads.
    func updateForVolume(_ systemVolume: Float, digitalVolume: Float = 1.0, referencePhon: Double = 0.0, maxDB: Double = -30.0, gainScale: Float = 1.0, bassCrossoverFrequency: Double = 70.0, bassPostLPFFrequency: Double = 200.0, trebleCrossoverFrequency: Double = 6000.0, trebleGainScale: Float = 1.0, bassExciterWet: Float = 1.0, bassLinearWet: Float = 1.0) {
        let curveChanged = systemVolume != _currentSystemVolume
            || referencePhon != _currentReferencePhon
            || gainScale != _currentGainScale || maxDB != _currentMaxDB
            || bassCrossoverFrequency != _bassCrossoverFrequency
            || bassPostLPFFrequency != _bassPostLPFFrequency
            || trebleCrossoverFrequency != _trebleCrossoverFrequency
            || trebleGainScale != _trebleGainScale
            || bassExciterWet != _currentBassExciterWet || bassLinearWet != _currentBassLinearWet
        _currentDigitalVolume = digitalVolume
        if isEnabled && !curveChanged {
            updatePreamp()
            return
        }

        var crossoverChanged = false
        if _bassCrossoverFrequency != bassCrossoverFrequency {
            _bassCrossoverFrequency = bassCrossoverFrequency
            crossoverChanged = true
        }
        if _bassPostLPFFrequency != bassPostLPFFrequency {
            _bassPostLPFFrequency = bassPostLPFFrequency
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
        
        _currentReferencePhon = referencePhon
        _currentSystemVolume = systemVolume
        _currentGainScale = gainScale
        _currentMaxDB = maxDB
        _currentBassExciterWet = bassExciterWet
        _currentBassLinearWet = bassLinearWet

        let gains = computeBandGains()
        updateHeadroom(gains: gains)

        // Bypass when all gains are negligible (near reference level) and exciter is off
        let allNegligible = gains.allSatisfy { abs($0) < 0.1 } && _lowExciterWet == 0.0
        if allNegligible {
            setEnabled(false)
            swapSetup(nil)
            _peakGainDB = 0
            _preampGain = 1
            return
        }

        let coefficients = Self.coefficientsForBands(gains: gains, trebleFrequency: _trebleCrossoverFrequency, sampleRate: sampleRate)
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
    var testBassEQ0DB: Double { _bassEQ0DB }
    var testPreampGain: Float { _preampGain }
    #endif

    // MARK: - Coefficient Computation

    /// The same hybrid curve is used for control updates and sample-rate changes.
    private func computeBandGains() -> [Float] {
        let volume = max(0, min(1, Double(_currentSystemVolume)))
        let volumeDB = 40.0 * (volume - 1.0)
        let maxDB = (_currentMaxDB >= -40 && _currentMaxDB <= -20) ? _currentMaxDB : -30
        let amount = pow(min(1, max(0, -volumeDB / abs(maxDB))), 1.8)
        let bassScale = max(0, Double(_currentGainScale))
        let linearWet = max(0, min(1, Double(_currentBassLinearWet)))
        let bassAmount = amount * bassScale * linearWet
        _bassEQ0DB = 10 * bassAmount

        // Low exciter parallel wet mix:
        // Scaled by 0.50 * amount * bassScale (at 1.0 knob = -12 dB mix, at 4.0 knob = 0 dB mix at max compensation).
        let bassHarmonicsEnabled = _currentBassExciterWet > 0
        _lowExciterWet = bassHarmonicsEnabled ? Float(Double(_currentBassExciterWet) * 0.50 * Double(amount) * bassScale) : 0

        // High-frequency Loudness compensation:
        // Clean +3.0 dB High-Shelf boost at 6.0 kHz according to ISO 226 equal-loudness contours,
        // dynamically scaled by volume level and loudness gain scale.
        let trebleEQDB = 3.0 * amount * bassScale
        _highExciterWet = Float(trebleEQDB)

        return [Float(_bassEQ0DB), Float(trebleEQDB)]
    }

    private func updateHeadroom(gains: [Float]) {
        let response = Self.realizedResponseDB(sectionGains: gains.map(Double.init), trebleFrequency: _trebleCrossoverFrequency, sampleRate: sampleRate)
        let peak = zip(Self.fitGridFrequencies(), response)
            .filter { $0.0 < sampleRate / 2 }
            .map { $0.1 }.max() ?? 0

        // Headroom budget: realized linear EQ shelf response + parallel exciter boost.
        // At max compensation (lowWet = 0.50), the exciter adds up to +2.92 dB (20 * log10(1 + 0.8 * 0.50)).
        // Multiplied by the 0.6 broadband headroom budget factor, this reserves exactly 1.75 dB (~1.74 dB)
        // of clean preamp attenuation to prevent low-end bloat and inter-sample peaks.
        let exciterPeakDB = _lowExciterWet > 0 ? 20.0 * log10(1.0 + 0.80 * Double(_lowExciterWet)) : 0.0
        _peakGainDB = max(0.0, peak) + exciterPeakDB
        updatePreamp()
    }

    private func updatePreamp() {
        // Boost above unity contributes no headroom. It remains the final limiter's job.
        // In real music / pink noise, low frequencies (<110 Hz) contain ~20-30% of total
        // broadband signal power across the 10-octave audible spectrum. Attenuating the entire track
        // 1:1 against a shelf boost causes excessive midrange/vocal attenuation ("midrange ducking").
        // A headroom budget factor of 0.6 matches the broadband RMS power integration ratio
        // (~6 dB cut for +10 dB bass shelf), preserving dynamics while downstream BrickwallLimiter
        // handles rare transient peaks.
        let digital = max(1e-8, min(1, Double(_currentDigitalVolume)))
        let availableDB = -20 * log10(digital)
        let budgetedPeakDB = _peakGainDB * 0.6
        let cutDB = max(0, budgetedPeakDB - availableDB)
        _preampGain = Float(pow(10, -cutDB / 20))
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
    static func coefficientsForBands(gains: [Float], trebleFrequency: Double = 6000.0, sampleRate: Double) -> [Double] {
        guard gains.count == bandCount else {
            return (0..<bandCount).flatMap { _ in [1.0, 0.0, 0.0, 0.0, 0.0] }
        }

        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(bandCount * 5)
        for (index, filter) in filterDefinitions.enumerated() {
            let filterFreq = filter.kind == .highShelf ? trebleFrequency : filter.frequency
            guard filterFreq < sampleRate / 2.0 else {
                allCoeffs.append(contentsOf: [1.0, 0.0, 0.0, 0.0, 0.0])
                continue
            }
            let coeffs: [Double]
            switch filter.kind {
            case .lowShelf:
                coeffs = BiquadMath.lowShelfCoefficients(
                    frequency: filterFreq,
                    gainDB: gains[index],
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .highShelf:
                coeffs = BiquadMath.highShelfCoefficients(
                    frequency: filterFreq,
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
        let gains = computeBandGains()
        updateHeadroom(gains: gains)
        let allNegligible = gains.allSatisfy { abs($0) < 0.1 } && _lowExciterWet == 0.0
        guard !allNegligible else { return nil }
        let coefficients = Self.coefficientsForBands(gains: gains, trebleFrequency: _trebleCrossoverFrequency, sampleRate: sampleRate)
        return (coefficients, Self.bandCount)
    }

    /// RT-safe global attenuation before the linear cascade and harmonic branches.
    override func preProcess(output: UnsafeMutablePointer<Float>, frameCount: Int) {
        var gain = _preampGain
        guard gain != 1 else { return }
        vDSP_vsmul(output, 1, &gain, output, 1, vDSP_Length(frameCount * 2))
    }

    override func updateSampleRate(_ newRate: Double) {
        super.updateSampleRate(newRate)
        updateCrossoverCoefficients()
    }

    override func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        // 1. Process linear loudness biquad filters first (low shelf + high shelf)
        super.process(input: input, output: output, frameCount: frameCount)
        
        let lowWet = _lowExciterWet
        guard isEnabled, lowWet > 0 else { return }

        // Bass harmonic exciter (Stereo Interleaved)
        for frame in 0..<frameCount {
            let idxL = frame * 2
            let idxR = frame * 2 + 1
            
            let xL = output[idxL]
            let xR = output[idxR]
            
            // Bass split at crossover frequency (50–120 Hz, default 70 Hz)
            let lowL = _lpL.process(xL)
            let lowR = _lpR.process(xR)
            
            // Parallel analog gentle asymmetric saturation (La Petite Excite model adapted for LF)
            let satLowL = saturateBass(lowL)
            let satLowR = saturateBass(lowR)
            
            // Post-HPF (20 Hz DC blocker) cleanly strips DC bias without phase cancellation notch
            let cleanSatLowL = _lowPostHPFL.process(satLowL)
            let cleanSatLowR = _lowPostHPFR.process(satLowR)
            
            // Sum 100% clean direct path (already filtered with bass + treble shelf) + parallel saturated bass band
            let outL = xL + (cleanSatLowL * lowWet)
            let outR = xR + (cleanSatLowR * lowWet)
            
            output[idxL] = outL
            output[idxR] = outR
        }
    }

    private func updateCrossoverCoefficients() {
        let lpCoeffs = BiquadMath.lowPassCoefficients(frequency: _bassCrossoverFrequency, q: 0.707, sampleRate: sampleRate)
        let bassPostHPFCoeffs = BiquadMath.highPassCoefficients(frequency: 20.0, q: 0.707, sampleRate: sampleRate)

        _lpL.updateCoefficients(b0: lpCoeffs[0], b1: lpCoeffs[1], b2: lpCoeffs[2], a1: lpCoeffs[3], a2: lpCoeffs[4])
        _lpR.updateCoefficients(b0: lpCoeffs[0], b1: lpCoeffs[1], b2: lpCoeffs[2], a1: lpCoeffs[3], a2: lpCoeffs[4])
        _lowPostHPFL.updateCoefficients(b0: bassPostHPFCoeffs[0], b1: bassPostHPFCoeffs[1], b2: bassPostHPFCoeffs[2], a1: bassPostHPFCoeffs[3], a2: bassPostHPFCoeffs[4])
        _lowPostHPFR.updateCoefficients(b0: bassPostHPFCoeffs[0], b1: bassPostHPFCoeffs[1], b2: bassPostHPFCoeffs[2], a1: bassPostHPFCoeffs[3], a2: bassPostHPFCoeffs[4])

        _lpL.reset()
        _lpR.reset()
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
    private func saturateBass(_ u: Float) -> Float {
        // Studio-grade gentle asymmetric saturation (La Petite Excite / triode tape model adapted for LF):
        // Monotonic function preserving fundamental and adding warm 2nd and 3rd harmonics without rectification or phase artifacts:
        // - Positive half: gentle soft compression u / (1 + 0.6 * u)
        // - Negative half: milder curvature u / (1 - 0.2 * u)
        // - f'(0) = 1.0 from both sides -> smooth zero crossing, zero derivative discontinuity
        // - Monotonic -> zero full-wave rectification, zero harsh octave fuzz
        if u >= 0.0 {
            return u / (1.0 + 0.6 * u)
        } else {
            return u / (1.0 - 0.2 * u)
        }
    }

    static func basisResponsesDB(sampleRate: Double) -> [[Double]] {
        let fitFrequencies = fitGridFrequencies()
        return filterDefinitions.map { filter in
            let coefficients: [Double]
            switch filter.kind {
            case .lowShelf:
                coefficients = BiquadMath.lowShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: Float(1.0),
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .highShelf:
                coefficients = BiquadMath.highShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: Float(1.0),
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

    static func realizedResponseDB(sectionGains: [Double], trebleFrequency: Double = 1500.0, sampleRate: Double) -> [Double] {
        let coefficients = coefficientsForBands(gains: sectionGains.map(Float.init), trebleFrequency: trebleFrequency, sampleRate: sampleRate)
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
    var b0: Float = 1.0, b1: Float = 0.0, b2: Float = 0.0
    var a1: Float = 0.0, a2: Float = 0.0
    
    var x1: Float = 0.0, x2: Float = 0.0
    var y1: Float = 0.0, y2: Float = 0.0
    
    mutating func updateCoefficients(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0)
        self.b1 = Float(b1)
        self.b2 = Float(b2)
        self.a1 = Float(a1)
        self.a2 = Float(a2)
    }
    
    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
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
