import AVFoundation
import Foundation
import Testing
@testable import HexCore

struct DurableAudioWriterTests {
	private func makeTemporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("durable-audio-writer-tests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	/// A recognisable ramp so a reader can be checked sample-for-sample, not just by count.
	private func samples(count: Int) -> [Float] {
		(0 ..< count).map { Float($0 % 100) / 100 }
	}

	private func fileLength(_ url: URL) throws -> Int {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		return (attributes[.size] as? Int) ?? 0
	}

	private func readUInt32(at offset: Int, in url: URL) throws -> UInt32 {
		let data = try Data(contentsOf: url)
		return UInt32(data[offset])
			| (UInt32(data[offset + 1]) << 8)
			| (UInt32(data[offset + 2]) << 16)
			| (UInt32(data[offset + 3]) << 24)
	}

	private func writeUInt32(_ value: UInt32, at offset: Int, in url: URL) throws {
		let handle = try FileHandle(forWritingTo: url)
		defer { try? handle.close() }
		var littleEndian = value.littleEndian
		try handle.seek(toOffset: UInt64(offset))
		try handle.write(contentsOf: withUnsafeBytes(of: &littleEndian) { Data($0) })
	}

	private func truncate(_ url: URL, to length: Int) throws {
		let handle = try FileHandle(forWritingTo: url)
		defer { try? handle.close() }
		try handle.truncate(atOffset: UInt64(length))
	}

	@Test
	func appendedAudioIsReadableBeforeTheWriterIsClosed() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")

		let writer = try DurableAudioWriter(url: url)
		try writer.append(samples(count: 16_000))
		try writer.checkpoint()

		// Deliberately no finish(): this is the state a kill leaves behind, and it must
		// already open as a WAV holding exactly what was appended.
		let file = try AVAudioFile(forReading: url)
		#expect(file.length == 16_000)
		#expect(file.processingFormat.sampleRate == 16_000)
		#expect(file.processingFormat.channelCount == 1)
	}

	@Test
	func headerSizesMatchTheBytesOnDisk() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")

		let writer = try DurableAudioWriter(url: url)
		try writer.append(samples(count: 16_000))
		try writer.checkpoint()

		let length = try fileLength(url)
		#expect(try readUInt32(at: 4, in: url) == UInt32(length - 8))
		#expect(try readUInt32(at: 40, in: url) == UInt32(length - 44))
	}

	@Test
	func samplesRoundTripThroughAReader() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")

		let input = samples(count: 1_000)
		let writer = try DurableAudioWriter(url: url)
		try writer.append(input)
		try writer.checkpoint()

		let file = try AVAudioFile(forReading: url)
		let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_000))
		try file.read(into: buffer)

		#expect(buffer.frameLength == 1_000)
		let channel = try #require(buffer.floatChannelData?[0])
		for index in 0 ..< input.count {
			#expect(channel[index] == input[index])
		}
	}

	@Test
	func aTruncatedFileIsRepairedToTheFramesThatSurvive() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")

		let writer = try DurableAudioWriter(url: url)
		try writer.append(samples(count: 32_000))
		try writer.finish()

		// A kill that caught the tail mid-write: the header still claims the full recording.
		let fullLength = try fileLength(url)
		let truncatedLength = 44 + (fullLength - 44) / 2
		try truncate(url, to: truncatedLength)

		let duration = try DurableAudioWriter.repairHeader(at: url)
		let expectedFrames = (truncatedLength - 44) / 4
		#expect(duration == Double(expectedFrames) / 16_000)

		let file = try AVAudioFile(forReading: url)
		#expect(file.length == AVAudioFramePosition(expectedFrames))
	}

	@Test
	func aStaleZeroedHeaderIsRecoveredFromTheFileLength() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")

		let writer = try DurableAudioWriter(url: url)
		try writer.append(samples(count: 24_000))
		try writer.finish()

		// Exactly what an unfinalised recording looks like: the sizes were never patched.
		try writeUInt32(0, at: 4, in: url)
		try writeUInt32(0, at: 40, in: url)

		let duration = try DurableAudioWriter.repairHeader(at: url)

		#expect(duration == 1.5)
		let file = try AVAudioFile(forReading: url)
		#expect(file.length == 24_000)
	}

	@Test
	func appendingAfterACheckpointKeepsTheHeaderTracking() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("hex-capture-\(UUID().uuidString).wav")

		let writer = try DurableAudioWriter(url: url)
		try writer.append(samples(count: 8_000))
		try writer.checkpoint()
		try writer.append(samples(count: 4_000))
		try writer.checkpoint()

		let length = try fileLength(url)
		#expect(try readUInt32(at: 4, in: url) == UInt32(length - 8))
		#expect(try readUInt32(at: 40, in: url) == UInt32(length - 44))

		let file = try AVAudioFile(forReading: url)
		#expect(file.length == 12_000)
	}

	@Test
	func repairReturnsNilForAFileTooShortToHoldAHeader() throws {
		let directory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("stub.wav")
		try Data(repeating: 0, count: 20).write(to: url)

		#expect(try DurableAudioWriter.repairHeader(at: url) == nil)
	}
}
