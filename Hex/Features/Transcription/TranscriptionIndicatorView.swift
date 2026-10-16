//
//  HexCapsuleView.swift
//  Hex
//
//  Created by Kit Langton on 1/25/25.

import AppKit
import HexCore
import Inject
import Pow
import SwiftUI

struct TranscriptionIndicatorView: View {
  @ObserveInjection var inject
  
  enum Status {
    case hidden
    case optionKeyPressed
    case recording
    case transcribing
    case prewarming
  }

  var status: Status
  var meter: Meter
  /// Used only to tell a dead microphone from a quiet room, which the level meter cannot.
  var speech: SpeechActivityDetector = .init()
  /// When the current recording started; used to decide when silence is worth mentioning.
  var recordingStartedAt: Date?
  /// What the transcriber is hearing so far, shown while you are still speaking.
  var liveText: String = ""
  /// Leading characters of `liveText` that were already there on the previous decode. The rest
  /// is what just arrived, and is drawn brighter so the eye lands on the newest words.
  var liveTextCarriedOver: Int = 0
  /// Whether audio is actually flowing yet — see `TranscriptionFeature.State.isCapturing`.
  var isCapturing: Bool = true

  let transcribeBaseColor: Color = .blue
  private var backgroundColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording:
      // Neutral until audio actually arrives, so "armed" never looks like "listening".
      guard !isWaitingForAudio else { return Color(nsColor: mixedNSColor(.gray, with: .black, by: 0.65)) }
      return mixedColor(mixedNSColor(.red, with: .black, by: 0.5), with: .red, by: meter.averagePower * 3)
    case .transcribing: return mixedColor(.blue, with: .black, by: 0.5)
    case .prewarming: return mixedColor(.blue, with: .black, by: 0.5)
    }
  }

  private var strokeColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording:
      guard !isWaitingForAudio else { return Color.white.opacity(0.25) }
      return mixedColor(.red, with: .white, by: 0.1).opacity(0.6)
    case .transcribing: return mixedColor(.blue, with: .white, by: 0.1).opacity(0.6)
    case .prewarming: return mixedColor(.blue, with: .white, by: 0.1).opacity(0.6)
    }
  }

  private func mixedColor(_ color: NSColor, with otherColor: NSColor, by fraction: Double) -> Color {
    Color(nsColor: mixedNSColor(color, with: otherColor, by: fraction))
  }

  private func mixedNSColor(_ color: NSColor, with otherColor: NSColor, by fraction: Double) -> NSColor {
    let clampedFraction = min(max(fraction, 0), 1)
    return color.blended(withFraction: clampedFraction, of: otherColor) ?? color
  }

  private var innerShadowColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.clear
    case .recording: return Color.red
    case .transcribing: return transcribeBaseColor
    case .prewarming: return transcribeBaseColor
    }
  }

  private let cornerRadius: CGFloat = 8
  private let baseWidth: CGFloat = 16
  private let expandedWidth: CGFloat = 56

  var isHidden: Bool {
    status == .hidden
  }

  /// The engine has been asked to record but has not delivered a frame yet, so nothing said
  /// right now would be kept.
  private var isWaitingForAudio: Bool { status == .recording && !isCapturing }

  /// The status line is present for the whole recording and never goes blank, so an empty line
  /// means the indicator itself is broken rather than "nothing to say yet". A three-step
  /// progression, so it never claims more than it knows:
  /// not listening yet → listening but nothing heard → words are arriving.
  private var statusLine: String? {
    guard status == .recording else { return nil }
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

  /// Placeholder states are shown dimmed so real transcribed words stand out from status.
  private var statusLineIsPlaceholder: Bool { liveText.isEmpty }

  /// Two-tone when there are real words: what just arrived at full brightness, everything
  /// carried over from the previous decode dimmed behind it.
  private func statusText(_ line: String) -> Text {
    guard !statusLineIsPlaceholder else {
      return Text(line).foregroundStyle(Color.white.opacity(0.6))
    }
    let split = min(max(0, liveTextCarriedOver), line.count)
    return Text(String(line.prefix(split))).foregroundStyle(Color.white.opacity(0.4))
      + Text(String(line.dropFirst(split))).foregroundStyle(Color.white)
  }

  @State var transcribeEffect = 0

  var body: some View {
    let averagePower = min(1, meter.averagePower * 3)
    let peakPower = min(1, meter.peakPower * 3)

    // The status line is a sibling in a top-anchored VStack rather than an overlay on the
    // capsule. As an overlay it was proposed the capsule's 56pt width, so a sentence collapsed
    // to "…g…"; as a sibling it gets the full width to wrap in. Top anchoring keeps the capsule
    // from moving when the line appears.
    ZStack(alignment: .top) {
      VStack(spacing: 18) {
        Capsule()
          .fill(backgroundColor.shadow(.inner(color: innerShadowColor, radius: 4)))
          .overlay {
            Capsule()
              .stroke(strokeColor, lineWidth: 1)
              .blendMode(.screen)
          }
          .overlay(alignment: .center) {
            RoundedRectangle(cornerRadius: cornerRadius)
              .fill(Color.red.opacity(status == .recording ? (averagePower < 0.1 ? averagePower / 0.1 : 1) : 0))
              .blur(radius: 2)
              .blendMode(.screen)
              .padding(6)
          }
          .overlay(alignment: .center) {
            RoundedRectangle(cornerRadius: cornerRadius)
              .fill(Color.white.opacity(status == .recording ? (averagePower < 0.1 ? averagePower / 0.1 : 0.5) : 0))
              .blur(radius: 1)
              .blendMode(.screen)
              .frame(maxWidth: .infinity, alignment: .center)
              .padding(7)
          }
          .overlay(alignment: .center) {
            GeometryReader { proxy in
              RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.red.opacity(status == .recording ? (peakPower < 0.1 ? (peakPower / 0.1) * 0.5 : 0.5) : 0))
                .frame(width: max(proxy.size.width * (peakPower + 0.6), 0), height: proxy.size.height, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)
                .blur(radius: 4)
                .blendMode(.screen)
            }.padding(6)
          }
          .cornerRadius(cornerRadius)
          .shadow(
            color: status == .recording ? .red.opacity(averagePower) : .red.opacity(0),
            radius: 4
          )
          .shadow(
            color: status == .recording ? .red.opacity(averagePower * 0.5) : .red.opacity(0),
            radius: 8
          )
          .animation(.interactiveSpring(), value: meter)
          .frame(
            width: status == .recording ? expandedWidth : baseWidth,
            height: baseWidth
          )
          .opacity(status == .hidden ? 0 : 1)
          .scaleEffect(status == .hidden ? 0.0 : 1)
          .blur(radius: status == .hidden ? 4 : 0)
          .animation(.bouncy(duration: 0.3), value: status)
          .changeEffect(.glow(color: .red.opacity(0.5), radius: 8), value: status)
          .changeEffect(.shine(angle: .degrees(0), duration: 0.6), value: transcribeEffect)
          .compositingGroup()
          .overlay(alignment: .top) {
            if status == .prewarming {
              Text("Model prewarming...")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.8)))
                .offset(y: -30)
                .transition(.opacity)
            }
          }
          .task(id: status == .transcribing) {
            while status == .transcribing, !Task.isCancelled {
              transcribeEffect += 1
              try? await Task.sleep(for: .seconds(0.25))
            }
          }

        // The words themselves, or the current state when there are none yet. This is the whole
        // point of the indicator: a level meter and a colour can only say "something is loud",
        // not "I am getting your words". Head truncation because the rolling window keeps the
        // most recent words at the end.
        if let statusLine {
          statusText(statusLine)
            .font(.system(size: 13))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .truncationMode(.head)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.75)))
            .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity)
    }
    .animation(.easeInOut(duration: 0.15), value: statusLineIsPlaceholder)
    .enableInjection()
  }
}

#Preview("HEX") {
  var speaking = SpeechActivityDetector()
  speaking.ingest(averagePower: 0.05)

  return VStack(spacing: 60) {
    TranscriptionIndicatorView(status: .hidden, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(
      status: .recording,
      meter: .init(averagePower: 0.5, peakPower: 0.5),
      speech: speaking,
      liveText: "so what I'm saying is that the tail of the recording keeps getting cut off"
    )
    TranscriptionIndicatorView(
      status: .recording,
      meter: .init(averagePower: 0.2, peakPower: 0.3),
      recordingStartedAt: Date().addingTimeInterval(-1)
    )
    TranscriptionIndicatorView(
      status: .recording,
      meter: .init(averagePower: 0.05, peakPower: 0.05),
      recordingStartedAt: Date().addingTimeInterval(-5)
    )
    TranscriptionIndicatorView(
      status: .recording,
      meter: .init(averagePower: 0, peakPower: 0),
      isCapturing: false
    )
    TranscriptionIndicatorView(status: .transcribing, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .prewarming, meter: .init(averagePower: 0, peakPower: 0))
  }
  .padding(40)
}
