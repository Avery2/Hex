import Foundation

/// Turns raw microphone levels into the two things worth telling someone while they speak.
///
/// Hex already showed loudness, but a level meter answers the wrong question: a silent room
/// and a muted or dead microphone look identical on it, and loudness says nothing about
/// whether the transcriber can actually make words out of what it hears. So this reports:
///
/// 1. **Is speech-like energy arriving at all?** Detected as sustained energy well above a
///    tracked noise floor, so a dead mic (`isSpeaking == false` forever) is distinguishable
///    from a quiet room (also `false`, but with a live noise floor).
/// 2. **Is that energy in the range the transcriber handles well?** Too faint and words get
///    dropped; clipping garbles them.
///
/// Thresholds are calibrated against real Hex recordings, where speech sat at RMS ~0.017-0.05
/// with peaks ~0.07-0.17, room tone sat at RMS ~0.0015 with peaks ~0.01, and a genuinely
/// clipped take peaked at 2.8.
public struct SpeechActivityDetector: Equatable, Sendable {
    public enum Quality: Equatable, Sendable {
        /// Nothing speech-like has arrived yet.
        case waiting
        /// Speech-like energy at a level the transcriber handles well.
        case good
        /// Speech-like energy, but too faint to transcribe reliably.
        case tooQuiet
        /// The input is clipping, which garbles words.
        case clipping
    }

    /// Levels at or below this are electrical/room noise, not someone talking.
    public static let defaultSilenceFloor: Double = 0.003
    /// How far above the tracked noise floor a frame must sit to count as speech.
    public static let defaultSpeechMargin: Double = 3.5
    /// Peak below which speech is treated as too faint for the transcriber.
    public static let defaultQuietThreshold: Double = 0.04
    /// Peak at or above which the input is clipping.
    public static let defaultClippingThreshold: Double = 0.97

    public let silenceFloor: Double
    public let speechMargin: Double
    /// Frames to stay "speaking" after the last speech frame, so the natural gaps between
    /// words don't make the indicator flicker.
    public let hangoverFrames: Int
    public let quietThreshold: Double
    public let clippingThreshold: Double
    /// Decay applied to the recent-peak envelope each frame (~0.3s half-life at the meter's rate).
    public let recentPeakDecay: Double

    public private(set) var noiseFloor: Double
    /// Speech-like energy in the current frame, including hangover.
    public private(set) var isSpeaking = false
    /// Latched: speech-like energy has arrived at least once this recording.
    public private(set) var hasSpoken = false
    /// Decaying envelope of recent peaks, used for the quality verdict.
    public private(set) var recentPeak: Double = 0
    /// Smoothed level of frames that counted as speech.
    public private(set) var speechLevel: Double = 0
    private var hangover = 0

    public init(
        silenceFloor: Double = SpeechActivityDetector.defaultSilenceFloor,
        speechMargin: Double = SpeechActivityDetector.defaultSpeechMargin,
        hangoverFrames: Int = 6,
        quietThreshold: Double = SpeechActivityDetector.defaultQuietThreshold,
        clippingThreshold: Double = SpeechActivityDetector.defaultClippingThreshold,
        recentPeakDecay: Double = 0.9
    ) {
        self.silenceFloor = silenceFloor
        self.speechMargin = speechMargin
        self.hangoverFrames = hangoverFrames
        self.quietThreshold = quietThreshold
        self.clippingThreshold = clippingThreshold
        self.recentPeakDecay = recentPeakDecay
        self.noiseFloor = silenceFloor
    }

    /// Clears per-recording state, keeping the learned noise floor: the room does not change
    /// just because a new recording started.
    public mutating func reset() {
        isSpeaking = false
        hasSpoken = false
        recentPeak = 0
        speechLevel = 0
        hangover = 0
    }

    /// Feeds one metering frame from the microphone.
    public mutating func ingest(averagePower: Double, peakPower: Double) {
        recentPeak = max(peakPower, recentPeak * recentPeakDecay)

        let threshold = max(noiseFloor * speechMargin, silenceFloor)
        if averagePower > threshold {
            isSpeaking = true
            hasSpoken = true
            hangover = hangoverFrames
            speechLevel = speechLevel == 0 ? averagePower : speechLevel * 0.8 + averagePower * 0.2
        } else if hangover > 0 {
            hangover -= 1
            if hangover == 0 {
                isSpeaking = false
            }
        } else {
            isSpeaking = false
            // Only adapt while nobody is talking, otherwise speech would raise its own floor.
            noiseFloor = max(silenceFloor, noiseFloor * 0.98 + averagePower * 0.02)
        }
    }

    /// Whether what the mic is hearing is in a range the transcriber can work with.
    public var quality: Quality {
        guard hasSpoken else { return .waiting }
        if recentPeak >= clippingThreshold { return .clipping }
        if recentPeak < quietThreshold { return .tooQuiet }
        return .good
    }
}
