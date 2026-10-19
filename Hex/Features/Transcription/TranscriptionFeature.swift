//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State: Equatable {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    /// What the mic levels say about whether words are actually being captured.
    var speech = SpeechActivityDetector()
    /// Whether audio is actually flowing yet. The hotkey arms a recording immediately, but the
    /// capture engine can take up to a second to deliver its first buffer, and anything said in
    /// that gap is lost. The indicator must not claim to be listening before it is.
    var isCapturing: Bool = false
    /// Set briefly when a long recording ends, so its end is acknowledged rather than silent.
    var sessionSummary: String?
    /// Set when the disk refused a write, so recording stopped instead of silently dropping audio.
    var recordingFailure: String?
    /// When audio actually started flowing, so the "nothing heard" warning is measured from
    /// there rather than from the hotkey press — otherwise engine startup time counts against
    /// the user and the warning fires before they have had a chance to speak.
    var listeningSince: Date?
    var sourceAppBundleID: String?
    var sourceAppName: String?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)
    case sessionSummaryExpired
    case recordingFailed(String)
    case recordingFailureExpired

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcribe(URL, TimeInterval, TranscriptStatus)
    /// Recordings a previous session left behind, to be transcribed into history.
    case recoverStrandedRecordings([StrandedRecordingRecovery.StrandedRecording])
    case transcriptionResult(String, URL, TimeInterval, TranscriptStatus)
    case transcriptionError(Error, URL?, TimeInterval)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingStart
    case recordingCleanup
    case transcription
    case livePreviewSamples
    case sessionSummary
    case recordingFailure
    case recordingFailureMonitor
  }

  /// Past this length a capture has stopped being dictation and become a session whose loss
  /// would matter, so its end gets a distinct acknowledgement and a visible confirmation.
  static let sessionDurationThreshold: TimeInterval = 30

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.livePreview) var livePreview

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts long-lived effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        // 4) Forwarding microphone samples to the live transcription preview
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect(),
          startSampleForwardingEffect(),
          startRecordingFailureMonitoringEffect()
        )

      // MARK: - Metering

      case .sessionSummaryExpired:
        state.sessionSummary = nil
        return .none

      case let .recordingFailed(message):
        // The disk refused a write, so carrying on would keep dropping audio while the
        // indicator still claimed to record. Stop now and say why.
        guard state.isRecording else { return .none }
        transcriptionFeatureLogger.error("Recording stopped by a write failure: \(message)")
        state.recordingFailure = "Recording stopped \u{00B7} \(message)"
        return .merge(
          .send(.stopRecording),
          .run { _ in soundEffect.play(.cancel) },
          recordingFailureExpiryEffect()
        )

      case .recordingFailureExpired:
        state.recordingFailure = nil
        return .none

      case let .audioLevelUpdated(meter):
        state.meter = meter
        state.speech.ingest(averagePower: meter.averagePower)
        // Metering only flows while the capture engine has an active recording, so the first
        // frame after a start is real proof that audio is arriving.
        if state.isRecording, !state.isCapturing {
          state.isCapturing = true
          state.listeningSince = now
          let startup = state.recordingStartTime.map { now.timeIntervalSince($0) } ?? 0
          transcriptionFeatureLogger.notice(
            "Capture is live \(String(format: "%.2f", startup))s after the hotkey"
          )
        }
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .recoverStrandedRecordings(recordings):
        guard !recordings.isEmpty else { return .none }
        return .merge(
          recordings.map { recording in
            .send(.transcribe(recording.url, recording.duration, .recovered))
          }
        )

      case let .transcribe(audioURL, duration, status):
        // Set here rather than at the call sites so the cancel path shows the same
        // "transcribing" state as the normal stop path.
        state.isTranscribing = true
        state.error = nil
        return transcribeEffect(url: audioURL, duration: duration, status: status)

      case let .transcriptionResult(result, audioURL, duration, status):
        return handleTranscriptionResult(
          &state,
          result: result,
          audioURL: audioURL,
          duration: duration,
          status: status
        )

      case let .transcriptionError(error, audioURL, duration):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL, duration: duration)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

		  // Process the key event
		  switch hotKeyProcessor.process(keyEvent: keyEvent) {
		  case .startRecording:
			Task { await send(.hotKeyPressed) }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false // or `true` if you want to intercept

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            return false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  /// Feeds microphone audio to the preview decoder for the lifetime of the app, the same way
  /// metering is subscribed once. The preview itself decides whether to accumulate anything,
  /// so there is exactly one long-lived consumer of the sample stream and no per-recording
  /// subscribe/unsubscribe to get wrong.
  func startSampleForwardingEffect() -> Effect<Action> {
    .run { _ in
      for await samples in await recording.observeAudioSamples() {
        await livePreview.append(samples)
      }
    }
    .cancellable(id: CancelID.livePreviewSamples, cancelInFlight: true)
  }

  /// Begins a preview session so words appear as they are said rather than only once the
  /// recording is finished. The decoded text is published through shared state rather than a
  /// callback, so nothing here depends on this effect staying alive.
  func beginLivePreviewEffect() -> Effect<Action> {
    .run { _ in
      await livePreview.begin()
    }
  }

  func endLivePreviewEffect() -> Effect<Action> {
    .run { _ in
      await livePreview.end()
    }
  }

  /// Surfaces a write failure the moment it happens. Without this a full disk stops recording
  /// silently and the user only finds out when they stop talking.
  func startRecordingFailureMonitoringEffect() -> Effect<Action> {
    .run { send in
      for await message in await recording.observeRecordingFailures() {
        await send(.recordingFailed(message))
      }
    }
    .cancellable(id: CancelID.recordingFailureMonitor, cancelInFlight: true)
  }

  /// Clears the recording-failure notice after long enough to read.
  func recordingFailureExpiryEffect() -> Effect<Action> {
    .run { send in
      try? await Task.sleep(for: .seconds(12))
      await send(.recordingFailureExpired)
    }
    .cancellable(id: CancelID.recordingFailure, cancelInFlight: true)
  }

  /// Clears the session-ended confirmation after long enough to be noticed.
  func sessionSummaryExpiryEffect() -> Effect<Action> {
    .run { send in
      try? await Task.sleep(for: .seconds(8))
      await send(.sessionSummaryExpired)
    }
    .cancellable(id: CancelID.sessionSummary, cancelInFlight: true)
  }

  static func sessionSummaryText(duration: TimeInterval) -> String {
    let total = Int(duration.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    let clock = hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
      : String(format: "%d:%02d", minutes, seconds)
    return "Session ended \u{00B7} \(clock)"
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    guard isTranscribing else { return .send(.startRecording) }
    return .concatenate(
      .send(.cancel),
      .send(.startRecording)
    )
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    let startTime = now
    state.recordingStartTime = startTime
    state.speech.reset()
    state.isCapturing = false
    state.listeningSince = nil
    state.sessionSummary = nil
    state.recordingFailure = nil
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .cancel(id: CancelID.sessionSummary),
      .cancel(id: CancelID.recordingFailure),
      beginLivePreviewEffect(),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] _ in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }
        guard !Task.isCancelled else {
          if preventSleep {
            await sleepManagement.allowSleep()
          }
          return
        }
        await recording.startRecording()
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true)
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return handleDiscard(&state)
    }

    // Otherwise, proceed to transcription. An empty model name is handled inside
    // `transcribeEffect`, which keeps the audio instead of discarding it.
    state.isTranscribing = true
    state.error = nil
    state.isPrewarming = true

    // A session's end is worth announcing; a two-word dictation's is not.
    let isSession = duration >= Self.sessionDurationThreshold
    if isSession {
      state.sessionSummary = Self.sessionSummaryText(duration: duration)
    }

    return .merge(
      .cancel(id: CancelID.recordingStart),
      endLivePreviewEffect(),
      isSession ? sessionSummaryExpiryEffect() : .none,
      .run { [sleepManagement] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()

        // Play the cue immediately: stopping now holds capture open briefly to catch the tail,
        // and the sound is the user's signal that recording has ended.
        soundEffect.play(isSession ? .sessionEnded : .stopRecording)

        // The stop path never deletes the captured file: a failed or superseded transcription
        // used to destroy the recording. Audio is handed to persistence, or left in the temp
        // directory for the next launch's recovery to pick up.
        let stopResult = await recording.stopRecording()
        switch stopResult {
        case let .captured(url):
          await send(.transcribe(url, duration, .pasted))
        case .ignored(.staleSession):
          transcriptionFeatureLogger.notice("Ignoring transcription stop superseded by a newer recording session")
        case .ignored(.noActiveRecording):
          transcriptionFeatureLogger.error("Recording stopped without captured audio")
          await send(.transcriptionError(RecordingFailure.noCapturedAudio, nil, duration))
        case let .failed(error):
          transcriptionFeatureLogger.error("Recording stop failed: \(error.localizedDescription)")
          await send(.transcriptionError(error, nil, duration))
        }
      }
      .cancellable(id: CancelID.transcription)
    )
  }

  /// Transcribes a captured recording and reports the text back to the reducer.
  ///
  /// Shared by the normal stop path and the cancel path, so cancelling produces a
  /// recoverable transcript rather than a deleted file.
  /// Transcribes a recording a previous session abandoned. Nothing is pasted — the user is
  /// not necessarily in the same app, or even the same hour — but the words land in history
  /// so an interrupted session does not lose them.
  func transcribeEffect(url: URL, duration: TimeInterval, status: TranscriptStatus) -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings

      let model = hexSettings.selectedModel
      guard !model.isEmpty else {
        // Defense-in-depth: handleStartRecording blocks recording when the bootstrap state
        // says no model is ready, but settings can change while a recording is in flight.
        // Never hand an empty model name to the transcriber: it silently produces nothing.
        transcriptionFeatureLogger.error("No transcription model selected; keeping audio \(url.lastPathComponent)")
        await send(.modelMissing)
        await send(.transcriptionError(TranscriptionFailure.noModelSelected, url, duration))
        return
      }

      let language = hexSettings.outputLanguage
      let decodeOptions = DecodingOptions(
        language: language,
        detectLanguage: language == nil, // Only auto-detect if no language specified
        chunkingStrategy: .vad,
      )

      do {
        let result = try await transcription.transcribe(url, model, decodeOptions) { _ in }
        transcriptionFeatureLogger.notice(
          "Transcribed audio from \(url.lastPathComponent) to text length \(result.count)"
        )
        await send(.transcriptionResult(result, url, duration, status))
      } catch {
        transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
        await send(.transcriptionError(error, url, duration))
      }
    }
    .cancellable(id: CancelID.transcription)
  }
}

enum TranscriptionFailure: Error, Equatable, LocalizedError {
  case noModelSelected

  var errorDescription: String? {
    switch self {
    case .noModelSelected:
      "No transcription model is selected."
    }
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL,
    duration: TimeInterval,
    status: TranscriptStatus
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // Empty text is not a reason to destroy a recording. For a session it is the case where
    // the audio is the only remaining copy of what was said, so it is kept with no text.
    guard !result.isEmpty else {
      return preserveTextlessRecordingEffect(
        &state,
        audioURL: audioURL,
        duration: duration,
        reason: "transcription produced no text"
      )
    }

    transcriptionFeatureLogger.info("Raw transcription: '\(result, privacy: .private)'")
    let remappings = state.hexSettings.wordRemappings
    let removalsEnabled = state.hexSettings.wordRemovalsEnabled
    let removals = state.hexSettings.wordRemovals
    let modifiedResult: String
    if state.isRemappingScratchpadFocused {
      modifiedResult = result
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    } else {
      var output = result
      if removalsEnabled {
        let removedResult = WordRemovalApplier.apply(output, removals: removals)
        if removedResult != output {
          let enabledRemovalCount = removals.filter(\.isEnabled).count
          transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
        }
        output = removedResult
      }
      let remappedResult = WordRemappingApplier.apply(output, remappings: remappings)
      if remappedResult != output {
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      }
      let formattedResult = TranscriptFormattingApplier.apply(
        remappedResult,
        lowercase: state.hexSettings.lowercaseTranscripts,
        removePunctuation: state.hexSettings.removePunctuation
      )
      if formattedResult != remappedResult {
        transcriptionFeatureLogger.info("Applied paste formatting")
      }
      modifiedResult = formattedResult
    }

    // Word removal or formatting emptied the text; the audio is still what was said.
    guard !modifiedResult.isEmpty else {
      return preserveTextlessRecordingEffect(
        &state,
        audioURL: audioURL,
        duration: duration,
        reason: "text was emptied by word removal or formatting"
      )
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { send in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: modifiedResult,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          status: status,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        await send(.transcriptionError(error, audioURL, duration))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  /// Keeps a recording whose transcript came back empty, but only once it is long enough to be
  /// a session rather than an accidental tap. Below that threshold nothing was said, so the
  /// file is removed and no empty history entry is created.
  func preserveTextlessRecordingEffect(
    _ state: inout State,
    audioURL: URL,
    duration: TimeInterval,
    reason: String
  ) -> Effect<Action> {
    guard duration >= Self.sessionDurationThreshold else {
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

    transcriptionFeatureLogger.notice(
      "Keeping a \(String(format: "%.0f", duration))s recording because \(reason)"
    )

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { _ in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: "",
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          status: .failed,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        transcriptionFeatureLogger.error(
          "Could not preserve textless recording: \(error.localizedDescription)"
        )
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?,
    duration: TimeInterval
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription

    // A failed transcription must not throw away what was said. Keep the audio in history
    // so it can be played back instead of disappearing, exactly like a cancelled take.
    guard let audioURL else { return .none }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { _ in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: "",
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          status: .failed,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        transcriptionFeatureLogger.error("Could not preserve failed recording: \(error.localizedDescription)")
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  /// Move file to permanent location, create a transcript record, and paste the text when the
  /// recording actually ended in a paste.
  ///
  /// Nothing that reaches here is deleted while history is enabled: cancelled and failed
  /// recordings are kept so the words stay recoverable. Turning history off remains the way
  /// to opt out of retaining audio.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    status: TranscriptStatus,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws {
    @Shared(.hexSettings) var hexSettings: HexSettings

    if hexSettings.saveTranscriptionHistory {
      let transcript = try await transcriptPersistence.save(
        result,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName,
        status
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    } else {
      FileManager.default.removeItemIfExists(at: audioURL)
    }

    guard status.wasPasted else { return }
    await pasteboard.paste(result)
    soundEffect.play(.pasteTranscript)
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  /// ESC. Cancelling is a decision about *pasting*, not about whether what you said is worth
  /// keeping — so the recording is stopped and transcribed as usual, then stored as
  /// `.notPasted` instead of being pasted. This used to delete the audio outright, which is
  /// why cancelling felt like losing the last thing you said. The text stays one keystroke
  /// away via "Paste Last Transcript".
  func handleCancel(_ state: inout State) -> Effect<Action> {
    let wasRecording = state.isRecording
    let duration = state.recordingStartTime.map { now.timeIntervalSince($0) } ?? 0
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false

    return .concatenate(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.recordingStart),
      endLivePreviewEffect(),
      .run { [sleepManagement] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        guard wasRecording else {
          soundEffect.play(.cancel)
          return
        }
        // Stop the recording to release microphone access, keeping the audio.
        let result = await recording.stopRecording()
        soundEffect.play(.cancel)

        guard case let .captured(url) = result else { return }
        guard !Task.isCancelled else { return }
        await send(.transcribe(url, duration, .notPasted))
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.recordingStart),
      endLivePreviewEffect(),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		}
		guard !Task.isCancelled else { return }
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject
  @Shared(.livePreview) var livePreview: LivePreviewSnapshot

  var status: TranscriptionIndicatorView.Status {
    if store.isRecording {
      return .recording
    } else if store.recordingFailure != nil {
      return .failed
    } else if store.sessionSummary != nil {
      // Takes precedence over the transcribing state: the acknowledgement that the session
      // ended and was saved matters more than the progress of the transcription.
      return .sessionEnded
    } else if store.isTranscribing {
      return .transcribing
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      meter: store.meter,
      speech: store.speech,
      recordingStartedAt: store.listeningSince,
      liveText: livePreview.text,
      liveTextCarriedOver: livePreview.carriedOverCharacters,
      sessionSummary: store.sessionSummary,
      failureMessage: store.recordingFailure,
      isCapturing: store.isCapturing
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
