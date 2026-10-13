import Foundation
import Testing
@testable import HexCore

/// Levels below come from real Hex recordings: room tone sat at RMS ~0.0015 with peaks ~0.01,
/// and speech at RMS ~0.017-0.05 with peaks ~0.07-0.17.
struct SpeechActivityDetectorTests {
	private func silence(_ detector: inout SpeechActivityDetector, frames: Int = 30) {
		for _ in 0 ..< frames {
			detector.ingest(averagePower: 0.0015)
		}
	}

	@Test
	func roomToneAloneNeverCountsAsSpeech() {
		var detector = SpeechActivityDetector()
		silence(&detector, frames: 200)

		#expect(detector.hasSpoken == false)
		#expect(detector.isSpeaking == false)
	}

	@Test
	func aDeadMicrophoneKeepsReportingNothingHeard() {
		var detector = SpeechActivityDetector()
		// A muted or unplugged input delivers pure zeros, which must never look like speech.
		for _ in 0 ..< 200 {
			detector.ingest(averagePower: 0)
		}

		#expect(detector.hasSpoken == false)
	}

	@Test
	func detectsSpeechWellAboveTheNoiseFloor() {
		var detector = SpeechActivityDetector()
		silence(&detector, frames: 20)

		for _ in 0 ..< 10 {
			detector.ingest(averagePower: 0.04)
		}

		#expect(detector.hasSpoken)
		#expect(detector.isSpeaking)
	}

	@Test
	func briefGapsBetweenWordsDoNotStopTheSignal() {
		var detector = SpeechActivityDetector()
		silence(&detector, frames: 20)

		detector.ingest(averagePower: 0.05)
		// Two quiet frames is a gap between words, not the end of speech.
		detector.ingest(averagePower: 0.0015)
		detector.ingest(averagePower: 0.0015)

		#expect(detector.isSpeaking)
	}

	@Test
	func speakingStopsAfterTheHangoverExpires() {
		var detector = SpeechActivityDetector(silenceFloor: 0.003, speechMargin: 3.5, hangoverFrames: 2)
		detector.ingest(averagePower: 0.05)

		for _ in 0 ..< 5 {
			detector.ingest(averagePower: 0.0015)
		}

		#expect(detector.isSpeaking == false)
		// The latch survives, so pausing mid-sentence never brings back the "nothing heard"
		// state — that was the bug in the quality-verdict version.
		#expect(detector.hasSpoken)
	}

	@Test
	func pausingMidSentenceNeverRevokesWhatWasAlreadyHeard() {
		var detector = SpeechActivityDetector()
		silence(&detector, frames: 20)

		detector.ingest(averagePower: 0.05)
		#expect(detector.hasSpoken)

		// A long pause: far longer than any hangover.
		silence(&detector, frames: 200)

		#expect(detector.hasSpoken)
		#expect(detector.isSpeaking == false)
	}

	@Test
	func noiseFloorAdaptsToALoudRoomWithoutSwallowingSpeech() {
		var detector = SpeechActivityDetector()
		// Sustained room noise, e.g. a fan, well above the initial floor.
		for _ in 0 ..< 300 {
			detector.ingest(averagePower: 0.01)
		}
		#expect(detector.noiseFloor > SpeechActivityDetector.defaultSilenceFloor)

		// Speech still has to stand out above the adapted floor to register.
		for _ in 0 ..< 10 {
			detector.ingest(averagePower: 0.15)
		}
		#expect(detector.isSpeaking)
	}

	@Test
	func resetClearsPerRecordingStateButKeepsTheLearnedNoiseFloor() {
		var detector = SpeechActivityDetector()
		for _ in 0 ..< 100 {
			detector.ingest(averagePower: 0.01)
		}
		detector.ingest(averagePower: 0.2)
		let learnedFloor = detector.noiseFloor
		#expect(detector.hasSpoken)

		detector.reset()

		#expect(detector.hasSpoken == false)
		#expect(detector.isSpeaking == false)
		// The room did not change just because a new recording started.
		#expect(detector.noiseFloor == learnedFloor)
	}
}
