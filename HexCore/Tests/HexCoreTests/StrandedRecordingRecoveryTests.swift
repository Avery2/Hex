import AVFoundation
import Foundation
import Testing
@testable import HexCore

struct StrandedRecordingRecoveryTests {
	private func makeTemporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("stranded-recovery-tests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	/// Writes a real WAV holding `frames` samples of 16kHz mono float audio.
	@discardableResult
	private func writeRecording(
		_ name: String,
		in directory: URL,
		frames: AVAudioFrameCount,
		modified: Date
	) throws -> URL {
		let url = directory.appendingPathComponent(name)
		let format = AVAudioFormat(
			commonFormat: .pcmFormatFloat32,
			sampleRate: 16_000,
			channels: 1,
			interleaved: false
		)!
		// Scoped so the writer is closed before the timestamp is set: closing an AVAudioFile
		// finalises the WAV header, which rewrites the file's modification date. Setting the
		// date while the writer is still open silently gets overwritten.
		do {
			let file = try AVAudioFile(
				forWriting: url,
				settings: [
					AVFormatIDKey: Int(kAudioFormatLinearPCM),
					AVSampleRateKey: 16_000,
					AVNumberOfChannelsKey: 1,
					AVLinearPCMBitDepthKey: 32,
					AVLinearPCMIsFloatKey: true,
					AVLinearPCMIsBigEndianKey: false,
					AVLinearPCMIsNonInterleaved: true,
				],
				commonFormat: .pcmFormatFloat32,
				interleaved: false
			)
			if frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
				buffer.frameLength = frames
				for index in 0 ..< Int(frames) {
					buffer.floatChannelData?[0][index] = 0.1
				}
				try file.write(from: buffer)
			}
		}
		try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
		return url
	}

	private let cutoff = Date()

	/// `FileManager.temporaryDirectory` reports `/var/...` while `contentsOfDirectory` reports
	/// the resolved `/private/var/...`, so raw `URL` equality fails on paths that are the same
	/// file. Compare resolved paths instead.
	private func sameFile(_ lhs: URL?, _ rhs: URL) -> Bool {
		guard let lhs else { return false }
		return lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
	}

	@Test
	func aRecordingThatHoldsAudioIsHandedBackForRecovery() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let url = try writeRecording(
			"hex-capture-\(UUID().uuidString).wav",
			in: directory,
			frames: 24_000,
			modified: cutoff.addingTimeInterval(-600)
		)

		let recovered = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		#expect(recovered.count == 1)
		#expect(sameFile(recovered.first?.url, url))
		#expect(recovered.first?.duration == 1.5)
		// Handed back, not consumed — the caller moves it into history.
		#expect(FileManager.default.fileExists(atPath: url.path))
	}

	@Test
	func aRecordingThatCapturedNothingIsRemoved() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		// Exactly what an aborted session leaves behind: a header and no frames.
		let url = try writeRecording(
			"hex-capture-\(UUID().uuidString).wav",
			in: directory,
			frames: 0,
			modified: cutoff.addingTimeInterval(-600)
		)

		let recovered = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		#expect(recovered.isEmpty)
		#expect(FileManager.default.fileExists(atPath: url.path) == false)
	}

	@Test
	func recordingsFromTheCurrentSessionAreLeftAlone() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		// Written after launch: this could be the recording in flight right now, and the
		// whole point of the cut-off is that recovery can never race a live session.
		let inFlight = try writeRecording(
			"hex-capture-\(UUID().uuidString).wav",
			in: directory,
			frames: 24_000,
			modified: cutoff.addingTimeInterval(5)
		)

		let recovered = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		#expect(recovered.isEmpty)
		#expect(FileManager.default.fileExists(atPath: inFlight.path))
	}

	@Test
	func recoveryIsOldestFirst() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let newer = try writeRecording(
			"hex-capture-\(UUID().uuidString).wav",
			in: directory,
			frames: 16_000,
			modified: cutoff.addingTimeInterval(-60)
		)
		let older = try writeRecording(
			"hex-recording-\(UUID().uuidString).wav",
			in: directory,
			frames: 32_000,
			modified: cutoff.addingTimeInterval(-600)
		)

		let recovered = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		#expect(recovered.count == 2)
		#expect(sameFile(recovered.first?.url, older))
		#expect(sameFile(recovered.last?.url, newer))
	}

	@Test
	func unreadableFilesAreKeptRatherThanDestroyed() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		// Truncated/garbage content: not something we can inspect, so not ours to delete.
		let url = directory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")
		try Data(repeating: 0xAB, count: 4096).write(to: url)
		try FileManager.default.setAttributes(
			[.modificationDate: cutoff.addingTimeInterval(-600)],
			ofItemAtPath: url.path
		)

		let recovered = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		#expect(recovered.isEmpty)
		#expect(FileManager.default.fileExists(atPath: url.path))
	}

	@Test
	func leavesUnrelatedFilesAlone() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let unrelated = directory.appendingPathComponent("CFNetworkDownload_abc.tmp")
		try Data(repeating: 0, count: 128).write(to: unrelated)

		let result = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		#expect(result.isEmpty)
		#expect(FileManager.default.fileExists(atPath: unrelated.path))
	}

	@Test
	func recognisesOnlyTheNamesHexActuallyWrites() {
		#expect(StrandedRecordingRecovery.isStrandedRecordingName("hex-capture-\(UUID().uuidString).wav"))
		#expect(StrandedRecordingRecovery.isStrandedRecordingName("hex-recording-\(UUID().uuidString).wav"))
		#expect(StrandedRecordingRecovery.isStrandedRecordingName("hex-capture-not-a-uuid.wav") == false)
		#expect(StrandedRecordingRecovery.isStrandedRecordingName("hex-capture-\(UUID().uuidString).wav.bak") == false)
		#expect(StrandedRecordingRecovery.isStrandedRecordingName("recording.wav") == false)
	}

	@Test
	func isANoOpForAMissingDirectory() {
		let missing = FileManager.default.temporaryDirectory
			.appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)

		#expect(StrandedRecordingRecovery.collect(in: missing, before: cutoff).isEmpty)
	}
}
