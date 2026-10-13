import Foundation

/// Cleans up recordings stranded in the temp directory.
///
/// Hex writes an in-progress recording to `temporaryDirectory` and normally moves it into
/// history when the recording finishes. Every path that abandons a recording — a crash, a
/// force quit, a stop request superseded by a newer session — left the file behind and
/// nothing ever deleted it. One Hex container had accumulated 1.3 GB across 1044 of these,
/// including a single six-hour recording from a session that never stopped, and a leftover
/// whose contents were mostly uninitialised memory.
///
/// Recording sessions last seconds, so a file still sitting in temp after `minimumAge` is
/// stranded by definition. The age gate is deliberately generous so an in-flight recording
/// can never be swept out from under the recorder.
public enum OrphanedRecordingCleanup {
    /// Filename prefixes Hex uses for in-progress recordings.
    public static let fileNamePrefixes = ["hex-capture-", "hex-recording-"]
    /// Generous compared to any real recording, so an active session is never touched.
    public static let defaultMinimumAge: TimeInterval = 60 * 60

    /// Matches only the exact names Hex writes — `hex-capture-<UUID>.wav` and
    /// `hex-recording-<UUID>.wav` — so the sweep can never delete something that merely
    /// shares a prefix.
    public static func isOrphanedRecording(_ fileName: String) -> Bool {
        guard fileName.hasSuffix(".wav") else { return false }
        let stem = String(fileName.dropLast(".wav".count))
        for prefix in fileNamePrefixes where stem.hasPrefix(prefix) {
            let identifier = String(stem.dropFirst(prefix.count))
            if UUID(uuidString: identifier) != nil { return true }
        }
        return false
    }

    public struct Result: Equatable, Sendable {
        public var files: Int = 0
        public var bytes: Int64 = 0
    }

    /// Deletes stranded recordings from `directory` and reports what was reclaimed.
    @discardableResult
    public static func run(
        in directory: URL,
        minimumAge: TimeInterval = OrphanedRecordingCleanup.defaultMinimumAge,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Result {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Result()
        }

        var result = Result()
        for url in entries {
            guard isOrphanedRecording(url.lastPathComponent) else { continue }

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let modifiedAt = values?.contentModificationDate else { continue }
            guard now.timeIntervalSince(modifiedAt) >= minimumAge else { continue }

            do {
                try fileManager.removeItem(at: url)
            } catch {
                continue
            }
            result.files += 1
            result.bytes += Int64(values?.fileSize ?? 0)
        }

        return result
    }
}
