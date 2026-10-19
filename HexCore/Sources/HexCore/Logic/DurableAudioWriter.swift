import Foundation

/// Writes the 16 kHz mono 32-bit float WAV that Hex records, so the file can be opened at
/// every instant rather than only once it is closed.
///
/// `AVAudioFile` only writes the RIFF and `data` chunk sizes when it closes, so a crash, a
/// force quit, or a power loss mid-recording leaves the audio bytes on disk behind a header
/// that reports zero frames and cannot be opened. This writer inverts that: it lays down a
/// complete header up front and patches the two size fields to match the bytes actually
/// written, so the file is a playable WAV at any truncation point.
///
/// `checkpoint()` is the durability boundary. It flushes appended audio to stable storage
/// before recording the new sizes, then flushes the sizes, so a power loss can never leave a
/// header claiming more audio than the file holds.
public final class DurableAudioWriter {
    public static let sampleRate: Double = 16_000
    /// Canonical RIFF/WAVE header: RIFF(12) + fmt(24) + data(8).
    public static let headerSize = 44
    public static let bytesPerFrame = 4

    public enum Error: Swift.Error, Equatable {
        case couldNotCreateFile(URL)
        case writerAlreadyFinished
        case audioExceedsRIFFLimit
    }

    private let handle: FileHandle
    private var isFinished = false

    public init(url: URL) throws {
        // A complete, self-consistent header from the first byte. The sizes start at zero and
        // are patched forward as audio arrives.
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Self.header(dataByteCount: 0)
        ) else {
            throw Error.couldNotCreateFile(url)
        }
        self.handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
    }

    deinit {
        // A writer that was never finished still owns a descriptor; release it rather than leak
        // it. Anything appended since the last checkpoint is already on disk but not yet
        // declared, so the header is left short rather than over-claiming — `repairHeader`
        // recovers those frames from the file length.
        if !isFinished { try? handle.close() }
    }

    /// Appends mono float samples at the end of the file. The header is deliberately left alone
    /// so the hot path stays a single write: between checkpoints the file under-declares by up
    /// to one interval, which is recoverable via `repairHeader`, whereas over-declaring would
    /// promise audio that may not have reached disk.
    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard !isFinished else { throw Error.writerAlreadyFinished }
        // Float is IEEE-754 on macOS and the platform is little-endian, so the raw bit
        // patterns are already the bytes the header describes.
        let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.write(contentsOf: bytes)
    }

    /// Makes everything appended so far durable and updates the header sizes to match.
    public func checkpoint() throws {
        guard !isFinished else { throw Error.writerAlreadyFinished }
        try flushHeader()
    }

    /// Flushes the final sizes and closes the file. The file is readable before this call and
    /// remains readable after it.
    public func finish() throws {
        guard !isFinished else { return }
        try flushHeader()
        try handle.close()
        isFinished = true
    }

    /// Rewrites the RIFF and `data` sizes from the file's real length and returns the audio
    /// duration. Recovery calls this on recordings whose header was never finalised.
    ///
    /// Returns `nil` when the file is shorter than a header, i.e. it cannot be a WAV at all.
    @discardableResult
    public static func repairHeader(at url: URL) throws -> TimeInterval? {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let fileLength = try handle.seekToEnd()
        guard fileLength >= UInt64(headerSize) else { return nil }

        try patchSizes(in: handle, fileLength: fileLength)
        try handle.synchronize()

        let frames = (fileLength - UInt64(headerSize)) / UInt64(bytesPerFrame)
        return Double(frames) / sampleRate
    }

    private func flushHeader() throws {
        // Audio first: if the header reached disk before its data, a power loss would leave a
        // file claiming frames it does not have.
        try handle.synchronize()
        let fileLength = try handle.seekToEnd()
        try Self.patchSizes(in: handle, fileLength: fileLength)
        try handle.synchronize()
        // Back to the end so the next append stays contiguous.
        _ = try handle.seekToEnd()
    }

    private static func patchSizes(in handle: FileHandle, fileLength: UInt64) throws {
        guard fileLength >= UInt64(headerSize),
              fileLength - 8 <= UInt64(UInt32.max),
              fileLength - UInt64(headerSize) <= UInt64(UInt32.max)
        else {
            throw Error.audioExceedsRIFFLimit
        }

        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: UInt32(fileLength - 8).littleEndianData)
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: UInt32(fileLength - UInt64(headerSize)).littleEndianData)
    }

    private static func header(dataByteCount: UInt32) -> Data {
        var data = Data(capacity: headerSize)
        data.append(contentsOf: Array("RIFF".utf8))
        // RIFF size is everything after this field: the file length minus 8.
        data.append(contentsOf: (dataByteCount &+ 36).littleEndianData)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: UInt32(16).littleEndianData) // fmt chunk size
        data.append(contentsOf: UInt16(3).littleEndianData) // WAVE_FORMAT_IEEE_FLOAT
        data.append(contentsOf: UInt16(1).littleEndianData) // mono
        data.append(contentsOf: UInt32(sampleRate).littleEndianData)
        data.append(contentsOf: (UInt32(sampleRate) * UInt32(bytesPerFrame)).littleEndianData)
        data.append(contentsOf: UInt16(bytesPerFrame).littleEndianData) // block align
        data.append(contentsOf: UInt16(32).littleEndianData) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: dataByteCount.littleEndianData)
        return data
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
