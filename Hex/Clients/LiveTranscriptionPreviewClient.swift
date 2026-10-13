import AVFoundation
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import WhisperKit

private let previewLogger = HexLog.transcription

/// Shows what the transcriber is hearing *while* you are still speaking.
///
/// The final transcript always comes from decoding the finished recording, so this is only a
/// preview — which is what makes it affordable. It keeps a short rolling window of the most
/// recent audio and re-decodes that on a timer instead of trying to stream a partial decode:
///
/// - A window rather than the whole recording keeps the cost flat no matter how long you talk.
///   Re-decoding everything so far would grow quadratically and fall behind on long dictation.
/// - It reuses the model that is already loaded. FluidAudio's true streaming engines
///   (`StreamingEouAsrManager`, Nemotron) are separate models, and the TDT model Hex uses is
///   explicitly not streaming-capable, so a second model would have to be downloaded and held
///   in memory for what is only a preview.
/// - The scratch file is reused in place, so nothing accumulates on disk.
@DependencyClient
struct LiveTranscriptionPreviewClient {
    var begin: @Sendable (_ onText: @escaping @Sendable (String) async -> Void) async -> Void
    var append: @Sendable (_ samples: [Float]) async -> Void
    var end: @Sendable () async -> Void
}

extension LiveTranscriptionPreviewClient: DependencyKey {
    public static var liveValue: LiveTranscriptionPreviewClient {
        let live = LiveTranscriptionPreviewLive()
        return LiveTranscriptionPreviewClient(
            begin: { await live.begin(onText: $0) },
            append: { await live.append($0) },
            end: { await live.end() }
        )
    }

    public static let testValue = LiveTranscriptionPreviewClient(
        begin: { _ in },
        append: { _ in },
        end: {}
    )
}

extension DependencyValues {
    var livePreview: LiveTranscriptionPreviewClient {
        get { self[LiveTranscriptionPreviewClient.self] }
        set { self[LiveTranscriptionPreviewClient.self] = newValue }
    }
}

actor LiveTranscriptionPreviewLive {
    /// How much recent audio is decoded. Long enough to hold a phrase, short enough that
    /// re-decoding it stays cheap.
    static let windowDuration: TimeInterval = 6
    static let sampleRate: Double = 16_000
    /// How often the window is re-decoded. Cost is bounded by `windowDuration`, not by how
    /// long the recording runs.
    static let refreshInterval: Duration = .milliseconds(1_200)
    /// Below this there is not enough audio to say anything useful yet.
    static let minimumWindowDuration: TimeInterval = 0.6

    @Dependency(\.transcription) var transcription

    private var samples: [Float] = []
    private var onText: (@Sendable (String) async -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var isRunning = false
    private var lastText = ""

    /// Reused rather than recreated, so a crash can strand at most one small scratch file.
    private let scratchURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("hex-live-preview.wav")

    func begin(onText: @escaping @Sendable (String) async -> Void) {
        self.onText = onText
        samples.removeAll(keepingCapacity: true)
        lastText = ""
        isRunning = true

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func append(_ newSamples: [Float]) {
        guard isRunning else { return }
        samples.append(contentsOf: newSamples)

        let capacity = Int(Self.windowDuration * Self.sampleRate)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    func end() {
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
        onText = nil
        samples.removeAll(keepingCapacity: false)
        lastText = ""
        try? FileManager.default.removeItem(at: scratchURL)
    }

    private func refresh() async {
        let minimumSamples = Int(Self.minimumWindowDuration * Self.sampleRate)
        guard isRunning, samples.count >= minimumSamples else { return }

        // Snapshot so audio arriving mid-decode does not mutate the window under us.
        let window = samples

        @Shared(.hexSettings) var hexSettings: HexSettings
        let model = hexSettings.selectedModel
        guard !model.isEmpty else { return }
        let language = hexSettings.outputLanguage

        do {
            try writeScratchFile(window)
            let text = try await transcription.transcribe(
                scratchURL,
                model,
                DecodingOptions(
                    language: language,
                    detectLanguage: language == nil,
                    chunkingStrategy: .vad
                )
            ) { _ in }

            // Dropped if the recording ended while this decode was in flight.
            guard isRunning, text != lastText else { return }
            lastText = text
            await onText?(text)
        } catch {
            previewLogger.debug("Live preview decode failed: \(error.localizedDescription)")
        }
    }

    private func writeScratchFile(_ samples: [Float]) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            buffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
        }

        try? FileManager.default.removeItem(at: scratchURL)

        // Scoped so the writer is closed (finalising the WAV header) before the decoder reads
        // it back. An open AVAudioFile leaves the file unreadable.
        do {
            let file = try AVAudioFile(
                forWriting: scratchURL,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: true,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
    }
}
