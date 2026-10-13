import Foundation

/// Tells whether speech-like energy is arriving at the microphone.
///
/// This exists for one job: the level meter cannot distinguish a quiet room from a muted or
/// dead microphone, because both look like a low reading. Speech is detected as sustained
/// energy well above a noise floor that adapts while nobody is talking, so a dead mic
/// (`hasSpoken` never becomes true) is distinguishable from someone simply pausing.
///
/// Deliberately *not* a quality verdict. An earlier version also graded how good the audio
/// was — too quiet, clipping — which was worse than useless in practice: any natural pause
/// between words decayed the level and flipped the indicator to "Too quiet" while the user
/// was mid-sentence. The words themselves are shown instead.
///
/// Thresholds are calibrated against real Hex recordings, where room tone sat at RMS ~0.0015
/// with peaks ~0.01, and speech at RMS ~0.017-0.05 with peaks ~0.07-0.17.
public struct SpeechActivityDetector: Equatable, Sendable {
    /// Levels at or below this are electrical/room noise, not someone talking.
    public static let defaultSilenceFloor: Double = 0.003
    /// How far above the tracked noise floor a frame must sit to count as speech.
    public static let defaultSpeechMargin: Double = 3.5

    public let silenceFloor: Double
    public let speechMargin: Double
    /// Frames to stay "speaking" after the last speech frame, so the natural gaps between
    /// words don't make the signal flicker.
    public let hangoverFrames: Int

    public private(set) var noiseFloor: Double
    /// Speech-like energy in the current frame, including hangover.
    public private(set) var isSpeaking = false
    /// Latched: speech-like energy has arrived at least once this recording.
    public private(set) var hasSpoken = false
    private var hangover = 0

    public init(
        silenceFloor: Double = SpeechActivityDetector.defaultSilenceFloor,
        speechMargin: Double = SpeechActivityDetector.defaultSpeechMargin,
        hangoverFrames: Int = 6
    ) {
        self.silenceFloor = silenceFloor
        self.speechMargin = speechMargin
        self.hangoverFrames = hangoverFrames
        self.noiseFloor = silenceFloor
    }

    /// Clears per-recording state, keeping the learned noise floor: the room does not change
    /// just because a new recording started.
    public mutating func reset() {
        isSpeaking = false
        hasSpoken = false
        hangover = 0
    }

    /// Feeds one metering frame from the microphone.
    public mutating func ingest(averagePower: Double) {
        let threshold = max(noiseFloor * speechMargin, silenceFloor)
        if averagePower > threshold {
            isSpeaking = true
            hasSpoken = true
            hangover = hangoverFrames
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
}
