import ComposableArchitecture
import Dependencies
import Foundation
import HexCore
import os

private let maintenanceLogger = Logger(subsystem: HexLog.subsystem, category: "AudioMaintenance")

/// Keeps the recordings shelf within the size the user chose — and does nothing at all until it isn't.
///
/// Runs once at launch and once after each take is saved. The policy decides whether anything is due;
/// this only does the work, one bounded bite at a time so a pass never turns into a disk storm.
enum AudioMaintenance {
  /// Roughly how much audio rewriting one pass may do. The next pass picks up the rest.
  /// Halving is a straight rewrite, so a pass may take all of it; a squeeze is an encode, so one per pass.
  static let halvingBytesPerPass = 6_000_000_000
  static let squeezesPerPass = 1
  static let megabyte = 1_000_000

  static func isFloat32(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url),
          let header = try? handle.read(upToCount: 44), header.count == 44,
          header[12..<16] == Data("fmt ".utf8) else { return false }
    return header[20] == 3 // WAVE_FORMAT_IEEE_FLOAT
  }

  static func recordingsFolder() throws -> URL {
    try URL.hexApplicationSupport.appendingPathComponent("Recordings", isDirectory: true)
  }

  /// One pass. Cheap and silent when the shelf fits in its budget.
  static func run(history: Shared<TranscriptionHistory>, budget: AudioAgingPolicy.Budget) async {
    guard let budgetBytes = budget.bytes else { return }
    let policy = AudioAgingPolicy(budgetBytes: budgetBytes)
    let fm = FileManager.default

    guard let folder = try? recordingsFolder(),
          let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }

    // The one check before any lossy step: we must already have a usable transcript for the take.
    // Failed, empty, and unknown recordings are therefore never squeezed — their audio is the only
    // record of what was said, and compressing it would be irreversible.
    let transcribed = Set(
      history.withLock { history in
        history.history
          .filter { !$0.text.isEmpty && $0.status != .failed }
          .map(\.audioPath.lastPathComponent)
      }
    )

    let now = Date()
    var items: [AudioAgingPolicy.Item] = []
    for name in names where name.hasSuffix(".wav") || name.hasSuffix(".m4a") {
      let url = folder.appendingPathComponent(name)
      guard let attributes = try? fm.attributesOfItem(atPath: url.path),
            let bytes = attributes[.size] as? Int else { continue }
      let used = (attributes[.modificationDate] as? Date) ?? (attributes[.creationDate] as? Date) ?? now
      items.append(
        AudioAgingPolicy.Item(
          url: url,
          bytes: bytes,
          ageDays: max(0, now.timeIntervalSince(used) / 86_400),
          isFloat32: name.hasSuffix(".wav") && isFloat32(url),
          isExemptFromCompression: !transcribed.contains(name) && !name.isEmpty
        )
      )
    }

    let plan = policy.plan(for: items)
    guard !plan.isEmpty else { return }

    var spent = 0
    for url in plan.halve {
      guard spent < halvingBytesPerPass else { return }
      spent += ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
      let used = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
      do {
        if let result = try WavCompactor.compactTo16Bit(at: url) {
          if let used { try? fm.setAttributes([.modificationDate: used], ofItemAtPath: url.path) }
          maintenanceLogger.info("Halved \(url.lastPathComponent, privacy: .public): \(result.bytesBefore / megabyte) MB -> \(result.bytesAfter / megabyte) MB")
        }
      } catch {
        maintenanceLogger.error("Could not halve \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }

    for (index, url) in plan.squeeze.enumerated() {
      guard index < squeezesPerPass else { return }
      spent += ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
      do {
        let usedBefore = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        let result = try AudioCompressor.compress(url)
        if let usedBefore {
          try? fm.setAttributes([.modificationDate: usedBefore], ofItemAtPath: result.compressedURL.path)
        }
        let oldName = url.lastPathComponent
        history.withLock { history in
          for index in history.history.indices where history.history[index].audioPath.lastPathComponent == oldName {
            history.history[index].audioPath = result.compressedURL
          }
        }
        maintenanceLogger.notice("Compressed \(oldName, privacy: .public): \(result.bytesBefore / megabyte) MB -> \(result.bytesAfter / megabyte) MB")
      } catch {
        maintenanceLogger.error("Could not compress \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
