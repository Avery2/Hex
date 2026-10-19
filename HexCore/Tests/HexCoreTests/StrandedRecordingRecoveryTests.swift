import Foundation
import Testing
@testable import HexCore

struct StrandedRecordingRecoveryTests {
	private let sampleRate: Double = 16_000
	private let headerBytes = 44
	private let bytesPerFrame = 4

	private func makeTemporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("stranded-recovery-tests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	/// The canonical RIFF/WAVE header Hex writes: 16kHz mono 32-bit float, 44 bytes.
	private func canonicalHeader(payloadBytes: Int) -> Data {
		var data = Data(capacity: headerBytes)
		data.append(contentsOf: Array("RIFF".utf8))
		data.append(contentsOf: UInt32(payloadBytes + 36).littleEndianData)
		data.append(contentsOf: Array("WAVE".utf8))
		data.append(contentsOf: Array("fmt ".utf8))
		data.append(contentsOf: UInt32(16).littleEndianData)
		data.append(contentsOf: UInt16(3).littleEndianData) // WAVE_FORMAT_IEEE_FLOAT
		data.append(contentsOf: UInt16(1).littleEndianData) // mono
		data.append(contentsOf: UInt32(sampleRate).littleEndianData)
		data.append(contentsOf: UInt32(sampleRate * Double(bytesPerFrame)).littleEndianData)
		data.append(contentsOf: UInt16(bytesPerFrame).littleEndianData) // block align
		data.append(contentsOf: UInt16(32).littleEndianData) // bits per sample
		data.append(contentsOf: Array("data".utf8))
		data.append(contentsOf: UInt32(payloadBytes).littleEndianData)
		return data
	}

	/// Writes a capture the way Hex lays it out on disk: a 44-byte header followed by `frames`
	/// mono float samples. With `headerFinalised: false` the header's size fields stay zeroed,
	/// which is exactly what a recording cut short by a crash looks like.
	@discardableResult
	private func writeCapture(
		_ name: String,
		in directory: URL,
		frames: Int,
		modified: Date,
		headerFinalised: Bool = true
	) throws -> URL {
		let url = directory.appendingPathComponent(name)
		let payloadBytes = frames * bytesPerFrame
		var data = headerFinalised
			? canonicalHeader(payloadBytes: payloadBytes)
			: Data(repeating: 0, count: headerBytes)
		// Non-zero bytes so the payload is real audio rather than zero padding.
		data.append(Data(repeating: 0x11, count: payloadBytes))
		try data.write(to: url)
		try setModificationDate(modified, on: url)
		return url
	}

	private func setModificationDate(_ date: Date, on url: URL) throws {
		try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
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

		let url = try writeCapture(
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
	func aSingleFrameIsEnoughToBeHandedBack() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let url = try writeCapture(
			"hex-capture-\(UUID().uuidString).wav",
			in: directory,
			frames: 1,
			modified: cutoff.addingTimeInterval(-600)
		)

		let recovered = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		#expect(recovered.count == 1)
		#expect(sameFile(recovered.first?.url, url))
		#expect(recovered.first?.duration == 1.0 / sampleRate)
		#expect(FileManager.default.fileExists(atPath: url.path))
	}

	/// The regression this whole file exists for: an interrupted recording leaves real audio
	/// behind a header whose sizes were never written. The old header-based check saw zero
	/// frames and deleted it; the size-based check must report it with the right duration.
	@Test
	func anUnfinalisedRecordingIsRecoveredFromItsSize() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		// The real-world file: 1,097,936 bytes, about 17 seconds of speech, with a zeroed header.
		let frames = 274_473
		let url = try writeCapture(
			"hex-capture-\(UUID().uuidString).wav",
			in: directory,
			frames: frames,
			modified: cutoff.addingTimeInterval(-600),
			headerFinalised: false
		)

		let recovered = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
		#expect(size == 1_097_936)
		#expect(recovered.count == 1)
		#expect(sameFile(recovered.first?.url, url))
		#expect(recovered.first?.duration == Double(frames) / sampleRate)
		// Reported, never deleted: the words are still on disk for the caller to move.
		#expect(FileManager.default.fileExists(atPath: url.path))
	}

	@Test
	func aRecordingThatCapturedNothingIsRemoved() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		// Exactly what an aborted session leaves behind: a header and no frames.
		let url = try writeCapture(
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
	func aHeaderWithAPartialFrameIsRemoved() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		// A header plus three stray bytes: less than one frame, so no audio.
		let url = directory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")
		var data = canonicalHeader(payloadBytes: 0)
		data.append(Data(repeating: 0x11, count: bytesPerFrame - 1))
		try data.write(to: url)
		try setModificationDate(cutoff.addingTimeInterval(-600), on: url)

		let recovered = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		#expect(recovered.isEmpty)
		#expect(FileManager.default.fileExists(atPath: url.path) == false)
	}

	@Test
	func aZeroLengthFileIsLeftAlone() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		// Nothing to inspect, so nothing to delete: an empty file is kept rather than guessed at.
		let url = directory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")
		try Data().write(to: url)
		try setModificationDate(cutoff.addingTimeInterval(-600), on: url)

		let recovered = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		#expect(recovered.isEmpty)
		#expect(FileManager.default.fileExists(atPath: url.path))
	}

	@Test
	func recordingsFromTheCurrentSessionAreLeftAlone() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		// Written after launch: this could be the recording in flight right now, and the
		// whole point of the cut-off is that recovery can never race a live session.
		let inFlight = try writeCapture(
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

		let newer = try writeCapture(
			"hex-capture-\(UUID().uuidString).wav",
			in: directory,
			frames: 16_000,
			modified: cutoff.addingTimeInterval(-60)
		)
		let older = try writeCapture(
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
	func entriesThatCannotBeInspectedAreLeftAlone() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		// A directory wearing a capture's name has no size we can trust as audio, so it is
		// neither reported nor removed.
		let entry = directory.appendingPathComponent(
			"hex-capture-\(UUID().uuidString).wav",
			isDirectory: true
		)
		try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
		try setModificationDate(cutoff.addingTimeInterval(-600), on: entry)

		let recovered = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		#expect(recovered.isEmpty)
		var isDirectory: ObjCBool = false
		#expect(FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory))
		#expect(isDirectory.boolValue)
	}

	@Test
	func filesWithUnparseableContentsAreNeverDeleted() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		// Bytes that are not a WAV at all. The size rule reads them as audio, which is the safe
		// direction: whatever they are, they are handed back rather than destroyed.
		let url = directory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")
		try Data(repeating: 0xAB, count: 4096).write(to: url)
		try setModificationDate(cutoff.addingTimeInterval(-600), on: url)

		let recovered = StrandedRecordingRecovery.collect(in: directory, before: cutoff)

		#expect(recovered.count == 1)
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

private extension FixedWidthInteger {
	var littleEndianData: Data {
		var value = littleEndian
		return withUnsafeBytes(of: &value) { Data($0) }
	}
}
