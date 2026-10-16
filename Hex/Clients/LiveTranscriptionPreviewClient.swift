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
extension SharedReaderKey where Self == InMemoryKey<String>.Default {
    /// Text the preview has decoded so far: written by the decoder, read by the indicator.
    ///
    /// Deliberately shared state rather than a TCA action. The decode finishes long after the
    /// effect that started it has returned, and TCA's `Send` silently drops actions based on
    /// task cancellation, so routing this through an action made it depend on effect lifetime
    /// in a way that kept breaking.
    static var livePreviewText: Self {
        Self[.inMemory("livePreviewText"), default: ""]
    }
}

@DependencyClient
struct LiveTranscriptionPreviewClient {
    var begin: @Sendable () async -> Void
    var append: @Sendable (_ samples: [Float]) async -> Void
    var end: @Sendable () async -> Void
}

extension LiveTranscriptionPreviewClient: DependencyKey {
    public static var liveValue: LiveTranscriptionPreviewClient {
        let live = LiveTranscriptionPreviewLive()
        return LiveTranscriptionPreviewClient(
            begin: { await live.begin() },
            append: { await live.append($0) },
            end: { await live.end() }
        )
    }

    public static let testValue = LiveTranscriptionPreviewClient(
        begin: {},
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
    /// Peak below which a window holds no speech-level energy. Silence makes the decoder
    /// hallucinate (a quiet window reliably produces things like "Thank you."), so a silent
    /// window is not decoded at all. Peak rather than RMS so a brief utterance inside a longer
    /// window is not averaged away. Calibrated against real recordings: room-tone peaks sit
    /// near 0.01 and speech peaks near 0.07-0.17.
    static let silencePeak: Double = 0.03

    @Dependency(\.transcription) var transcription

    @Shared(.livePreviewText) var livePreviewText: String

    private var samples: [Float] = []
    private var refreshTask: Task<Void, Never>?
    private var isRunning = false
    private var lastText = ""
    private var didLogFirstSamples = false
    private var isDecoding = false

    /// Reused rather than recreated, so a crash can strand at most one small scratch file.
    private let scratchURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("hex-live-preview.wav")

    func begin() {
        $livePreviewText.withLock { $0 = "" }
        samples.removeAll(keepingCapacity: true)
        lastText = ""
        isRunning = true
        didLogFirstSamples = false

        previewLogger.notice("Live preview: session started")

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
            previewLogger.debug("Live preview: refresh loop exited")
        }
    }

    func append(_ newSamples: [Float]) {
        guard isRunning else { return }
        samples.append(contentsOf: newSamples)

        if !didLogFirstSamples {
            didLogFirstSamples = true
            previewLogger.notice("Live preview: first audio arrived, \(newSamples.count) samples")
        }

        let capacity = Int(Self.windowDuration * Self.sampleRate)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    func end() {
        if isRunning {
            previewLogger.notice("Live preview: session ended with \(self.samples.count) samples buffered")
        }
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
        $livePreviewText.withLock { $0 = "" }
        samples.removeAll(keepingCapacity: false)
        lastText = ""
        try? FileManager.default.removeItem(at: scratchURL)
    }

    private func refresh() async {
        // A decode takes longer than the refresh interval, and this actor is re-entrant across
        // `await`, so without this guard the next tick would rewrite the scratch file while the
        // previous decode was still reading it — the decoder then reads a half-written file and
        // returns nothing.
        guard !isDecoding else {
            previewLogger.debug("Live preview: previous decode still running, skipping tick")
            return
        }

        let minimumSamples = Int(Self.minimumWindowDuration * Self.sampleRate)
        previewLogger.debug(
            "Live preview: tick running=\(self.isRunning) samples=\(self.samples.count) needed=\(minimumSamples)"
        )
        guard isRunning, samples.count >= minimumSamples else { return }

        isDecoding = true
        defer { isDecoding = false }

        // Snapshot so audio arriving mid-decode does not mutate the window under us.
        let window = samples

        // Nothing said yet: decoding would only invent words and burn inference.
        guard hasSpeechEnergy(window) else {
            previewLogger.debug("Live preview: window is silent, skipping decode")
            return
        }

        @Shared(.hexSettings) var hexSettings: HexSettings
        let model = hexSettings.selectedModel
        guard !model.isEmpty else {
            previewLogger.error("Live preview: no model selected, skipping")
            return
        }
        let language = hexSettings.outputLanguage

        do {
            try writeScratchFile(window)
            previewLogger.debug("Live preview: decoding \(String(format: "%.1f", Double(window.count) / Self.sampleRate))s window")
            let text = try await transcription.transcribe(
                scratchURL,
                model,
                DecodingOptions(
                    language: language,
                    detectLanguage: language == nil,
                    chunkingStrategy: .vad
                )
            ) { _ in }

            previewLogger.debug("Live preview: decoded text length \(text.count)")

            // Dropped if the recording ended while this decode was in flight.
            guard isRunning, text != lastText else { return }
            lastText = text
            previewLogger.notice("Live preview: publishing \(text.count) characters")
            $livePreviewText.withLock { $0 = text }
        } catch {
            previewLogger.debug("Live preview decode failed: \(error.localizedDescription)")
        }
    }

    /// True when the window carries speech-level energy rather than room tone.
    private func hasSpeechEnergy(_ samples: [Float]) -> Bool {
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        return Double(peak) > Self.silencePeak
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
