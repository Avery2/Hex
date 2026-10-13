import Foundation

/// What happened to a recording once Hex stopped listening.
///
/// Hex used to delete the audio for anything that did not end in a paste, which meant the
/// words were gone the moment you hit Escape or a transcription failed. Keeping the status
/// on the record lets those recordings survive in history and be recovered instead.
public enum TranscriptStatus: String, Codable, Equatable, Sendable {
    /// Transcribed and pasted into the frontmost app — the normal path.
    case pasted
    /// The user cancelled (Escape) after speaking. Kept so the words can be recovered
    /// with "Paste Last Transcript" rather than disappearing.
    case notPasted
    /// Transcription failed. The audio is kept so nothing that was said is lost.
    case failed

    public var wasPasted: Bool { self == .pasted }
}

public struct Transcript: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var text: String
    public var audioPath: URL
    public var duration: TimeInterval
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    /// Defaults to `.pasted` for history written before this field existed.
    public var status: TranscriptStatus

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        text: String,
        audioPath: URL,
        duration: TimeInterval,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        status: TranscriptStatus = .pasted
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.audioPath = audioPath
        self.duration = duration
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case text
        case audioPath
        case duration
        case sourceAppBundleID
        case sourceAppName
        case status
    }

    /// Hand-written so existing history files — which predate `status` — keep decoding.
    /// A missing status means the entry came from a version that only ever stored pasted
    /// transcripts, so `.pasted` is the honest default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        text = try container.decode(String.self, forKey: .text)
        audioPath = try container.decode(URL.self, forKey: .audioPath)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        sourceAppBundleID = try container.decodeIfPresent(String.self, forKey: .sourceAppBundleID)
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        status = try container.decodeIfPresent(TranscriptStatus.self, forKey: .status) ?? .pasted
    }
}

public struct TranscriptionHistory: Codable, Equatable, Sendable {
    public var history: [Transcript] = []

    public init(history: [Transcript] = []) {
        self.history = history
    }
}
