import Foundation
import Testing
@testable import HexCore

/// `Transcript.status` was added after history files already existed on disk, and a decoding
/// failure there would silently wipe someone's saved transcripts — so the legacy shape is
/// pinned down explicitly.
struct TranscriptStatusCodingTests {
	/// Byte-for-byte the shape Hex 0.8.5 wrote, before `status` existed.
	private let legacyHistoryJSON = """
	{
	  "history" : [
	    {
	      "audioPath" : "file:\\/\\/\\/Users\\/someone\\/Recordings\\/1791878719.22442.wav",
	      "duration" : 3.5501569509506226,
	      "id" : "EA62958D-D2D0-4FE3-88BC-DFCBE3DF9176",
	      "sourceAppBundleID" : "md.obsidian",
	      "sourceAppName" : "Obsidian",
	      "text" : "Hello, I'm testing this out.",
	      "timestamp" : 813571519.224628
	    }
	  ]
	}
	"""

	@Test
	func historyWrittenBeforeStatusExistedStillDecodes() throws {
		let history = try JSONDecoder().decode(
			TranscriptionHistory.self,
			from: Data(legacyHistoryJSON.utf8)
		)

		#expect(history.history.count == 1)
		let transcript = try #require(history.history.first)
		#expect(transcript.text == "Hello, I'm testing this out.")
		#expect(transcript.sourceAppName == "Obsidian")
		#expect(transcript.duration == 3.5501569509506226)
		// Anything written before this field existed could only ever have been pasted.
		#expect(transcript.status == .pasted)
	}

	@Test
	func everyStatusSurvivesARoundTrip() throws {
		for status in [TranscriptStatus.pasted, .notPasted, .failed] {
			let transcript = Transcript(
				timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000),
				text: "hello",
				audioPath: URL(fileURLWithPath: "/tmp/hello.wav"),
				duration: 1.25,
				sourceAppBundleID: "com.apple.Safari",
				sourceAppName: "Safari",
				status: status
			)

			let data = try JSONEncoder().encode(transcript)
			let decoded = try JSONDecoder().decode(Transcript.self, from: data)

			#expect(decoded == transcript)
			#expect(decoded.status == status)
		}
	}

	@Test
	func onlyPastedTranscriptsReportThemselvesAsPasted() {
		#expect(TranscriptStatus.pasted.wasPasted)
		#expect(TranscriptStatus.notPasted.wasPasted == false)
		#expect(TranscriptStatus.failed.wasPasted == false)
	}
}
