// FineTune/Audio/Loudness/PostAgcCompressor.swift

import Foundation

/// Post-AGC dynamics compressor matching the Orban Optimod 5-band mode processing structure.
///
/// Features:
/// 1. **5-Band LR4 Crossover** – Splits audio at 200 Hz, 420 Hz, 1.6 kHz, and 6.2 kHz.
/// 2. **Feedback Compression** – Uses output-level overshoot to calculate gain reduction.
/// 3. **Dynamic Ratio / Knee** – Knee transitions progressively (6 dB knee width); ratio increases
///    dynamically from 1.5:1 to settings.ratio (default 6.0:1) as overshoot grows.
/// 4. **Automatic Release Control (ARC)** – Dual-stage release slows recovery on sustained
///    compression to prevent pumping, while maintaining fast release for transient spikes.
/// 5. **Inter-Band Coupling** – Clamps adjacent band gain differences within ±4.0 dB of the Master band (Band 3).
///
/// **RT-safety contract**: All mutable state is owned exclusively by the real-time
/// audio thread after init. Settings and sample-rate changes are handled by creating
/// a **new** instance on the main thread, atomically swapping the pointer in
/// ProcessTapController, and deferring destruction of the old instance by 500 ms.
final class PostAgcCompressor: @unchecked Sendable {

    // MARK: - Private state (exclusively RT-thread owned after init)

    private let settings: PostAgcCompressorSettings
    private let sampleRate: Float

    final class CompressorBand: @unchecked Sendable {
        let thresholdOffsetDb: Float
        let ratio: Float
        let attackMs: Float
        let releaseMs: Float
        let kneeDb: Float
        let maxReleaseSpeed: Float
        let exponentialRelease: Float
        let sampleRate: Float
        
        // Mutable state (RT thread only)
        var gainReductionDb: Float = 0
        var slowGainReductionDb: Float = 0
        
        // Coefficients
        private var kneeHalfDb: Float = 0
        private var attackCoeff: Float = 0
        private var releaseCoeff: Float = 0
        private var maxReleaseCoeff: Float = 0
        private var slowAttackCoeff: Float = 0
        private var slowReleaseCoeff: Float = 0
        
        init(thresholdOffsetDb: Float, ratio: Float, attackMs: Float, releaseMs: Float, kneeDb: Float, maxReleaseSpeed: Float, exponentialRelease: Float, sampleRate: Float) {
            self.thresholdOffsetDb = thresholdOffsetDb
            self.ratio = ratio
            self.attackMs = attackMs
            self.releaseMs = releaseMs
            self.kneeDb = kneeDb
            self.maxReleaseSpeed = maxReleaseSpeed
            self.exponentialRelease = exponentialRelease
            self.sampleRate = sampleRate
            updateSampleRate(sampleRate)
        }
        
        func updateSampleRate(_ sampleRate: Float) {
            self.kneeHalfDb = kneeDb * 0.5
            let samplePeriodMs: Float = 1000.0 / sampleRate
            let stepMsHop = samplePeriodMs * Float(PostAgcCompressor.hopSize)
            let attackTau = attackMs / 1.966
            self.attackCoeff = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: attackTau, stepMs: stepMsHop)
            self.releaseCoeff = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: releaseMs, stepMs: stepMsHop)
            let maxReleaseSpeed = max(self.maxReleaseSpeed, 0.001)
            self.maxReleaseCoeff = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: releaseMs / maxReleaseSpeed, stepMs: stepMsHop)
            
            // ARC slow-stage coefficients: 100 ms attack, 600 ms release
            self.slowAttackCoeff = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: 100.0, stepMs: stepMsHop)
            self.slowReleaseCoeff = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: 600.0, stepMs: stepMsHop)
        }
        
        func calculateGainReduction(levelDb: Float, globalThresholdDb: Float) -> Float {
            let bandThresholdDb = globalThresholdDb + thresholdOffsetDb
            
            // 1. Feedback estimation of output level
            let estimatedOutputDb = levelDb + gainReductionDb
            let x = estimatedOutputDb - bandThresholdDb
            
            var desiredGrDb: Float = 0.0
            
            // Helper to get progressive feedback ratio/slope based on overshoot depth
            func getFeedbackSlope(forOvershoot ov: Float) -> Float {
                let rMin: Float = 1.5
                let rMax = max(ratio, rMin)
                let maxOvershootRange: Float = 10.0
                let normOvershoot = max(0.0, min(ov / maxOvershootRange, 1.0))
                let dynamicRatio = rMin + (rMax - rMin) * normOvershoot
                return dynamicRatio - 1.0
            }
            
            let xKnee = x + kneeHalfDb
            if xKnee >= kneeDb {
                let xFlat = xKnee - kneeHalfDb
                let slope = getFeedbackSlope(forOvershoot: xFlat)
                desiredGrDb = -slope * xFlat
            } else if xKnee > 0 {
                let slope = getFeedbackSlope(forOvershoot: xKnee)
                desiredGrDb = -slope * (xKnee * xKnee) / (2.0 * max(kneeDb, 1e-6))
            } else {
                desiredGrDb = 0.0
            }
            
            // 2. Dual-stage ARC (Automatic Release Control)
            if desiredGrDb < slowGainReductionDb {
                slowGainReductionDb += slowAttackCoeff * (desiredGrDb - slowGainReductionDb)
            } else {
                slowGainReductionDb += slowReleaseCoeff * (desiredGrDb - slowGainReductionDb)
            }
            
            let currentGr = min(gainReductionDb, -0.01)
            let ratioOfSustained = min(1.0, max(0.0, slowGainReductionDb / currentGr))
            let arcMultiplier = 1.0 - 0.85 * ratioOfSustained
            
            // Apply smoothing to gainReductionDb
            if desiredGrDb < gainReductionDb {
                gainReductionDb += attackCoeff * (desiredGrDb - gainReductionDb)
            } else {
                var adjustedRelease = releaseCoeff * arcMultiplier
                let expRelease = exponentialRelease
                let maxReleaseDb: Float = 12.0
                let normalized = min(abs(gainReductionDb) / maxReleaseDb, 1.0)
                let expFactor = 1.0 - expRelease * (1.0 - normalized * normalized)
                adjustedRelease = adjustedRelease * max(expFactor, 0.01)
                adjustedRelease = min(adjustedRelease, maxReleaseCoeff)
                gainReductionDb += adjustedRelease * (desiredGrDb - gainReductionDb)
            }
            
            if gainReductionDb > 0 { gainReductionDb = 0 }
            return gainReductionDb
        }
    }

    let band1: CompressorBand
    let band2: CompressorBand
    let band3: CompressorBand
    let band4: CompressorBand
    let band5: CompressorBand

    private var crossover200Hz: [LinkwitzRileyCrossover2] = []
    private var crossover6200Hz: [LinkwitzRileyCrossover2] = []
    private var crossover1600Hz: [LinkwitzRileyCrossover2] = []
    private var crossover420Hz: [LinkwitzRileyCrossover2] = []

    // All-pass filters to align phase of the crossover bands
    private var apB1_6200Hz: [LinkwitzRileyCrossover2] = []
    private var apB1_1600Hz: [LinkwitzRileyCrossover2] = []
    private var apB1_420Hz: [LinkwitzRileyCrossover2] = []
    
    private var apB4_420Hz: [LinkwitzRileyCrossover2] = []
    
    private var apB5_1600Hz: [LinkwitzRileyCrossover2] = []
    private var apB5_420Hz: [LinkwitzRileyCrossover2] = []

    // MARK: - Init

    init(settings: PostAgcCompressorSettings, sampleRate: Float) {
        self.settings = settings
        self.sampleRate = sampleRate

        // Band 1: Sub-bass (<200 Hz), threshold offset -8.0 dB
        self.band1 = CompressorBand(
            thresholdOffsetDb: -8.0,
            ratio: 3.0,
            attackMs: 25.0,
            releaseMs: 300.0,
            kneeDb: settings.kneeDb,
            maxReleaseSpeed: settings.maxReleaseSpeed,
            exponentialRelease: settings.exponentialRelease,
            sampleRate: sampleRate
        )
        // Band 2: Mid-bass (200 - 420 Hz), threshold offset -4.0 dB
        self.band2 = CompressorBand(
            thresholdOffsetDb: -4.0,
            ratio: 3.0,
            attackMs: 20.0,
            releaseMs: 200.0,
            kneeDb: settings.kneeDb,
            maxReleaseSpeed: settings.maxReleaseSpeed,
            exponentialRelease: settings.exponentialRelease,
            sampleRate: sampleRate
        )
        // Band 3: Mid (420 Hz - 1.6 kHz) - Master Anchor Band
        self.band3 = CompressorBand(
            thresholdOffsetDb: 0.0,
            ratio: settings.ratio,
            attackMs: settings.attackMs,
            releaseMs: settings.releaseMs,
            kneeDb: settings.kneeDb,
            maxReleaseSpeed: settings.maxReleaseSpeed,
            exponentialRelease: settings.exponentialRelease,
            sampleRate: sampleRate
        )
        // Band 4: High-mid (1.6 kHz - 6.2 kHz)
        self.band4 = CompressorBand(
            thresholdOffsetDb: 0.0,
            ratio: settings.ratio,
            attackMs: settings.attackMs,
            releaseMs: settings.releaseMs,
            kneeDb: settings.kneeDb,
            maxReleaseSpeed: settings.maxReleaseSpeed,
            exponentialRelease: settings.exponentialRelease,
            sampleRate: sampleRate
        )
        // Band 5: Highs (>6.2 kHz), threshold offset +2.0 dB
        self.band5 = CompressorBand(
            thresholdOffsetDb: 2.0,
            ratio: 4.0,
            attackMs: 5.0,
            releaseMs: 50.0,
            kneeDb: settings.kneeDb,
            maxReleaseSpeed: settings.maxReleaseSpeed,
            exponentialRelease: settings.exponentialRelease,
            sampleRate: sampleRate
        )

        // Pre-allocate crossover arrays and buffers for 2 channels
        self.crossover200Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 200.0, sampleRate: Double(sampleRate)) }
        self.crossover6200Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 6200.0, sampleRate: Double(sampleRate)) }
        self.crossover1600Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 1600.0, sampleRate: Double(sampleRate)) }
        self.crossover420Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 420.0, sampleRate: Double(sampleRate)) }

        self.apB1_6200Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 6200.0, sampleRate: Double(sampleRate)) }
        self.apB1_1600Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 1600.0, sampleRate: Double(sampleRate)) }
        self.apB1_420Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 420.0, sampleRate: Double(sampleRate)) }
        
        self.apB4_420Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 420.0, sampleRate: Double(sampleRate)) }
        
        self.apB5_1600Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 1600.0, sampleRate: Double(sampleRate)) }
        self.apB5_420Hz = (0..<2).map { _ in LinkwitzRileyCrossover2(frequency: 420.0, sampleRate: Double(sampleRate)) }

        self.band1Samples = [Float](repeating: 0, count: 2)
        self.band2Samples = [Float](repeating: 0, count: 2)
        self.band3Samples = [Float](repeating: 0, count: 2)
        self.band4Samples = [Float](repeating: 0, count: 2)
        self.band5Samples = [Float](repeating: 0, count: 2)
    }

    // MARK: - Public API

    /// Whether compression is active.
    var isEnabled: Bool { settings.enabled }

    /// The current settings snapshot (read from main thread for creating replacement instances).
    var currentSettings: PostAgcCompressorSettings { settings }

    private var band1Samples: [Float] = []
    private var band2Samples: [Float] = []
    private var band3Samples: [Float] = []
    private var band4Samples: [Float] = []
    private var band5Samples: [Float] = []

    static let hopSize = 32
    private var hopCounter = 0
    private var hopPeak1: Float = 0.0
    private var hopPeak2: Float = 0.0
    private var hopPeak3: Float = 0.0
    private var hopPeak4: Float = 0.0
    private var hopPeak5: Float = 0.0
    
    private var currentGain1: Float = 1.0
    private var currentGain2: Float = 1.0
    private var currentGain3: Float = 1.0
    private var currentGain4: Float = 1.0
    private var currentGain5: Float = 1.0

    /// Process audio from an interleaved input buffer to an interleaved output buffer.
    ///
    /// - Parameters:
    ///   - input:        Interleaved input: `input[f * channelCount + ch]`
    ///   - output:       Interleaved output: `output[f * channelCount + ch]`
    ///   - frameCount:   Number of frames per channel.
    ///   - channelCount: Number of channels. Must be 2 (stereo).
    ///
    /// RT-safe: allocation-free, no logging.
    func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        guard settings.enabled else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * channelCount * MemoryLayout<Float>.size)
            }
            return
        }

        // Narrow API contract to strictly 2 channels (stereo). If channelCount is not 2,
        // bypass and copy input directly to output without performing any heap allocations.
        guard channelCount == 2 else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * channelCount * MemoryLayout<Float>.size)
            }
            return
        }

        let globalThresholdDb = settings.thresholdDb

        for frame in 0..<frameCount {
            let base = frame * channelCount

            for ch in 0..<channelCount {
                var sample = input[base + ch]
                if sample.isNaN {
                    sample = 0.0
                }
                
                // Nested LR4 Crossover split tree:
                // 1. Split at 200 Hz
                let (low200, high200) = crossover200Hz[ch].process(sample)
                
                // 2. Split high200 at 6.2 kHz
                let (low6200, high6200) = crossover6200Hz[ch].process(high200)
                
                // 3. Split low6200 at 1.6 kHz
                let (low1600, high1600) = crossover1600Hz[ch].process(low6200)
                
                // 4. Split low1600 at 420 Hz
                let (low420, high420) = crossover420Hz[ch].process(low1600)
                
                // 5. Apply All-pass filters to align phase of the bands that have fewer crossover splits
                // Band 1 needs all-pass at 6.2 kHz, 1.6 kHz, and 420 Hz
                let (lB1_62, hB1_62) = apB1_6200Hz[ch].process(low200)
                let apB1_62 = lB1_62 + hB1_62
                let (lB1_16, hB1_16) = apB1_1600Hz[ch].process(apB1_62)
                let apB1_16 = lB1_16 + hB1_16
                let (lB1_42, hB1_42) = apB1_420Hz[ch].process(apB1_16)
                band1Samples[ch] = lB1_42 + hB1_42
                
                // Band 2 and Band 3 already went through all 4 frequency splits
                band2Samples[ch] = low420
                band3Samples[ch] = high420
                
                // Band 4 needs all-pass at 420 Hz
                let (lB4_42, hB4_42) = apB4_420Hz[ch].process(high1600)
                band4Samples[ch] = lB4_42 + hB4_42
                
                // Band 5 needs all-pass at 1.6 kHz and 420 Hz
                let (lB5_16, hB5_16) = apB5_1600Hz[ch].process(high6200)
                let apB5_16 = lB5_16 + hB5_16
                let (lB5_42, hB5_42) = apB5_420Hz[ch].process(apB5_16)
                band5Samples[ch] = lB5_42 + hB5_42

                let abs1 = abs(low200)
                let abs2 = abs(low420)
                let abs3 = abs(high420)
                let abs4 = abs(high1600)
                let abs5 = abs(high6200)

                if abs1 > hopPeak1 { hopPeak1 = abs1 }
                if abs2 > hopPeak2 { hopPeak2 = abs2 }
                if abs3 > hopPeak3 { hopPeak3 = abs3 }
                if abs4 > hopPeak4 { hopPeak4 = abs4 }
                if abs5 > hopPeak5 { hopPeak5 = abs5 }
            }

            hopCounter += 1
            if hopCounter >= Self.hopSize {
                let level1Db = LoudnessEqualizerMath.linearToDb(hopPeak1)
                let level2Db = LoudnessEqualizerMath.linearToDb(hopPeak2)
                let level3Db = LoudnessEqualizerMath.linearToDb(hopPeak3)
                let level4Db = LoudnessEqualizerMath.linearToDb(hopPeak4)
                let level5Db = LoudnessEqualizerMath.linearToDb(hopPeak5)

                // 1. Calculate raw feedback gain reductions
                _ = band1.calculateGainReduction(levelDb: level1Db, globalThresholdDb: globalThresholdDb)
                _ = band2.calculateGainReduction(levelDb: level2Db, globalThresholdDb: globalThresholdDb)
                _ = band3.calculateGainReduction(levelDb: level3Db, globalThresholdDb: globalThresholdDb)
                _ = band4.calculateGainReduction(levelDb: level4Db, globalThresholdDb: globalThresholdDb)
                _ = band5.calculateGainReduction(levelDb: level5Db, globalThresholdDb: globalThresholdDb)

                // 2. Inter-Band Coupling (adjacent bands tied within ±4.0 dB of Master B3)
                let masterGainDb = band3.gainReductionDb
                
                let b2Min = masterGainDb - 4.0
                let b2Max = masterGainDb + 4.0
                band2.gainReductionDb = max(b2Min, min(b2Max, band2.gainReductionDb))
                if band2.gainReductionDb > 0 { band2.gainReductionDb = 0 }
                
                let b1Min = band2.gainReductionDb - 4.0
                let b1Max = band2.gainReductionDb + 4.0
                band1.gainReductionDb = max(b1Min, min(b1Max, band1.gainReductionDb))
                if band1.gainReductionDb > 0 { band1.gainReductionDb = 0 }
                
                let b4Min = masterGainDb - 4.0
                let b4Max = masterGainDb + 4.0
                band4.gainReductionDb = max(b4Min, min(b4Max, band4.gainReductionDb))
                if band4.gainReductionDb > 0 { band4.gainReductionDb = 0 }
                
                let b5Min = band4.gainReductionDb - 4.0
                let b5Max = band4.gainReductionDb + 4.0
                band5.gainReductionDb = max(b5Min, min(b5Max, band5.gainReductionDb))
                if band5.gainReductionDb > 0 { band5.gainReductionDb = 0 }

                // 3. Convert dB to linear gain coefficients
                currentGain1 = LoudnessEqualizerMath.dbToLinear(band1.gainReductionDb)
                currentGain2 = LoudnessEqualizerMath.dbToLinear(band2.gainReductionDb)
                currentGain3 = LoudnessEqualizerMath.dbToLinear(band3.gainReductionDb)
                currentGain4 = LoudnessEqualizerMath.dbToLinear(band4.gainReductionDb)
                currentGain5 = LoudnessEqualizerMath.dbToLinear(band5.gainReductionDb)

                // Reset peak accumulators
                hopCounter = 0
                hopPeak1 = 0.0
                hopPeak2 = 0.0
                hopPeak3 = 0.0
                hopPeak4 = 0.0
                hopPeak5 = 0.0
            }

            for ch in 0..<channelCount {
                output[base + ch] = band1Samples[ch] * currentGain1 +
                                    band2Samples[ch] * currentGain2 +
                                    band3Samples[ch] * currentGain3 +
                                    band4Samples[ch] * currentGain4 +
                                    band5Samples[ch] * currentGain5
            }
        }
    }
}
