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
  /// What the mic levels say about whether words are actually being captured.
  var speech: SpeechActivityDetector = .init()
  /// When the current recording started; used to decide when silence is worth mentioning.
  var recordingStartedAt: Date?

  let transcribeBaseColor: Color = .blue
  private var backgroundColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording:
      return mixedColor(mixedNSColor(.red, with: .black, by: 0.5), with: .red, by: meter.averagePower * 3)
    case .transcribing: return mixedColor(.blue, with: .black, by: 0.5)
    case .prewarming: return mixedColor(.blue, with: .black, by: 0.5)
    }
  }

  /// The outline carries the capture verdict, which is deliberately a different channel from
  /// the fill's loudness: loudness alone can't tell a quiet room from a dead microphone, and
  /// it says nothing about whether the transcriber can make words out of what it hears.
  private var captureColor: Color {
    switch speech.quality {
    case .waiting: return Color.white.opacity(0.25)
    case .good: return .green
    case .tooQuiet: return .yellow
    case .clipping: return .orange
    }
  }

  private var strokeColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording: return captureColor
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

  /// Text worth showing only when something needs fixing, so the indicator stays tiny.
  private var hint: String? {
    switch speech.quality {
    case .tooQuiet: return "Too quiet"
    case .clipping: return "Clipping"
    case .good: return nil
    case .waiting:
      // Nothing speech-like for a couple of seconds of recording is nearly always the
      // microphone (wrong device, muted, unplugged) rather than a quiet room.
      guard status == .recording, let startedAt = recordingStartedAt else { return nil }
      return Date().timeIntervalSince(startedAt) > 2.5 ? "Not hearing you" : nil
    }
  }

  @State var transcribeEffect = 0

  var body: some View {
    let averagePower = min(1, meter.averagePower * 3)
    let peakPower = min(1, meter.peakPower * 3)
    ZStack {
      Capsule()
        .fill(backgroundColor.shadow(.inner(color: innerShadowColor, radius: 4)))
        .overlay {
          Capsule()
            .stroke(strokeColor, lineWidth: status == .recording ? 1.5 : 1)
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
        // A green halo only while words are actively arriving, so the outline reads as
        // "I'm getting this" rather than just "something is loud".
        .shadow(
          color: status == .recording && speech.isSpeaking ? captureColor.opacity(0.7) : .clear,
          radius: 6
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
        .task(id: status == .transcribing) {
          while status == .transcribing, !Task.isCancelled {
            transcribeEffect += 1
            try? await Task.sleep(for: .seconds(0.25))
          }
        }
      
      // Tooltip above the capsule: prewarming status, or a capture problem worth fixing.
      if let message = status == .prewarming ? "Model prewarming..." : hint {
        VStack(spacing: 4) {
          Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.8))
            )
        }
        .offset(y: -24)
        .transition(.opacity)
        .zIndex(2)
      }
    }
    .animation(.easeInOut(duration: 0.15), value: hint)
    .enableInjection()
  }
}

#Preview("HEX") {
  var speaking = SpeechActivityDetector()
  speaking.ingest(averagePower: 0.05, peakPower: 0.2)
  var quiet = SpeechActivityDetector()
  quiet.ingest(averagePower: 0.006, peakPower: 0.02)

  return VStack(spacing: 8) {
    TranscriptionIndicatorView(status: .hidden, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .optionKeyPressed, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(
      status: .recording,
      meter: .init(averagePower: 0.5, peakPower: 0.5),
      speech: speaking
    )
    TranscriptionIndicatorView(
      status: .recording,
      meter: .init(averagePower: 0.2, peakPower: 0.3),
      speech: quiet
    )
    TranscriptionIndicatorView(
      status: .recording,
      meter: .init(averagePower: 0.05, peakPower: 0.05),
      recordingStartedAt: Date().addingTimeInterval(-5)
    )
    TranscriptionIndicatorView(status: .transcribing, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .prewarming, meter: .init(averagePower: 0, peakPower: 0))
  }
  .padding(40)
}
