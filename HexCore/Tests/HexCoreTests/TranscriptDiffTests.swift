import Testing
@testable import HexCore

@Suite("Transcript diff")
struct TranscriptDiffTests {
  @Test("Removed words are marked where they were, kept words survive in order")
  func marksRemovals() {
    let raw = "so, like, we could try it."
    let cleaned = "so we could try it."
    let segments = TranscriptDiff.segments(raw: raw, cleaned: cleaned)
    #expect(segments.contains { $0.kind == .removed && $0.text.contains("like") })
    #expect(TranscriptDiff.text(segments, restoring: []).contains("we could try it"))
    #expect(!TranscriptDiff.text(segments, restoring: []).contains("like"))
  }

  @Test("Restoring a removal puts the original words back")
  func restores() {
    let raw = "pour the the water."
    let cleaned = "pour the water."
    let segments = TranscriptDiff.segments(raw: raw, cleaned: cleaned)
    let removedIDs = Set(segments.filter { $0.kind == .removed }.map(\.id))
    #expect(!removedIDs.isEmpty)
    let restored = TranscriptDiff.text(segments, restoring: removedIDs)
    #expect(restored.split(separator: " ").count == raw.split(separator: " ").count)
  }

  @Test("An unchanged transcript is one kept segment")
  func unchanged() {
    let text = "nothing to clean here."
    let segments = TranscriptDiff.segments(raw: text, cleaned: text)
    #expect(segments.count == 1)
    #expect(segments.first?.kind == .kept)
  }
}
