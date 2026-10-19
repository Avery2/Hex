import Foundation

/// Recovers recordings stranded in the temp directory by a crash, a force quit, or a stop
/// request that never arrived.
///
/// Hex writes an in-progress recording to `temporaryDirectory` and moves it into history when
/// the recording finishes, so every path that abandons one leaves the file behind. These were
/// previously cleaned up by age, which asks the wrong question: a recording is either empty or
/// it holds something worth keeping, and deleting on a timer risks throwing away words.
///
/// Asking the WAV header is also the wrong question. A crash can interrupt a recording before
/// the RIFF and `data` sizes are written, so `AVAudioFile` reports zero frames for a file that
/// holds megabytes of real speech. Size is the honest signal, and the format is fixed — 16kHz
/// mono 32-bit float behind a canonical 44-byte header — so the payload, and therefore the
/// duration, follows from the byte count alone:
///
/// - **Holds at least one frame** → a real recording, handed back for recovery.
/// - **Holds no complete frame** → the session captured no audio at all, so it is removed.
/// - **Cannot be measured** → left alone. Nothing is deleted that cannot be inspected first,
///   and a zero-length file is kept rather than guessed at.
///
/// The `before` cut-off is what makes this safe to run while the app is live: anything written
/// after the current launch is by definition still in use, and recordings are uniquely named,
/// so a snapshot taken at launch can never collide with one started later in the same session.
public enum StrandedRecordingRecovery {
    /// Filename prefixes Hex uses for in-progress recordings.
    public static let fileNamePrefixes = ["hex-capture-", "hex-recording-"]

    /// Every capture is 16kHz mono 32-bit float, so a frame is four bytes behind a canonical
    /// 44-byte RIFF/WAVE header. Duration is derived from these, never from the header's own
    /// size fields, which may still be zeroed when a crash cuts a recording short.
    private static let headerBytes = 44
    private static let bytesPerFrame = 4
    private static let sampleRate: Double = 16_000

    public struct StrandedRecording: Equatable, Sendable {
        public let url: URL
        public let duration: TimeInterval

        public init(url: URL, duration: TimeInterval) {
            self.url = url
            self.duration = duration
        }
    }

    /// Matches only the exact names Hex writes — `hex-capture-<UUID>.wav` and
    /// `hex-recording-<UUID>.wav` — so nothing that merely shares a prefix is ever touched.
    public static func isStrandedRecordingName(_ fileName: String) -> Bool {
        guard fileName.hasSuffix(".wav") else { return false }
        let stem = String(fileName.dropLast(".wav".count))
        for prefix in fileNamePrefixes where stem.hasPrefix(prefix) {
            let identifier = String(stem.dropFirst(prefix.count))
            if UUID(uuidString: identifier) != nil { return true }
        }
        return false
    }

    /// Collects recordings left behind by earlier sessions, removing the ones that captured
    /// nothing. Returns them oldest-first so recovery happens in the order they were spoken.
    @discardableResult
    public static func collect(
        in directory: URL,
        before cutoff: Date,
        fileManager: FileManager = .default
    ) -> [StrandedRecording] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var recovered: [(modified: Date, recording: StrandedRecording)] = []

        for url in entries {
            guard isStrandedRecordingName(url.lastPathComponent) else { continue }

            let values = try? url.resourceValues(forKeys: keys)
            // No timestamp, or written after launch: treat it as live and leave it alone.
            guard let modified = values?.contentModificationDate, modified < cutoff else { continue }

            // Directories, entries that cannot be read, and files that vanished between the
            // directory listing and this call cannot be measured, so they are not ours to
            // delete. A zero-length file is treated the same way: there is nothing to inspect,
            // and the cost of leaving it is lower than the cost of a wrong deletion.
            guard values?.isRegularFile == true,
                  let fileSize = values?.fileSize,
                  fileSize > 0
            else { continue }

            let payloadBytes = fileSize - headerBytes
            guard payloadBytes >= bytesPerFrame else {
                // A header and no complete frame: an aborted session that captured nothing.
                try? fileManager.removeItem(at: url)
                continue
            }

            // Frames come from the file's length, not its header, so a recording whose sizes
            // were never finalised is still handed back with the right duration.
            let frames = payloadBytes / bytesPerFrame
            recovered.append((modified, StrandedRecording(
                url: url,
                duration: Double(frames) / sampleRate
            )))
        }

        return recovered
            .sorted { $0.modified < $1.modified }
            .map(\.recording)
    }
}
