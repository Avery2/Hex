import Accelerate
import Foundation

/// Rewrites a finished recording as 16-bit PCM instead of 32-bit float.
///
/// Every sample this app writes is a 4-byte `float`. Speech does not need that: 16-bit PCM still
/// gives ~96 dB of dynamic range, which is more than a microphone delivers, so the extra two bytes
/// per sample are headroom nothing uses. Halving them halves the recording — 3.84 MB/min becomes
/// 1.92 — and the file stays a plain WAV, so nothing downstream has to change.
///
/// Only ever applied to a take that has already been transcribed and moved into `Recordings`, so the
/// live recording path keeps its float format and its crash-recovery behaviour untouched.
public enum WavCompactor {
  public struct Result: Equatable, Sendable {
    public let bytesBefore: Int
    public let bytesAfter: Int
  }

  /// Converts in place. Returns nil when there is nothing to do (already 16-bit, or not a file this
  /// app wrote).
  @discardableResult
  public static func compactTo16Bit(at url: URL) throws -> Result? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    guard let header = try handle.read(upToCount: 44), header.count == 44,
          header.prefix(4) == Data("RIFF".utf8),
          header[8..<12] == Data("WAVE".utf8),
          header[12..<16] == Data("fmt ".utf8),
          header[36..<40] == Data("data".utf8)
    else { return nil }

    func integer(_ range: Range<Int>) -> UInt32 {
      header[range].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    let formatTag = UInt16(integer(20..<22))
    let channels = UInt16(integer(22..<24))
    let bitsPerSample = UInt16(integer(34..<36))
    // Only the exact shape this app writes: mono, 32-bit IEEE float.
    guard formatTag == 3, channels == 1, bitsPerSample == 32 else { return nil }

    let sampleRate = integer(24..<28)
    let before = Int(try handle.seekToEnd())
    guard before > 44 else { return nil }

    let tempURL = url.deletingLastPathComponent()
      .appendingPathComponent("\(url.lastPathComponent).16bit")
    FileManager.default.removeItemIfExists(at: tempURL)
    guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }

    let output = try FileHandle(forWritingTo: tempURL)
    let frameCount = (before - 44) / 4
    let result = Result(bytesBefore: before, bytesAfter: 44 + frameCount * 2)
    do {
      try output.write(contentsOf: canonicalHeader(sampleRate: sampleRate, dataBytes: UInt32(result.bytesAfter - 44)))

      // Stream it: some takes are 300 MB, and this runs while the app is otherwise idle.
      _ = try handle.seek(toOffset: 44)
      var converted = 0
      while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
        let count = chunk.count / 4
        try chunk.withUnsafeBytes { raw in
          guard let floats = raw.bindMemory(to: Float.self).baseAddress else { return }
          // Vectorised: scale into int16 range, then convert in bulk. Sampling this by hand in Swift
          // took minutes for a 4 GB shelf; Accelerate does it at memory speed.
          var scaled = [Float](repeating: 0, count: count)
          var factor = Float(32_767)
          vDSP_vsmul(floats, 1, &factor, &scaled, 1, vDSP_Length(count))
          var samples = [Int16](repeating: 0, count: count)
          vDSP_vfix16(&scaled, 1, &samples, 1, vDSP_Length(count))
          try output.write(contentsOf: samples.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        converted += count
      }
      guard converted == (before - 44) / 4 else {
        throw CocoaError(.fileWriteUnknown)
      }

      try output.synchronize()
      try output.close()

      // Swap the finished file into place in one step: a half-written file must never be the one
      // history points at.
      _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
      return result
    } catch {
      try? output.close()
      FileManager.default.removeItemIfExists(at: tempURL)
      throw error
    }
  }

  /// The same 44-byte canonical header `DurableAudioWriter` writes, with 16-bit PCM fields.
  private static func canonicalHeader(sampleRate: UInt32, dataBytes: UInt32) -> Data {
    var data = Data(capacity: 44)
    func append(_ value: some FixedWidthInteger) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(dataBytes &+ 36)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    append(UInt32(16))
    append(UInt16(1)) // WAVE_FORMAT_PCM
    append(UInt16(1)) // mono
    append(sampleRate)
    append(sampleRate * 2) // byte rate
    append(UInt16(2)) // block align
    append(UInt16(16)) // bits per sample
    data.append(contentsOf: Array("data".utf8))
    append(dataBytes)
    return data
  }
}
