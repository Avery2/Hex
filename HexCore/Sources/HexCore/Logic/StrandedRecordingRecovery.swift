import AVFoundation
import Foundation

/// Recovers recordings stranded in the temp directory by a crash, a force quit, or a stop
/// request that never arrived.
///
/// Hex writes an in-progress recording to `temporaryDirectory` and moves it into history when
/// the recording finishes, so every path that abandons one leaves the file behind. These were
/// previously cleaned up by age, which asks the wrong question: a recording is either empty or
/// it holds something worth keeping, and deleting on a timer risks throwing away words.
///
/// So this asks about content instead:
///
/// - **Opens and holds frames** → a real recording, handed back for recovery.
/// - **Opens and holds nothing** → the session captured no audio at all, so it is removed.
/// - **Will not open** → left alone. Nothing is deleted that cannot be inspected first.
///
/// The `before` cut-off is what makes this safe to run while the app is live: anything written
/// after the current launch is by definition still in use, and recordings are uniquely named,
/// so a snapshot taken at launch can never collide with one started later in the same session.
public enum StrandedRecordingRecovery {
    /// Filename prefixes Hex uses for in-progress recordings.
    public static let fileNamePrefixes = ["hex-capture-", "hex-recording-"]

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
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var recovered: [(modified: Date, recording: StrandedRecording)] = []

        for url in entries {
            guard isStrandedRecordingName(url.lastPathComponent) else { continue }

            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            // No timestamp, or written after launch: treat it as live and leave it alone.
            guard let modified, modified < cutoff else { continue }

            guard let file = try? AVAudioFile(forReading: url) else {
                // Unreadable: keep it rather than destroy something that cannot be checked.
                continue
            }

            guard file.length > 0 else {
                try? fileManager.removeItem(at: url)
                continue
            }

            let duration = Double(file.length) / file.processingFormat.sampleRate
            recovered.append((modified, StrandedRecording(url: url, duration: duration)))
        }

        return recovered
            .sorted { $0.modified < $1.modified }
            .map(\.recording)
    }
}
