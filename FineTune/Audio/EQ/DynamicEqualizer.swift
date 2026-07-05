import Foundation
import Accelerate

struct BiquadState {
    var x1: Double = 0
    var x2: Double = 0
    var y1: Double = 0
    var y2: Double = 0
    
    mutating func reset() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
    }
}

struct BiquadCoefficients {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0
}

struct StereoBiquad {
    var coeffs = BiquadCoefficients()
    var stateL = BiquadState()
    var stateR = BiquadState()
    
    mutating func reset() {
        stateL.reset()
        stateR.reset()
    }
    
    mutating func process(left xL: Double, right xR: Double) -> (left: Double, right: Double) {
        let yL = coeffs.b0 * xL + coeffs.b1 * stateL.x1 + coeffs.b2 * stateL.x2 - coeffs.a1 * stateL.y1 - coeffs.a2 * stateL.y2
        stateL.x2 = stateL.x1
        stateL.x1 = xL
        stateL.y2 = stateL.y1
        stateL.y1 = yL
        
        let yR = coeffs.b0 * xR + coeffs.b1 * stateR.x1 + coeffs.b2 * stateR.x2 - coeffs.a1 * stateR.y1 - coeffs.a2 * stateR.y2
        stateR.x2 = stateR.x1
        stateR.x1 = xR
        stateR.y2 = stateR.y1
        stateR.y1 = yR
        
        return (yL, yR)
    }
}

final class DynamicEqualizer: @unchecked Sendable {
    // 5 bands frequencies
    static let frequencies: [Double] = [68.0, 350.0, 1410.0, 4520.0, 9540.0]
    
    // Live debug gains shared with the UI
    nonisolated(unsafe) static var debugGains: [Float] = [0, 0, 0, 0, 0]
    
    // Relative targets (Harman In-Ear 2019)
    static let targets: [Float] = [8.5, 1.0, 3.5, 2.5, -2.0]
    
    // Silence threshold
    static let silenceThresholdDB: Float = -50.0
    
    // Strength (amount of correction, default 0.5)
    var strength: Float = 0.5
    
    // Max cut/boost limits per band
    var maxBoostDBs: [Float] = [6.0, 5.0, 4.0, 3.0, 3.0]
    var maxCutDBs: [Float] = [-6.0, -6.0, -6.0, -6.0, -6.0]
    
    // Response speed and protection configurations
    var adjustmentTime: Double = 1.3
    var jumpAcceleration: Double = 1.5
    var loudBandThreshold: Float = 3.0
    
    var sampleRate: Double = 48000.0
    
    // 5 bandpass filters for Left and Right channels
    var bandpassFilters: [StereoBiquad] = []
    
    // 5 peaking EQ filters for Left and Right channels in cascade
    var peakingFilters: [StereoBiquad] = []
    
    // 5 envelope values (internal for unit testing)
    var envelopes: [Float] = [0, 0, 0, 0, 0]
    
    // 5 current dynamic gains (internal for unit testing)
    var currentGains: [Float] = [0, 0, 0, 0, 0]
    
    var isEnabled: Bool = true
    
    init(sampleRate: Double = 48000.0) {
        self.sampleRate = sampleRate
        setupFilters()
    }
    
    private var envelopeAlpha: Float {
        Float(exp(-1.0 / (0.150 * sampleRate)))
    }
    
    func setupFilters() {
        bandpassFilters = (0..<5).map { i in
            var filter = StereoBiquad()
            filter.coeffs = bandpassCoefficients(frequency: Self.frequencies[i], sampleRate: sampleRate)
            return filter
        }
        
        peakingFilters = (0..<5).map { i in
            var filter = StereoBiquad()
            filter.coeffs = peakingCoefficients(frequency: Self.frequencies[i], gainDB: currentGains[i], sampleRate: sampleRate)
            return filter
        }
    }
    
    func reset() {
        for i in 0..<5 {
            bandpassFilters[i].reset()
            peakingFilters[i].reset()
            envelopes[i] = 0.0
            currentGains[i] = 0.0
        }
        setupFilters()
    }
    
    func updateSampleRate(_ newRate: Double) {
        guard newRate != sampleRate else { return }
        sampleRate = newRate
        reset()
    }
    
    private func bandpassCoefficients(frequency: Double, sampleRate: Double) -> BiquadCoefficients {
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        // Let's use Q = 1.0 for bandpass splitters
        let q = 1.0
        let alpha = sinW / (2.0 * q)
        
        let b0 = alpha
        let b1 = 0.0
        let b2 = -alpha
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosW
        let a2 = 1.0 - alpha
        
        return BiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }
    
    private func peakingCoefficients(frequency: Double, gainDB: Float, sampleRate: Double) -> BiquadCoefficients {
        let coeffs = BiquadMath.peakingEQCoefficients(frequency: frequency, gainDB: gainDB, q: 1.0, sampleRate: sampleRate)
        return BiquadCoefficients(b0: coeffs[0], b1: coeffs[1], b2: coeffs[2], a1: coeffs[3], a2: coeffs[4])
    }
    
    func calculateTargetGains() -> [Float] {
        // Convert envelopes to dB
        let envDBs = envelopes.map { env -> Float in
            if env <= 1e-10 { return -200.0 }
            return 20.0 * log10(env)
        }
        
        let silenceThreshold = Self.silenceThresholdDB
        let nominalLevel: Float = -20.0
        let levelRange = nominalLevel - silenceThreshold
        
        // Calculate per-band continuous weight (allow it to exceed 1.0 for high volume levels)
        let weights = envDBs.map { db -> Float in
            max(0.0, min(1.5, (db - silenceThreshold) / levelRange))
        }
        
        // Calculate weighted average DB
        let weightedSum = zip(envDBs, weights).reduce(0.0) { $0 + $1.0 * $1.1 }
        let weightSum = weights.reduce(0.0, +)
        let avgDB = weightSum > 0.0 ? weightedSum / weightSum : silenceThreshold
        
        var targetGains = [Float](repeating: 0.0, count: 5)
        for i in 0..<5 {
            let relativeLevel = envDBs[i] - avgDB
            let diff = Self.targets[i] - relativeLevel
            let target = diff * strength
            
            // Scale target gain and clamp limits by the weight
            let limitScale = weights[i]
            targetGains[i] = max(maxCutDBs[i] * limitScale, min(maxBoostDBs[i] * limitScale, target * limitScale))
        }
        return targetGains
    }
    
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard isEnabled else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
            }
            return
        }
        
        let alpha = self.envelopeAlpha
        let oneMinusAlpha = 1.0 - alpha
        
        // 1. Run per-frame processing to update bandpass filters and envelope followers
        for frame in 0..<frameCount {
            let idx = frame * 2
            let xL = Double(input[idx])
            let xR = Double(input[idx + 1])
            
            for i in 0..<5 {
                let bp = bandpassFilters[i].process(left: xL, right: xR)
                let rect = Float(max(abs(bp.left), abs(bp.right)))
                envelopes[i] = alpha * envelopes[i] + oneMinusAlpha * rect
            }
        }
        
        // 2. Recalculate target gains based on envelopes
        let targetGains = calculateTargetGains()
        
        // 3. Smooth current gains towards target gains using exponential smoothing
        let dt = Double(frameCount) / sampleRate
        
        for i in 0..<5 {
            var target = targetGains[i]
            let diff = target - currentGains[i]
            
            // Loud band protection: Reduce boost at sudden jumps above loudBandThreshold dB
            if diff > loudBandThreshold {
                target = currentGains[i] + loudBandThreshold
            }
            
            // Sudden jump acceleration (use 2.0 dB as the jump detection threshold)
            let isSuddenJump = abs(diff) > 2.0
            let tau = isSuddenJump ? (adjustmentTime / jumpAcceleration) : adjustmentTime
            
            let beta = Float(exp(-dt / tau))
            currentGains[i] = beta * currentGains[i] + (1.0 - beta) * target
            
            // Recompute peaking filter coefficients with currentGains[i]
            peakingFilters[i].coeffs = peakingCoefficients(
                frequency: Self.frequencies[i],
                gainDB: currentGains[i],
                sampleRate: sampleRate
            )
        }
        
        // Update shared debug gains for the UI
        Self.debugGains = currentGains
        
        // 4. Process the peaking filter cascade on the input/output buffer
        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
        }
        
        // Calculate makeup gain to ensure the maximum peak gain of the EQ does not exceed 0 dB
        let maxGain = currentGains.max() ?? 0.0
        let makeupGain = maxGain > 0.0 ? Double(pow(10.0, -maxGain / 20.0)) : 1.0
        
        for frame in 0..<frameCount {
            let idx = frame * 2
            var xL = Double(output[idx])
            var xR = Double(output[idx + 1])
            
            for i in 0..<5 {
                let out = peakingFilters[i].process(left: xL, right: xR)
                xL = out.left
                xR = out.right
            }
            
            output[idx] = Float(xL * makeupGain)
            output[idx + 1] = Float(xR * makeupGain)
        }
    }
}
