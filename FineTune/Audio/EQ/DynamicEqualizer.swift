import Foundation
import Accelerate
import os

struct DynamicEqualizerBiquadState {
    var x1: Float = 0
    var x2: Float = 0
    var y1: Float = 0
    var y2: Float = 0
    
    mutating func reset() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
    }
}

struct BiquadCoefficients {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0
}

struct StereoBiquad {
    var coeffs = BiquadCoefficients()
    var stateL = DynamicEqualizerBiquadState()
    var stateR = DynamicEqualizerBiquadState()
    
    mutating func reset() {
        stateL.reset()
        stateR.reset()
    }
    
    mutating func process(left xL: Float, right xR: Float) -> (left: Float, right: Float) {
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
    private static let debugGainsStorage = RealTimeSafeDebugGains()
    static var debugGains: [Float] {
        get {
            debugGainsStorage.read()
        }
        set {
            debugGainsStorage.write(newValue)
        }
    }
    
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
    
    // Last gains for which peaking coefficients were actually computed.
    private var lastComputedGains: [Float] = [0, 0, 0, 0, 0]
    
    // Minimum gain change (dB) to trigger coefficient recompute.
    private static let coeffRecomputeThreshold: Float = 0.05
    
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
        for i in 0..<5 {
            lastComputedGains[i] = currentGains[i]
        }
    }
    
    func reset() {
        for i in 0..<5 {
            bandpassFilters[i].reset()
            peakingFilters[i].reset()
            envelopes[i] = 0.0
            currentGains[i] = 0.0
            lastComputedGains[i] = 0.0
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
            b0: Float(b0 / a0),
            b1: Float(b1 / a0),
            b2: Float(b2 / a0),
            a1: Float(a1 / a0),
            a2: Float(a2 / a0)
        )
    }
    
    func peakingCoefficients(frequency: Double, gainDB: Float, sampleRate: Double) -> BiquadCoefficients {
        let coeffs = BiquadMath.peakingEQCoefficients(frequency: frequency, gainDB: gainDB, q: 1.0, sampleRate: sampleRate)
        return BiquadCoefficients(
            b0: Float(coeffs[0]),
            b1: Float(coeffs[1]),
            b2: Float(coeffs[2]),
            a1: Float(coeffs[3]),
            a2: Float(coeffs[4])
        )
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
        // Extract filters to stack variables to avoid copy-on-write and subscript check overhead
        var bp0 = bandpassFilters[0]
        var bp1 = bandpassFilters[1]
        var bp2 = bandpassFilters[2]
        var bp3 = bandpassFilters[3]
        var bp4 = bandpassFilters[4]
        
        for frame in 0..<frameCount {
            let idx = frame * 2
            let xL = input[idx]
            let xR = input[idx + 1]
            
            // Unroll loop for 5 bands
            let out0 = bp0.process(left: xL, right: xR)
            envelopes[0] = alpha * envelopes[0] + oneMinusAlpha * max(abs(out0.left), abs(out0.right))
            
            let out1 = bp1.process(left: xL, right: xR)
            envelopes[1] = alpha * envelopes[1] + oneMinusAlpha * max(abs(out1.left), abs(out1.right))
            
            let out2 = bp2.process(left: xL, right: xR)
            envelopes[2] = alpha * envelopes[2] + oneMinusAlpha * max(abs(out2.left), abs(out2.right))
            
            let out3 = bp3.process(left: xL, right: xR)
            envelopes[3] = alpha * envelopes[3] + oneMinusAlpha * max(abs(out3.left), abs(out3.right))
            
            let out4 = bp4.process(left: xL, right: xR)
            envelopes[4] = alpha * envelopes[4] + oneMinusAlpha * max(abs(out4.left), abs(out4.right))
        }
        
        bandpassFilters[0] = bp0
        bandpassFilters[1] = bp1
        bandpassFilters[2] = bp2
        bandpassFilters[3] = bp3
        bandpassFilters[4] = bp4
        
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
            
            // Only recompute coefficients when gain changed meaningfully
            if abs(currentGains[i] - lastComputedGains[i]) >= Self.coeffRecomputeThreshold {
                peakingFilters[i].coeffs = peakingCoefficients(
                    frequency: Self.frequencies[i],
                    gainDB: currentGains[i],
                    sampleRate: sampleRate
                )
                lastComputedGains[i] = currentGains[i]
            }
        }
        
        // Update shared debug gains for the UI
        Self.debugGains = currentGains
        
        // 4. Process the peaking filter cascade on the input/output buffer
        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
        }
        
        // Calculate makeup gain to ensure the maximum peak gain of the EQ does not exceed 0 dB
        let maxGain = currentGains.max() ?? 0.0
        let makeupGain = maxGain > 0.0 ? Float(pow(10.0, -maxGain / 20.0)) : 1.0
        
        // Extract peaking filters to stack variables
        var pk0 = peakingFilters[0]
        var pk1 = peakingFilters[1]
        var pk2 = peakingFilters[2]
        var pk3 = peakingFilters[3]
        var pk4 = peakingFilters[4]
        
        for frame in 0..<frameCount {
            let idx = frame * 2
            let xL = output[idx]
            let xR = output[idx + 1]
            
            // Process peaking filters in unrolled cascade
            let out0 = pk0.process(left: xL, right: xR)
            let out1 = pk1.process(left: out0.left, right: out0.right)
            let out2 = pk2.process(left: out1.left, right: out1.right)
            let out3 = pk3.process(left: out2.left, right: out2.right)
            let out4 = pk4.process(left: out3.left, right: out3.right)
            
            output[idx] = out4.left * makeupGain
            output[idx + 1] = out4.right * makeupGain
        }
        
        peakingFilters[0] = pk0
        peakingFilters[1] = pk1
        peakingFilters[2] = pk2
        peakingFilters[3] = pk3
        peakingFilters[4] = pk4
    }
}

fileprivate final class RealTimeSafeDebugGains: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var gains = [Float](repeating: 0, count: 5)
    
    func read() -> [Float] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return gains
    }
    
    func write(_ newGains: [Float]) {
        if os_unfair_lock_trylock(&lock) {
            gains = newGains
            os_unfair_lock_unlock(&lock)
        }
    }
}
