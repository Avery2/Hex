//
//  SoundEffect.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AVFoundation
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import SwiftUI

// Thank you. Never mind then.What a beautiful idea.
public enum SoundEffect: String, CaseIterable {
  case pasteTranscript
  case startRecording
  case stopRecording
  case cancel

  public var fileName: String {
    self.rawValue
  }

  var fileExtension: String {
    "mp3"
  }
}

@DependencyClient
public struct SoundEffectsClient {
  public var play: @Sendable (SoundEffect) -> Void
  public var stop: @Sendable (SoundEffect) -> Void
  public var stopAll: @Sendable () -> Void
  public var preloadSounds: @Sendable () async -> Void
  public var setEnabled: @Sendable (Bool) async -> Void
}

extension SoundEffectsClient: DependencyKey {
  public static var liveValue: SoundEffectsClient {
    let live = SoundEffectsClientLive()
    return SoundEffectsClient(
      play: { soundEffect in
        Task { await live.play(soundEffect) }
      },
      stop: { soundEffect in
        Task { await live.stop(soundEffect) }
      },
      stopAll: {
        Task { await live.stopAll() }
      },
      preloadSounds: {
        await live.preloadSounds()
      },
      setEnabled: { enabled in
        await live.setEnabled(enabled)
      }
    )
  }
}

public extension DependencyValues {
  var soundEffects: SoundEffectsClient {
    get { self[SoundEffectsClient.self] }
    set { self[SoundEffectsClient.self] = newValue }
  }
}

/// Plays short UI sounds with `AVAudioPlayer` rather than an `AVAudioEngine` graph.
///
/// `AVAudioPlayerNode.play()` raises an Objective-C exception — which surfaces as an
/// uncatchable `abort()` in Swift — whenever the engine is not running or the graph was
/// invalidated by an output-device change. That aborted Hex outright (see the
/// `AVAudioPlayerNodeImpl::StartImpl` crashes in `~/Library/Logs/DiagnosticReports`), and it
/// happened on the recording-start/stop sound path, i.e. exactly when the audio graph is
/// being torn down and rebuilt. `AVAudioPlayer` owns its own audio queue, survives device
/// changes, and reports failure by returning `false` instead of throwing, so a bad audio
/// state degrades to a silent sound effect instead of a dead app.
actor SoundEffectsClientLive {
  private let logger = HexLog.sound
  private let baselineVolume = HexSettings.baseSoundEffectsVolume

  @Shared(.hexSettings) var hexSettings: HexSettings
  /// One long-lived player per effect, so playback never re-decodes the file.
  private var players: [SoundEffect: AVAudioPlayer] = [:]
  private var isSetup = false

  func play(_ soundEffect: SoundEffect) {
    guard hexSettings.soundEffectsEnabled else { return }
    guard let player = players[soundEffect] else {
      logger.error("Requested sound \(soundEffect.rawValue) not preloaded")
      return
    }

    player.volume = Float(clampedVolume)
    // `stop()` leaves `currentTime` where it was, so rewind explicitly to keep rapid
    // re-triggers (start/stop/start) audible instead of silently no-oping.
    player.stop()
    player.currentTime = 0

    guard player.play() else {
      logger.error("AVAudioPlayer declined to play \(soundEffect.rawValue)")
      return
    }
  }

  func stop(_ soundEffect: SoundEffect) {
    players[soundEffect]?.stop()
  }

  func stopAll() {
    players.values.forEach { $0.stop() }
  }

  func preloadSounds() async {
    guard !isSetup else { return }

    for soundEffect in SoundEffect.allCases {
      loadSound(soundEffect)
    }

    isSetup = true
  }

  func setEnabled(_: Bool) async {
    await preloadSounds()

    if !hexSettings.soundEffectsEnabled {
      stopAll()
    }
  }

  private var clampedVolume: Double {
    min(max(hexSettings.soundEffectsVolume, 0), baselineVolume)
  }

  private func loadSound(_ soundEffect: SoundEffect) {
    guard let url = Bundle.main.url(
      forResource: soundEffect.fileName,
      withExtension: soundEffect.fileExtension
    ) else {
      logger.error("Missing sound resource \(soundEffect.fileName).\(soundEffect.fileExtension)")
      return
    }

    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.volume = Float(clampedVolume)
      players[soundEffect] = player
    } catch {
      logger.error("Failed to load sound \(soundEffect.rawValue): \(error.localizedDescription)")
    }
  }
}
