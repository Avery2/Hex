//
//  TranscriptionIndicatorView.swift
//  Hex
//
//  Created by Kit Langton on 1/25/25.
//

import AppKit
import HexCore
import Inject
import SwiftUI

/// The bar Hex puts at the top of the screen — the whole of what it draws over other apps.
///
/// One fixed pill, one row, in every state: a dot, the elapsed time, what is being heard, and the two
/// decisions a recording needs (Cancel, Finish). Nothing in it grows, shrinks or slides as you speak.
/// It used to carry a level meter whose width followed the microphone, which read as the bar itself
/// moving, and before that it hugged its text — both made an indicator that was hard to ignore while
/// you were reading something else.
struct TranscriptionIndicatorView: View {
  @ObserveInjection var inject

  enum Status: Equatable {
    case hidden
    case optionKeyPressed
    case recording
    case transcribing
    case prewarming
    /// A long recording has ended and been saved; shown briefly so its end is never silent.
    case sessionEnded
    /// Recording stopped because the disk refused a write.
    case failed
  }

  var status: Status
  var meter: Meter
  /// Used only to tell a dead microphone from a quiet room, which the level meter cannot.
  var speech: SpeechActivityDetector = .init()
  /// When audio actually started flowing, used to decide when silence is worth mentioning.
  var recordingStartedAt: Date?
  /// When the take began, for the elapsed clock in the bar.
  var startedAt: Date?
  /// What the transcriber is hearing so far, shown while you are still speaking.
  var liveText: String = ""
  /// Leading characters of `liveText` that were already there on the previous decode. The rest
  /// is what just arrived, and is drawn brighter so the eye lands on the newest words.
  var liveTextCarriedOver: Int = 0
  /// Confirmation text shown while the session-ended state is on screen.
  var sessionSummary: String?
  /// Shown instead of the session confirmation when recording had to stop on a write failure.
  var failureMessage: String?
  /// Whether audio is actually flowing yet — see `TranscriptionFeature.State.isCapturing`.
  var isCapturing: Bool = true
  /// Whether the take's words are still being worked out.
  ///
  /// A finished session shows its check the instant you stop, which is right — the recording is
  /// safe — but the words are still seconds away. Saying nothing in that gap reads as "is this
  /// lagging?", so the bar says what it is doing until Paste can appear.
  var isTranscribing: Bool = false
  /// Whether there are words from this take worth pasting again.
  var canPaste: Bool = false
  /// What this take transcribed to, for the bar to open out and show in full.
  var transcript: String?

  /// Stop and keep the audio, but do not paste it.
  var onCancel: () -> Void = {}
  /// Stop and paste what was said.
  var onFinish: () -> Void = {}
  /// Paste this take into whatever app is in front now.
  var onPaste: () -> Void = {}
  /// Take the finished bar off screen now rather than waiting for it to expire.
  var onDismiss: () -> Void = {}
  /// Told whether the bar is on screen: only then may its window take clicks.
  var onInteractiveChanged: (Bool) -> Void = { _ in }
  /// Told how big the bar is, because its window is exactly the bar.
  var onBarSizeChanged: (CGSize) -> Void = { _ in }

  /// The finished transcript is folded away until you ask for it: the bar is meant to be glanceable,
  /// and only a session you care about is worth the screen space of the whole thing.
  @State private var isShowingTranscript = false

  private var isVisible: Bool { status != .hidden }

  /// A finished session whose words are still being worked out. The check is already true — the
  /// audio is safe — so this says what is *still happening* rather than contradicting it.
  private var showsWorkingIndicator: Bool {
    status == .sessionEnded && isTranscribing
  }

  /// Whether the whole transcript is worth opening out: only a finished take has one to show.
  private var canUnfold: Bool {
    switch status {
    case .sessionEnded, .failed: transcript?.isEmpty == false
    default: false
    }
  }

  /// Whatever is on screen takes the click. Letting a click through a bar you can see would act on
  /// the app behind it instead, which is worse than the click doing nothing.
  private var isInteractive: Bool { isVisible }

  private var accent: Color {
    switch status {
    case .hidden, .optionKeyPressed: .gray
    case .recording: .red
    case .transcribing, .prewarming: .blue
    case .sessionEnded: .green
    case .failed: .orange
    }
  }

  private var level: Double {
    guard status == .recording, isCapturing else { return 0 }
    return min(1, meter.averagePower * 3)
  }

  /// The engine has been asked to record but has not delivered a frame yet, so nothing said
  /// right now would be kept.
  private var isWaitingForAudio: Bool { status == .recording && !isCapturing }

  /// The one line of text in the bar: what is being heard, or why nothing is, or how the take ended.
  private var message: String? {
    switch status {
    case .hidden, .optionKeyPressed:
      return nil
    case .transcribing:
      return liveText.isEmpty ? "Transcribing\u{2026}" : liveText
    case .prewarming:
      return "Warming up\u{2026}"
    case .sessionEnded:
      return sessionSummary ?? "Session ended"
    case .failed:
      return failureMessage ?? "Recording stopped"
    case .recording:
      if isWaitingForAudio { return "Not listening yet" }
      if !liveText.isEmpty { return liveText }
      // Nothing speech-like for a couple of seconds is nearly always the microphone (wrong
      // device, muted, unplugged) rather than a quiet room. Only fires when nothing has been
      // heard at all, so pausing mid-sentence never triggers it.
      if !speech.hasSpoken, let startedAt = recordingStartedAt,
         Date().timeIntervalSince(startedAt) > 2.5 {
        return "Not hearing you"
      }
      return "Listening\u{2026}"
    }
  }

  /// Status text is drawn dimmer than real words, so what the transcriber is hearing stands out
  /// from the bar telling you about itself.
  private var messageIsPlaceholder: Bool {
    status != .recording || liveText.isEmpty
  }

  /// Two-tone when there are real words: what just arrived at full brightness, everything
  /// carried over from the previous decode dimmed behind it.
  private func messageText(_ line: String) -> Text {
    guard !messageIsPlaceholder else {
      return Text(line).foregroundStyle(Color.white.opacity(0.45))
    }
    let split = min(max(0, liveTextCarriedOver), line.count)
    return Text(String(line.prefix(split))).foregroundStyle(Color.white.opacity(0.4))
      + Text(String(line.dropFirst(split))).foregroundStyle(Color.white)
  }

  private func clock(from start: Date, to now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(start).rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
      : String(format: "%d:%02d", minutes, seconds)
  }

  var body: some View {
    ZStack(alignment: .top) {
      if isVisible {
        bar
          .transition(.opacity)
      }
    }
    .frame(
      width: RecordingBarLayout.size.width,
      height: height
    )
    .animation(.easeInOut(duration: 0.16), value: isVisible)
    .animation(.easeInOut(duration: 0.18), value: isShowingTranscript)
    .onChange(of: isInteractive, initial: true) { _, interactive in
      onInteractiveChanged(interactive)
    }
    .onChange(of: height, initial: true) { _, newHeight in
      // Reported from the height that is actually drawn rather than from `isShowingTranscript`,
      // because those two disagree whenever there is no transcript to show — and a window bigger
      // than the bar is a patch of screen that swallows clicks meant for the app underneath.
      onBarSizeChanged(CGSize(width: RecordingBarLayout.size.width, height: newHeight))
    }
    .onChange(of: status) { _, _ in
      // Every new state starts folded, and a bar that is going away folds before it does.
      if isShowingTranscript { isShowingTranscript = false }
    }
    .enableInjection()
  }

  private var height: CGFloat {
    isShowingTranscript && canUnfold
      ? RecordingBarLayout.expandedSize.height
      : RecordingBarLayout.size.height
  }

  private var bar: some View {
    VStack(alignment: .leading, spacing: 0) {
      row

      if isShowingTranscript && canUnfold, let transcript {
        Rectangle()
          .fill(Color.white.opacity(0.08))
          .frame(height: 1)

        // Selectable, so the text is still yours to take by hand if Paste goes somewhere odd.
        ScrollView {
          Text(transcript)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.9))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(
      width: RecordingBarLayout.size.width,
      height: height,
      alignment: .top
    )
    .background(background)
    .animation(.easeInOut(duration: 0.18), value: status)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }

  private var row: some View {
    HStack(spacing: 9) {
      lead

      if status == .recording, let startedAt {
        elapsed(startedAt)
      }

      if let message {
        // Head truncation because the live transcript keeps the newest words at the end, and one
        // line is all the bar has: the words that matter are the ones just said.
        messageText(message)
          .font(.system(size: 12))
          .lineLimit(1)
          .truncationMode(.head)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Spacer(minLength: 0)
      }

      if showsWorkingIndicator {
        HStack(spacing: 5) {
          ProgressView()
            .controlSize(.mini)
            .tint(.white.opacity(0.7))
          Text("Transcribing")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.5))
        }
        .fixedSize()
      }

      controls
    }
    .padding(.horizontal, 13)
    .frame(height: RecordingBarLayout.size.height)
  }

  /// The fixed slot that says what state the bar is in without ever moving the text beside it.
  private var lead: some View {
    ZStack {
      switch status {
      case .recording:
        Circle()
          .fill(isCapturing ? Color.red : Color.white.opacity(0.3))
          .frame(width: 8, height: 8)
          // A breath, not a meter: enough to show the microphone is live, small enough to ignore.
          .opacity(0.7 + 0.3 * level)
      case .transcribing, .prewarming:
        ProgressView()
          .controlSize(.mini)
          .tint(.white.opacity(0.85))
      case .sessionEnded:
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(Color.green)
      case .failed:
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.orange)
      case .optionKeyPressed:
        Circle()
          .fill(Color.white.opacity(0.35))
          .frame(width: 8, height: 8)
      case .hidden:
        EmptyView()
      }
    }
    .frame(width: 12, height: 12)
  }

  /// The elapsed time, ticking once a second. Monospaced digits so the bar does not twitch.
  private func elapsed(_ startedAt: Date) -> some View {
    // Anchored to the take's start rather than "now", so the tick does not re-phase every time the
    // live transcript redraws the bar.
    TimelineView(.periodic(from: startedAt, by: 1)) { context in
      Text(clock(from: startedAt, to: context.date))
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
    }
  }

  @ViewBuilder private var controls: some View {
    switch status {
    case .recording:
      HStack(spacing: 5) {
        BarChip(systemImage: "xmark", accessibilityLabel: "Cancel", action: onCancel)
        BarChip(systemImage: "checkmark", accessibilityLabel: "Finish", isPrimary: true, action: onFinish)
      }
    case .sessionEnded, .failed:
      HStack(spacing: 5) {
        if canUnfold {
          BarChip(
            systemImage: isShowingTranscript ? "chevron.up" : "chevron.down",
            accessibilityLabel: isShowingTranscript ? "Hide transcript" : "Show transcript",
            action: { isShowingTranscript.toggle() }
          )
        }
        // Only offered once the words exist, and only for this take: "Paste" here means the thing
        // you just said, into wherever you ended up. It is the reason the bar is still here.
        if canPaste {
          BarChip(
            title: "Paste",
            accessibilityLabel: "Paste this transcript",
            isPrimary: true,
            action: onPaste
          )
        }
        BarChip(systemImage: "xmark", accessibilityLabel: "Dismiss", action: onDismiss)
      }
    case .hidden, .optionKeyPressed, .transcribing, .prewarming:
      EmptyView()
    }
  }

  private var background: some View {
    // 20 on a 40pt-tall bar is a capsule; on an opened-out bar it is the same rounded top and
    // bottom, so unfolding does not change the shape's corners.
    RoundedRectangle(cornerRadius: 20, style: .continuous)
      .fill(Color.black.opacity(0.86))
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(Color.white.opacity(0.09), lineWidth: 1)
      }
  }

  private var accessibilityLabel: String {
    switch status {
    case .recording: "Recording, \(startedAt.map { clock(from: $0, to: Date()) } ?? "0:00") elapsed"
    case .transcribing: "Transcribing"
    case .prewarming: "Warming up the model"
    case .sessionEnded: sessionSummary ?? "Session ended"
    case .failed: failureMessage ?? "Recording stopped"
    case .optionKeyPressed: "Ready to record"
    case .hidden: ""
    }
  }
}

/// A button in the bar. Fixed size so the pill never changes shape, and a hover tint because the bar
/// has no window chrome to say it is a control.
private struct BarChip: View {
  var title: String?
  var systemImage: String?
  var accessibilityLabel: String
  var isPrimary: Bool = false
  var action: () -> Void

  @State private var isHovering = false

  private var fill: Color {
    if isPrimary { return Color(red: 0.23, green: 0.36, blue: 0.96) }
    return Color.white.opacity(isHovering ? 0.18 : 0.1)
  }

  var body: some View {
    Button(action: action) {
      Group {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 10, weight: .bold))
        } else {
          Text(title ?? "")
            .font(.system(size: 11, weight: .semibold))
        }
      }
      .foregroundStyle(isPrimary ? Color.white : Color.white.opacity(0.85))
      .frame(height: 22)
      .padding(.horizontal, systemImage == nil ? 9 : 0)
      .frame(width: systemImage == nil ? nil : 22, height: 22)
      .background(Capsule().fill(fill))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(accessibilityLabel)
    .accessibilityLabel(accessibilityLabel)
  }
}

#Preview("HEX") {
  var speaking = SpeechActivityDetector()
  speaking.ingest(averagePower: 0.05)

  return VStack(spacing: 12) {
    TranscriptionIndicatorView(
      status: .recording,
      meter: .init(averagePower: 0.5, peakPower: 0.5),
      speech: speaking,
      startedAt: Date().addingTimeInterval(-42),
      liveText: "so the tail of the recording keeps getting cut off when I stop talking"
    )
    TranscriptionIndicatorView(
      status: .recording,
      meter: .init(averagePower: 0.2, peakPower: 0.3),
      recordingStartedAt: Date().addingTimeInterval(-1),
      startedAt: Date().addingTimeInterval(-7)
    )
    TranscriptionIndicatorView(
      status: .recording,
      meter: .init(averagePower: 0.05, peakPower: 0.05),
      recordingStartedAt: Date().addingTimeInterval(-5),
      startedAt: Date().addingTimeInterval(-5)
    )
    TranscriptionIndicatorView(
      status: .recording,
      meter: .init(averagePower: 0, peakPower: 0),
      startedAt: Date(),
      isCapturing: false
    )
    TranscriptionIndicatorView(
      status: .transcribing,
      meter: .init(averagePower: 0, peakPower: 0),
      liveText: "and that is the last thing I said"
    )
    TranscriptionIndicatorView(status: .sessionEnded, meter: .init(averagePower: 0, peakPower: 0), sessionSummary: "Session ended · 4:12")
    TranscriptionIndicatorView(status: .failed, meter: .init(averagePower: 0, peakPower: 0), failureMessage: "Recording stopped · disk full")
    TranscriptionIndicatorView(status: .hidden, meter: .init(averagePower: 0, peakPower: 0))
  }
  .padding(24)
  .background(Color.gray)
}
