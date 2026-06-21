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
    static let frequencies: [Double] = [38.0, 230.0, 4464.0, 5628.0, 17740.0]
    
    // Relative targets (StereoTool)
    static let targets: [Float] = [-2.0, 2.0, 1.0, -4.0, -8.0]
    
    // Silence threshold
    static let silenceThresholdDB: Float = -20.0
    
    // Strength (amount of correction, default 0.5)
    var strength: Float = 0.5
    
    // Max cut/boost limits
    var maxBoostDB: Float = 6.0
    var maxCutDB: Float = -6.0
    
    // Speed of cut/boost in dB/sec
    var maxChangeRate: Float = 25.0
    
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
        
        // Find active bands above silence threshold
        var activeIndices: [Int] = []
        var activeSum: Float = 0.0
        for i in 0..<5 {
            if envDBs[i] >= Self.silenceThresholdDB {
                activeIndices.append(i)
                activeSum += envDBs[i]
            }
        }
        
        var targetGains: [Float] = [0, 0, 0, 0, 0]
        if !activeIndices.isEmpty {
            let avgDB = activeSum / Float(activeIndices.count)
            for i in 0..<5 {
                if activeIndices.contains(i) {
                    let relativeLevel = envDBs[i] - avgDB
                    let diff = Self.targets[i] - relativeLevel
                    let target = diff * strength
                    targetGains[i] = max(maxCutDB, min(maxBoostDB, target))
                } else {
                    targetGains[i] = 0.0
                }
            }
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
        
        // 3. Ramp current gains towards target gains
        let dt = Double(frameCount) / sampleRate
        let maxChange = maxChangeRate * Float(dt)
        
        for i in 0..<5 {
            let diff = targetGains[i] - currentGains[i]
            if diff > maxChange {
                currentGains[i] += maxChange
            } else if diff < -maxChange {
                currentGains[i] -= maxChange
            } else {
                currentGains[i] = targetGains[i]
            }
            
            // Recompute peaking filter coefficients with currentGains[i]
            peakingFilters[i].coeffs = peakingCoefficients(
                frequency: Self.frequencies[i],
                gainDB: currentGains[i],
                sampleRate: sampleRate
            )
        }
        
        // 4. Process the peaking filter cascade on the input/output buffer
        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
        }
        
        for frame in 0..<frameCount {
            let idx = frame * 2
            var xL = Double(output[idx])
            var xR = Double(output[idx + 1])
            
            for i in 0..<5 {
                let out = peakingFilters[i].process(left: xL, right: xR)
                xL = out.left
                xR = out.right
            }
            
            output[idx] = Float(xL)
            output[idx + 1] = Float(xR)
        }
    }
}
