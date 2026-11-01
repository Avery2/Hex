import AVFoundation
import Foundation

/// Encodes a finished recording to AAC.
///
/// Only used when the recordings shelf has run past its budget, and only for takes whose transcript
/// exists (a failed take's audio is the only record of what was said). The rewrite is atomic: the
/// `.m4a` is written beside the original and only replaces it once it has been read back.
public enum AudioCompressor {
  public struct Result: Equatable, Sendable {
    public let compressedURL: URL
    public let bytesBefore: Int
    public let bytesAfter: Int
  }

  public enum Failure: LocalizedError {
    case unreadable(URL)
    case encodeFailed(String)

    public var errorDescription: String? {
      switch self {
      case let .unreadable(url): "Could not read \(url.lastPathComponent)"
      case let .encodeFailed(reason): "Could not encode audio: \(reason)"
      }
    }
  }

  /// Speech at 32 kbps mono is transparent enough for review, and about 1/8 of 16-bit PCM.
  public static let bitRate = 32_000

  /// Encodes `url` to AAC, deletes the original on success, and returns where the audio now lives.
  public static func compress(_ url: URL, bitRate: Int = bitRate) throws -> Result {
    let input: AVAudioFile
    do {
      input = try AVAudioFile(forReading: url)
    } catch {
      throw Failure.unreadable(url)
    }
    let format = input.processingFormat
    let frames = AVAudioFrameCount(input.length)
    guard frames > 0 else { throw Failure.encodeFailed("empty file") }

    let target = url.deletingPathExtension().appendingPathExtension("m4a")
    FileManager.default.removeItemIfExists(at: target)

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: format.sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: bitRate,
    ]
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
      throw Failure.encodeFailed("could not allocate a buffer")
    }
    do {
      // The writer has to go out of scope before the file can be read back: AVAudioFile flushes its
      // encoder in deinit, and an m4a that has not been flushed has no moov atom to read.
      let output = try AVAudioFile(forWriting: target, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
      try input.read(into: buffer)
      try output.write(from: buffer)
    } catch {
      FileManager.default.removeItemIfExists(at: target)
      throw Failure.encodeFailed(error.localizedDescription)
    }

    // Read it back before trusting it: a take is deleted on the strength of this check.
    guard let check = try? AVAudioFile(forReading: target), check.length > 0 else {
      FileManager.default.removeItemIfExists(at: target)
      throw Failure.encodeFailed("the encoded file could not be read back")
    }

    let before = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    let after = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
    guard after > 0, after < before else {
      // No point keeping a re-encode that did not save anything.
      FileManager.default.removeItemIfExists(at: target)
      throw Failure.encodeFailed("the re-encode was not smaller")
    }

    try FileManager.default.removeItem(at: url)
    return Result(compressedURL: target, bytesBefore: before, bytesAfter: after)
  }
}
