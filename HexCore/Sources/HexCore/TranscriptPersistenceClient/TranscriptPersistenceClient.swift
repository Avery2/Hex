import Dependencies
import Foundation

public struct TranscriptPersistenceClient: Sendable {
    public var save: @Sendable (
        _ result: String,
        _ audioURL: URL,
        _ duration: TimeInterval,
        _ sourceAppBundleID: String?,
        _ sourceAppName: String?,
        _ status: TranscriptStatus
    ) async throws -> Transcript
    
    public var deleteAudio: @Sendable (_ transcript: Transcript) async throws -> Void
}

extension TranscriptPersistenceClient: DependencyKey {
    public static let liveValue: TranscriptPersistenceClient = {
        return TranscriptPersistenceClient(
            save: { result, audioURL, duration, sourceAppBundleID, sourceAppName, status in
                let fm = FileManager.default
                let recordingsFolder = try URL.hexApplicationSupport.appendingPathComponent("Recordings", isDirectory: true)
                try fm.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)

                // Two recordings can finish inside the same millisecond (a cancel landing on
                // top of a stop), which used to make the second move fail and lose the audio.
                let base = Date().timeIntervalSince1970
                var finalURL = recordingsFolder.appendingPathComponent("\(base).wav")
                var attempt = 1
                while fm.fileExists(atPath: finalURL.path) {
                    finalURL = recordingsFolder.appendingPathComponent("\(base)-\\(attempt).wav")
                    attempt += 1
                }
                try fm.moveItem(at: audioURL, to: finalURL)

                return Transcript(
                    timestamp: Date(),
                    text: result,
                    audioPath: finalURL,
                    duration: duration,
                    sourceAppBundleID: sourceAppBundleID,
                    sourceAppName: sourceAppName,
                    status: status
                )
            },
            deleteAudio: { transcript in
                FileManager.default.removeItemIfExists(at: transcript.audioPath)
            }
        )
    }()
    
    public static let testValue = TranscriptPersistenceClient(
        save: { _, _, _, _, _, status in
            Transcript(
                timestamp: Date(),
                text: "",
                audioPath: URL(fileURLWithPath: "/"),
                duration: 0,
                status: status
            )
        },
        deleteAudio: { _ in }
    )
}

public extension DependencyValues {
    var transcriptPersistence: TranscriptPersistenceClient {
        get { self[TranscriptPersistenceClient.self] }
        set { self[TranscriptPersistenceClient.self] = newValue }
    }
}
