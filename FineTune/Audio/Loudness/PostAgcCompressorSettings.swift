struct PostAgcCompressorSettings: Codable, Equatable, Sendable {
    /// Threshold in dBFS. Signals above this are compressed.
    /// Default -3.0 dBFS — sweet spot for Orban-style post-AGC density compression.
    var thresholdDb: Float = -3.0
    
    /// Compression ratio. Default: 6.0 (acts as the maximum dynamic feedback ratio).
    var ratio: Float = 6.0
    
    /// Attack time in milliseconds.
    /// Default: 10.0 ms.
    var attackMs: Float = 10.0
    
    /// Release time in milliseconds.
    /// Default: 50.0 ms (fast release for transients, ARC will slow this down dynamically).
    var releaseMs: Float = 50.0
    
    /// Knee width in dB. Default: 6.0 dB for a progressive soft-knee transition.
    var kneeDb: Float = 6.0
    
    /// Exponential release factor (0 = linear, closer to 1 = more exponential).
    /// Higher values slow down release as gain reduction approaches 0 dB.
    /// Default: 0.8.
    var exponentialRelease: Float = 0.8
    
    /// Max Release Speed cap (default: 0.502502918).
    /// Divides the release time to compute a maximum release coefficient,
    /// preventing overly fast recovery at deep gain reduction.
    var maxReleaseSpeed: Float = 0.502502918
    
    /// Whether the compressor is active. Auto-enabled when AGC is enabled.
    var enabled: Bool = true
}
