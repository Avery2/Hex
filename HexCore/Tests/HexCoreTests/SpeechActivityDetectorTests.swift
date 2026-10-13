import Foundation
import Testing
@testable import HexCore

/// Levels below come from real Hex recordings: room tone sat at RMS ~0.0015 with peaks ~0.01,
/// speech at RMS ~0.017-0.05 with peaks ~0.07-0.17, and a clipped take peaked at 2.8.
struct SpeechActivityDetectorTests {
	private func silence(_ detector: inout SpeechActivityDetector, frames: Int = 30) {
		for _ in 0 ..< frames {
			detector.ingest(averagePower: 0.0015, peakPower: 0.01)
		}
	}

	@Test
	func roomToneAloneNeverCountsAsSpeech() {
		var detector = SpeechActivityDetector()
		silence(&detector, frames: 200)

		#expect(detector.hasSpoken == false)
		#expect(detector.isSpeaking == false)
		// The whole point: a quiet room reports `waiting`, not a misleading "capturing".
		#expect(detector.quality == .waiting)
	}

	@Test
	func detectsSpeechWellAboveTheNoiseFloor() {
		var detector = SpeechActivityDetector()
		silence(&detector, frames: 20)

		for _ in 0 ..< 10 {
			detector.ingest(averagePower: 0.04, peakPower: 0.15)
		}

		#expect(detector.hasSpoken)
		#expect(detector.isSpeaking)
		#expect(detector.quality == .good)
	}

	@Test
	func speechThatIsTooFaintToTranscribeIsReported() {
		var detector = SpeechActivityDetector()
		silence(&detector, frames: 20)

		// Above the noise floor, so it registers as speech, but with a peak far below the
		// level speech normally reaches — the "you're too far from the mic" case.
		for _ in 0 ..< 10 {
			detector.ingest(averagePower: 0.012, peakPower: 0.03)
		}

		#expect(detector.hasSpoken)
		#expect(detector.quality == .tooQuiet)
	}

	@Test
	func clippingIsReported() {
		var detector = SpeechActivityDetector()
		silence(&detector, frames: 20)

		for _ in 0 ..< 5 {
			detector.ingest(averagePower: 0.3, peakPower: 1.4)
		}

		#expect(detector.quality == .clipping)
	}

	@Test
	func briefGapsBetweenWordsDoNotStopTheSignal() {
		var detector = SpeechActivityDetector()
		silence(&detector, frames: 20)

		detector.ingest(averagePower: 0.05, peakPower: 0.2)
		// Two quiet frames is a gap between words, not the end of speech.
		detector.ingest(averagePower: 0.0015, peakPower: 0.01)
		detector.ingest(averagePower: 0.0015, peakPower: 0.01)

		#expect(detector.isSpeaking)
	}

	@Test
	func speakingStopsAfterTheHangoverExpires() {
		var detector = SpeechActivityDetector(silenceFloor: 0.003, speechMargin: 3.5, hangoverFrames: 2)
		detector.ingest(averagePower: 0.05, peakPower: 0.2)

		for _ in 0 ..< 5 {
			detector.ingest(averagePower: 0.0015, peakPower: 0.01)
		}

		#expect(detector.isSpeaking == false)
		// The latch survives, so the UI can still say "I did hear you".
		#expect(detector.hasSpoken)
	}

	@Test
	func aDeadMicrophoneKeepsReportingWaiting() {
		var detector = SpeechActivityDetector()
		// A muted or unplugged input delivers pure zeros, which must never look like speech.
		for _ in 0 ..< 200 {
			detector.ingest(averagePower: 0, peakPower: 0)
		}

		#expect(detector.hasSpoken == false)
		#expect(detector.quality == .waiting)
	}

	@Test
	func noiseFloorAdaptsToALoudRoomWithoutSwallowingSpeech() {
		var detector = SpeechActivityDetector()
		// Sustained room noise, e.g. a fan, well above the initial floor.
		for _ in 0 ..< 300 {
			detector.ingest(averagePower: 0.01, peakPower: 0.03)
		}
		let adaptedFloor = detector.noiseFloor
		#expect(adaptedFloor > SpeechActivityDetector.defaultSilenceFloor)

		// Speech still has to stand out above the adapted floor to register.
		for _ in 0 ..< 10 {
			detector.ingest(averagePower: 0.15, peakPower: 0.4)
		}
		#expect(detector.isSpeaking)
		#expect(detector.quality == .good)
	}

	@Test
	func resetClearsPerRecordingStateButKeepsTheLearnedNoiseFloor() {
		var detector = SpeechActivityDetector()
		for _ in 0 ..< 100 {
			detector.ingest(averagePower: 0.01, peakPower: 0.03)
		}
		detector.ingest(averagePower: 0.2, peakPower: 0.5)
		let learnedFloor = detector.noiseFloor
		#expect(detector.hasSpoken)

		detector.reset()

		#expect(detector.hasSpoken == false)
		#expect(detector.isSpeaking == false)
		#expect(detector.recentPeak == 0)
		// The room did not change just because a new recording started.
		#expect(detector.noiseFloor == learnedFloor)
	}
}
