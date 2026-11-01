import Foundation
import Testing
@testable import HexCore

@Suite("Audio aging policy")
struct AudioAgingPolicyTests {
  private func item(_ name: String, megabytes: Int, ageDays: Double, float: Bool = false, unrecoverable: Bool = false) -> AudioAgingPolicy.Item {
    AudioAgingPolicy.Item(
      url: URL(fileURLWithPath: "/tmp/\(name).wav"),
      bytes: megabytes * 1_000_000,
      ageDays: ageDays,
      isFloat32: float,
      isExemptFromCompression: unrecoverable
    )
  }

  @Test("Under budget: nothing happens at all")
  func underBudgetIsUntouched() {
    let policy = AudioAgingPolicy(budgetBytes: 2_000_000_000)
    let shelf = [item("a", megabytes: 500, ageDays: 40), item("b", megabytes: 400, ageDays: 90)]
    #expect(policy.plan(for: shelf).isEmpty)
  }

  @Test("Over budget: halve first, and stop there if that is enough")
  func halvesBeforeSqueezing() {
    let policy = AudioAgingPolicy(budgetBytes: 1_000_000_000)
    let shelf = [
      item("old-float", megabytes: 900, ageDays: 60, float: true),
      item("new-float", megabytes: 900, ageDays: 1, float: true),
    ]
    let plan = policy.plan(for: shelf)
    #expect(!plan.halve.isEmpty)
    #expect(plan.squeeze.isEmpty, "1.8 GB of float halves to 0.9 GB, which fits the 1 GB budget")
  }

  @Test("Still over after halving: squeeze biggest and oldest first")
  func squeezesBiggestAndOldestFirst() {
    let policy = AudioAgingPolicy(budgetBytes: 1_000_000_000)
    let shelf = [
      item("small-old", megabytes: 100, ageDays: 30),   // score 3,000
      item("huge-new", megabytes: 900, ageDays: 1),     // score 900
      item("huge-old", megabytes: 600, ageDays: 20),    // score 12,000
      item("medium", megabytes: 200, ageDays: 10),      // score 2,000
    ]
    let plan = policy.plan(for: shelf)
    #expect(plan.halve.isEmpty)
    #expect(plan.squeeze.first?.lastPathComponent == "huge-old.wav")
    // 1.8 GB of audio; one 600 MB re-encode saves 525 MB, so it needs the biggest first.
    #expect(plan.squeeze.contains { $0.lastPathComponent == "huge-new.wav" })
    #expect(!plan.squeeze.contains { $0.lastPathComponent == "small-old.wav" }, "small takes are last in line")
  }

  @Test("A take with no usable transcript is never re-encoded")
  func keepsTheOnlyRecordOfWhatWasSaid() {
    let policy = AudioAgingPolicy(budgetBytes: 1_000)
    let shelf = [
      item("failed", megabytes: 900, ageDays: 99, unrecoverable: true),
      item("fine", megabytes: 100, ageDays: 1),
    ]
    let plan = policy.plan(for: shelf)
    #expect(!plan.squeeze.contains { $0.lastPathComponent == "failed.wav" })
  }

  @Test("Budget choices map to sizes, including off")
  func budgets() {
    #expect(AudioAgingPolicy.Budget.off.bytes == nil)
    #expect(AudioAgingPolicy.Budget.twoGigabytes.bytes == 2_000_000_000)
    #expect(AudioAgingPolicy.Budget.fourGigabytes.bytes == 4_000_000_000)
    #expect(AudioAgingPolicy.Budget.allCases.count == 5)
  }
}
