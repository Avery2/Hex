import AVFoundation
import Foundation
import Testing
@testable import HexCore

@Suite("Audio compressor")
struct AudioCompressorTests {
  /// A short 16-bit WAV of a sine wave, written the way a real recording would be.
  private func makeWav(seconds: Double = 2) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("compress-\(UUID().uuidString).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let frames = AVAudioFrameCount(16_000 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let channel = buffer.floatChannelData![0]
    for index in 0..<Int(frames) {
      channel[index] = Float(sin(Double(index) / 30)) * 0.3
    }
    let file = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ])
    try file.write(from: buffer)
    return url
  }

  @Test("Produces a smaller m4a with the same audio")
  func compresses() throws {
    let url = try makeWav()
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int

    let result = try AudioCompressor.compress(url)

    #expect(result.bytesAfter < before / 2)
    #expect(result.compressedURL.pathExtension == "m4a")
    #expect(!FileManager.default.fileExists(atPath: url.path), "the original is replaced")
    let decoded = try AVAudioFile(forReading: result.compressedURL)
    #expect(abs(Double(decoded.length) / 16_000 - 2.0) < 0.3)
  }

  @Test("A file that cannot be read is refused, not deleted")
  func refusesGarbage() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("garbage-\(UUID().uuidString).wav")
    try Data("not audio".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: AudioCompressor.Failure.self) {
      try AudioCompressor.compress(url)
    }
    #expect(FileManager.default.fileExists(atPath: url.path))
  }
}
