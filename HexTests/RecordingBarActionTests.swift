import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Hex

/// A take ends in two ways, and only one of them leaves the hotkey monitor out of step.
///
/// Double-tap lock is built out of the release times of the two taps, so an ordinary hotkey stop has
/// to leave that timing alone. Resetting the monitor there erased the first tap, the second one was
/// measured against nothing, and a double-tap behaved like a press-and-hold — the gesture silently
/// stopped working. These two tests pin which end is which.
@MainActor
final class RecordingBarActionTests: XCTestCase {
  func testStoppingWithTheHotkeyLeavesTheDoubleTapTimingAlone() async {
    let now = Date(timeIntervalSince1970: 1_234)
    let store = Self.store(now: now)
    store.exhaustivity = .off

    let before = Self.resetStamp
    await store.send(.hotKeyReleased)
    await store.finish()

    XCTAssertEqual(Self.resetStamp, before, "a hotkey stop must not reset the monitor's tap timing")
  }

  func testCancellingWithTheHotkeyLeavesTheDoubleTapTimingAlone() async {
    let now = Date(timeIntervalSince1970: 1_234)
    let store = Self.store(now: now)
    store.exhaustivity = .off

    let before = Self.resetStamp
    await store.send(.discard)
    await store.finish()

    XCTAssertEqual(Self.resetStamp, before, "a discard the hotkey caused must not reset the monitor")
  }

  func testFinishingFromTheBarTellsTheHotkeyMonitor() async {
    let now = Date(timeIntervalSince1970: 1_234)
    let store = Self.store(now: now)
    store.exhaustivity = .off

    let before = Self.resetStamp
    await store.send(.finishFromBar)
    await store.finish()

    XCTAssertEqual(Self.resetStamp, before + 1, "a click ends the take without the chord being released")
  }

  func testCancellingFromTheBarTellsTheHotkeyMonitor() async {
    let now = Date(timeIntervalSince1970: 1_234)
    let store = Self.store(now: now)
    store.exhaustivity = .off

    let before = Self.resetStamp
    await store.send(.cancelFromBar)
    await store.finish()

    XCTAssertEqual(Self.resetStamp, before + 1, "a click ends the take without the chord being released")
  }

  func testPastingFromTheBarSendsThisTakesWords() async {
    let now = Date(timeIntervalSince1970: 1_234)
    let probe = PasteProbe()
    var state = Self.recordingState(now: now)
    state.isRecording = false
    state.isTranscribing = false
    state.sessionSummary = "Session ended · 4:12"
    state.lastTranscript = "the words from this take"

    let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
      $0.date.now = now
      $0.pasteboard.paste = { await probe.record($0) }
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.pasteResult)
    await store.finish()

    let pasted = await probe.text
    XCTAssertEqual(pasted, "the words from this take")
    XCTAssertNil(store.state.sessionSummary, "pasting ends the take for the bar")
  }

  func testPastingFromTheBarDoesNothingWithoutWords() async {
    let now = Date(timeIntervalSince1970: 1_234)
    let probe = PasteProbe()
    var state = Self.recordingState(now: now)
    state.isRecording = false
    state.isTranscribing = true
    state.sessionSummary = "Session ended · 4:12"

    let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
      $0.date.now = now
      $0.pasteboard.paste = { await probe.record($0) }
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.pasteResult)
    await store.finish()

    let pasted = await probe.text
    XCTAssertNil(pasted, "nothing has been transcribed yet, so there is nothing to paste")
  }

  func testDismissingTheBarKeepsItHiddenWhileTranscribing() async {
    let now = Date(timeIntervalSince1970: 1_234)
    var state = Self.recordingState(now: now)
    state.isRecording = false
    state.isTranscribing = true
    state.sessionSummary = "Session ended · 4:12"

    let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
      $0.date.now = now
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.dismissResult)
    await store.finish()

    XCTAssertNil(store.state.sessionSummary)
    XCTAssertTrue(
      store.state.resultDismissed,
      "a transcription still in flight must not bring the bar back after you closed it"
    )
  }

  func testALockedTakeKeepsItsBar() async {
    var state = Self.recordingState(now: Date(timeIntervalSince1970: 1_234))
    state.isLockedTake = true
    state.recordingStartTime = Date(timeIntervalSince1970: 1_231)

    let store = Self.finishingStore(state)
    await store.send(.stopRecording)
    await store.skipInFlightEffects()

    XCTAssertNotNil(
      store.state.sessionSummary,
      "a take you locked is one you stayed in on purpose, so its result stays on screen"
    )
  }

  func testAHeldTakeLeavesNoBarBehind() async {
    var state = Self.recordingState(now: Date(timeIntervalSince1970: 1_234))
    state.isLockedTake = false
    state.recordingStartTime = Date(timeIntervalSince1970: 1_231)

    let store = Self.finishingStore(state)
    await store.send(.stopRecording)
    await store.finish()

    XCTAssertNil(
      store.state.sessionSummary,
      "a held hotkey is a quick dictation: it pastes and the bar gets out of the way"
    )
  }

  func testTheLockDecidesTheEndingNotTheClock() async {
    // Same three seconds either way: only the mode differs.
    var locked = Self.recordingState(now: Date(timeIntervalSince1970: 1_234))
    locked.isLockedTake = true
    locked.recordingStartTime = Date(timeIntervalSince1970: 1_231)

    var held = Self.recordingState(now: Date(timeIntervalSince1970: 1_234))
    held.isLockedTake = false
    held.recordingStartTime = Date(timeIntervalSince1970: 1_231)

    let lockedStore = Self.finishingStore(locked)
    await lockedStore.send(.stopRecording)
    await lockedStore.skipInFlightEffects()

    let heldStore = Self.finishingStore(held)
    await heldStore.send(.stopRecording)
    await heldStore.finish()

    XCTAssertNotNil(lockedStore.state.sessionSummary)
    XCTAssertNil(heldStore.state.sessionSummary)
  }

  func testTheLockOnlyAppliesToARunningTake() async {
    let now = Date(timeIntervalSince1970: 1_234)
    var state = Self.recordingState(now: now)
    state.isLockedTake = false

    let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
      $0.date.now = now
    }
    store.exhaustivity = .off

    await store.send(.takeBecameLocked) {
      $0.isLockedTake = true
    }

    // With nothing recording, a lock describes no take and must not linger onto the next one.
    var idle = Self.recordingState(now: now)
    idle.isRecording = false
    idle.isLockedTake = false
    let idleStore = TestStore(initialState: idle) { TranscriptionFeature() } withDependencies: {
      $0.date.now = now
    }
    idleStore.exhaustivity = .off

    await idleStore.send(.takeBecameLocked)
    XCTAssertFalse(idleStore.state.isLockedTake)
  }

  func testAStartedTakeTakesItsModeFromThePress() async {
    let now = Date(timeIntervalSince1970: 1_234)
    var state = Self.recordingState(now: now)
    state.isRecording = false
    state.isLockedTake = true  // stale from an earlier take

    let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {}
      $0.sleepManagement.preventSleep = { _ in }
      $0.soundEffects.play = { _ in }
      $0.livePreview.begin = {}
    }
    store.exhaustivity = .off

    // A held press starts a quick take, whatever the previous one was.
    await store.send(.startRecording(locked: false))
    XCTAssertFalse(store.state.isLockedTake)
  }

  private static var resetStamp: Int {
    Shared(.hotKeyResetStamp).wrappedValue
  }

  /// A take that ends cleanly and transcribes to nothing, so the tests stay about the bar.
  private static func finishingStore(_ state: TranscriptionFeature.State) -> TestStoreOf<TranscriptionFeature> {
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_234)
      $0.recording.stopRecording = { .captured(URL(fileURLWithPath: "/tmp/hex-test-missing.wav")) }
      $0.transcription.transcribe = { _, _, _, _ in "" }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
      $0.livePreview.end = {}
      $0.pasteboard.paste = { _ in }
    }
    store.exhaustivity = .off
    return store
  }

  private static func recordingState(now: Date) -> TranscriptionFeature.State {
    TranscriptionFeature.State(
      isRecording: true,
      recordingStartTime: now,
      hexSettings: Shared(value: .init()),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: Shared(value: .init())
    )
  }

  private static func store(now: Date) -> TestStoreOf<TranscriptionFeature> {
    TestStore(initialState: recordingState(now: now)) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.stopRecording = { .captured(URL(fileURLWithPath: "/tmp/hex-test-missing.wav")) }
      $0.transcription.transcribe = { _, _, _, _ in "" }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
      $0.livePreview.end = {}
      $0.pasteboard.paste = { _ in }
    }
  }
}

private actor PasteProbe {
  private(set) var text: String?

  func record(_ text: String) {
    self.text = text
  }
}
