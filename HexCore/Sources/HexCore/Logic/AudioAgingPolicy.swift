import Foundation

/// When recordings are worth compressing, and which ones.
///
/// Two rules, in this order, and nothing happens until the shelf is over budget:
///
/// 1. **Halve before you squeeze.** A 32-bit float recording becomes 16-bit PCM first. That is
///    lossless in practice (speech never uses the extra headroom) and halves the shelf, often enough
///    on its own to get back under budget.
/// 2. **Then squeeze the ones that deserve it.** Only if the shelf is still over budget do takes get
///    encoded to AAC, ordered by *bytes saved × log(days old)*: a big file climbs the queue fast, an
///    old one climbs slowly, and a small take barely moves at all. Age never releases anything on its
///    own — it only decides who is at the front of the queue when the shelf has run out of room.
///
/// Nothing is deleted by any of this. Deleting audio is a separate, future decision.
public struct AudioAgingPolicy: Equatable, Sendable {
  /// The size the recordings folder is allowed to reach before anything is done.
  public var budgetBytes: Int
  /// Roughly what an AAC re-encode leaves behind, for planning only: 32 kbps against 32 KB/s of
  /// 16-bit audio is about 1/8.
  public var estimatedCompressedRatio: Double

  public init(budgetBytes: Int, estimatedCompressedRatio: Double = 0.125) {
    self.budgetBytes = budgetBytes
    self.estimatedCompressedRatio = estimatedCompressedRatio
  }

  /// How big the recordings shelf may get before anything is tidied.
  public enum Budget: String, CaseIterable, Codable, Equatable, Sendable {
    case off
    case oneGigabyte
    case twoGigabytes
    case fourGigabytes
    case eightGigabytes

    public var bytes: Int? {
      switch self {
      case .off: nil
      case .oneGigabyte: 1_000_000_000
      case .twoGigabytes: 2_000_000_000
      case .fourGigabytes: 4_000_000_000
      case .eightGigabytes: 8_000_000_000
      }
    }

    public var label: String {
      switch self {
      case .off: "Off"
      case .oneGigabyte: "1 GB"
      case .twoGigabytes: "2 GB"
      case .fourGigabytes: "4 GB"
      case .eightGigabytes: "8 GB"
      }
    }
  }

  /// A recording on the shelf, as the policy sees it.
  public struct Item: Equatable, Sendable {
    public let url: URL
    public let bytes: Int
    /// Whole days since the recording was last played or made.
    public let ageDays: Double
    /// Whether the file still needs the lossless halving step.
    public let isFloat32: Bool
    /// A take we have no usable transcript for — failed, empty, or not in history at all. Its audio
    /// is the only record of what was said, so it is never re-encoded. This is the one check that
    /// runs before squeezing: nothing gets the lossy treatment until it has been transcribed.
    public let isExemptFromCompression: Bool

    public init(url: URL, bytes: Int, ageDays: Double, isFloat32: Bool, isExemptFromCompression: Bool = false) {
      self.url = url
      self.bytes = bytes
      self.ageDays = ageDays
      self.isFloat32 = isFloat32
      self.isExemptFromCompression = isExemptFromCompression
    }
  }

  public struct Plan: Equatable, Sendable {
    /// Lossless: rewrite as 16-bit PCM, same file name.
    public var halve: [URL] = []
    /// Lossy: encode to AAC, biggest and oldest first.
    public var squeeze: [URL] = []

    public var isEmpty: Bool { halve.isEmpty && squeeze.isEmpty }
  }

  /// What to do with the shelf right now. Empty while the shelf fits.
  public func plan(for items: [Item]) -> Plan {
    var plan = Plan()
    var total = items.reduce(0) { $0 + $1.bytes }
    guard total > budgetBytes else { return plan }

    // 1. Halving costs nothing audible, so it is spent first — biggest recordings first, because
    // each one written is a recording rewritten, and few big ones get there quicker than many small.
    for item in items.filter(\.isFloat32).sorted(by: { $0.bytes > $1.bytes }) {
      guard total > budgetBytes else { break }
      total -= item.bytes / 2
      plan.halve.append(item.url)
    }
    // Never squeeze while any float recording is still waiting to be halved: the free half has to be
    // taken first, or a take would be re-encoded lossy at twice the size it needed to be.
    guard total > budgetBytes, !items.contains(where: \.isFloat32) else { return plan }

    // 2. Then the takes that deserve it, most expensive-and-least-touched first.
    let squeezeable = items
      .filter { !$0.isExemptFromCompression && !plan.halve.contains($0.url) }
      .sorted { score($0) > score($1) }
    for item in squeezeable {
      guard total > budgetBytes else { break }
      let after = Int(Double(item.bytes) * estimatedCompressedRatio)
      total -= item.bytes - after
      plan.squeeze.append(item.url)
    }
    return plan
  }

  /// Bytes saved × log(days): what compressing this take would buy, discounted by how likely you
  /// are to still want it. Logarithmic so that a month-old file is twice as pressing as a one-day-old
  /// one rather than thirty times.
  public func score(_ item: Item) -> Double {
    let saved = Double(item.bytes) * (1 - estimatedCompressedRatio)
    return saved * log2(1 + max(item.ageDays, 1))
  }
}
