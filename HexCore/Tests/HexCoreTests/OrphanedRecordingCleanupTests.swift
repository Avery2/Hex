import Foundation
import Testing
@testable import HexCore

struct OrphanedRecordingCleanupTests {
	private func makeTemporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("orphan-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	private func write(
		_ name: String,
		in directory: URL,
		bytes: Int = 4096,
		modified: Date
	) throws -> URL {
		let url = directory.appendingPathComponent(name)
		try Data(repeating: 0, count: bytes).write(to: url)
		try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
		return url
	}

	@Test
	func removesStrandedRecordingsOlderThanTheMinimumAge() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let now = Date()

		let strandedCapture = try write(
			"hex-capture-\(UUID().uuidString).wav",
			in: directory,
			bytes: 52_480,
			modified: now.addingTimeInterval(-7200)
		)
		let strandedFallback = try write(
			"hex-recording-\(UUID().uuidString).wav",
			in: directory,
			bytes: 1024,
			modified: now.addingTimeInterval(-7200)
		)

		let result = OrphanedRecordingCleanup.run(in: directory, now: now)

		#expect(result.files == 2)
		#expect(result.bytes == 52_480 + 1024)
		#expect(FileManager.default.fileExists(atPath: strandedCapture.path) == false)
		#expect(FileManager.default.fileExists(atPath: strandedFallback.path) == false)
	}

	@Test
	func neverTouchesARecordingThatMightStillBeInFlight() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let now = Date()

		// Written a moment ago: this could be the recording the user is speaking into right now.
		let active = try write(
			"hex-capture-\(UUID().uuidString).wav",
			in: directory,
			modified: now.addingTimeInterval(-5)
		)

		let result = OrphanedRecordingCleanup.run(in: directory, now: now)

		#expect(result.files == 0)
		#expect(FileManager.default.fileExists(atPath: active.path))
	}

	@Test
	func leavesUnrelatedFilesAlone() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let now = Date()

		let unrelated = try write(
			"CFNetworkDownload_abc.tmp",
			in: directory,
			modified: now.addingTimeInterval(-7200)
		)
		// Shares the `hex-capture-` prefix but is not a name Hex writes.
		let lookalike = try write(
			"hex-capture-not-a-uuid.wav",
			in: directory,
			modified: now.addingTimeInterval(-7200)
		)
		let lookalikeSuffix = try write(
			"hex-capture-\(UUID().uuidString).wav.bak",
			in: directory,
			modified: now.addingTimeInterval(-7200)
		)

		let result = OrphanedRecordingCleanup.run(in: directory, now: now)

		#expect(result.files == 0)
		#expect(FileManager.default.fileExists(atPath: unrelated.path))
		#expect(FileManager.default.fileExists(atPath: lookalike.path))
		#expect(FileManager.default.fileExists(atPath: lookalikeSuffix.path))
	}

	@Test
	func recognisesOnlyTheNamesHexActuallyWrites() {
		#expect(OrphanedRecordingCleanup.isOrphanedRecording("hex-capture-\(UUID().uuidString).wav"))
		#expect(OrphanedRecordingCleanup.isOrphanedRecording("hex-recording-\(UUID().uuidString).wav"))
		#expect(OrphanedRecordingCleanup.isOrphanedRecording("hex-capture-not-a-uuid.wav") == false)
		#expect(OrphanedRecordingCleanup.isOrphanedRecording("hex-capture-\(UUID().uuidString).wav.bak") == false)
		#expect(OrphanedRecordingCleanup.isOrphanedRecording("recording.wav") == false)
	}

	@Test
	func isANoOpForAMissingDirectory() {
		let missing = FileManager.default.temporaryDirectory
			.appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)

		let result = OrphanedRecordingCleanup.run(in: missing)

		#expect(result.files == 0)
		#expect(result.bytes == 0)
	}
}
