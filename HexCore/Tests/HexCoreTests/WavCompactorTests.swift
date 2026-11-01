import Foundation
import Testing
@testable import HexCore

@Suite("WAV compaction")
struct WavCompactorTests {
  /// A short float32 recording, written the way the recorder writes one.
  private func makeFloatWav(samples: [Float]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("compact-\(UUID().uuidString).wav")
    var data = Data()
    func append(_ value: some FixedWidthInteger) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + samples.count * 4))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    append(UInt32(16))
    append(UInt16(3))          // IEEE float
    append(UInt16(1))
    append(UInt32(16_000))
    append(UInt32(64_000))
    append(UInt16(4))
    append(UInt16(32))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(samples.count * 4))
    samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    try data.write(to: url)
    return url
  }

  @Test("Halves the file and keeps the audio")
  func halvesTheFile() throws {
    let samples = (0..<16_000).map { Float(sin(Double($0) / 40)) * 0.5 }
    let url = try makeFloatWav(samples: samples)
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try Data(contentsOf: url).count

    let result = try WavCompactor.compactTo16Bit(at: url)
    let after = try Data(contentsOf: url).count

    #expect(result?.bytesBefore == before)
    #expect(after == 44 + (before - 44) / 2, "header stays, samples halve")
    #expect(result?.bytesAfter == after)

    // Header now says 16-bit PCM, and the sample count is unchanged.
    let header = try Data(contentsOf: url).prefix(44)
    #expect(header[20] == 1)      // WAVE_FORMAT_PCM
    #expect(header[34] == 16)     // bits per sample
    #expect((after - 44) / 2 == samples.count)
  }

  @Test("Compacting twice changes nothing")
  func idempotent() throws {
    let url = try makeFloatWav(samples: Array(repeating: 0.25, count: 1_000))
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try WavCompactor.compactTo16Bit(at: url)
    let once = try Data(contentsOf: url)
    let second = try WavCompactor.compactTo16Bit(at: url)
    #expect(second == nil)
    #expect(try Data(contentsOf: url) == once)
  }

  @Test("A file it did not write is left alone")
  func ignoresForeignFiles() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("foreign-\(UUID().uuidString).wav")
    try Data("not a riff file at all, really".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try WavCompactor.compactTo16Bit(at: url) == nil)
  }
}
