import Foundation

/// A transcript split into what survived cleanup and what it removed, for showing the change.
///
/// Dictation cleanup only ever deletes words, so the interesting question is "which words went?"
/// — and a word-aligned diff answers exactly that. Removed runs are kept in place (rather than
/// shown as a separate list) so the bar can strike them out where they were and put one back.
public enum TranscriptDiff {
  public struct Segment: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
      /// Still in the cleaned text.
      case kept
      /// Removed by cleanup; can be put back.
      case removed
    }

    public let id: Int
    public let kind: Kind
    public let text: String

    public init(id: Int, kind: Kind, text: String) {
      self.id = id
      self.kind = kind
      self.text = text
    }
  }

  /// Word-aligned segments. Whitespace is carried with the word that follows it, so joining the
  /// segments reproduces the text.
  public static func segments(raw: String, cleaned: String) -> [Segment] {
    let rawWords = words(of: raw)
    let cleanedWords = words(of: cleaned)

    // Longest common subsequence over words, computed as a table of common-suffix lengths.
    let n = rawWords.count
    let m = cleanedWords.count
    var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    if n > 0 && m > 0 {
      for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
          lcs[i][j] = rawWords[i].core == cleanedWords[j].core
            ? lcs[i + 1][j + 1] + 1
            : max(lcs[i + 1][j], lcs[i][j + 1])
        }
      }
    }

    var segments: [Segment] = []
    var id = 0
    var i = 0
    var j = 0

    func append(_ kind: Segment.Kind, _ text: String) {
      if var last = segments.last, last.kind == kind {
        last = Segment(id: last.id, kind: kind, text: last.text + text)
        segments[segments.count - 1] = last
      } else {
        segments.append(Segment(id: id, kind: kind, text: text))
        id += 1
      }
    }

    while i < n && j < m {
      if rawWords[i].core == cleanedWords[j].core {
        append(.kept, rawWords[i].text)
        i += 1
        j += 1
      } else if lcs[i + 1][j] >= lcs[i][j + 1] {
        append(.removed, rawWords[i].text)
        i += 1
      } else {
        // Cleanup never adds words, but a caller could pass a rewritten pair; keep the extra.
        append(.kept, cleanedWords[j].text)
        j += 1
      }
    }
    while i < n { append(.removed, rawWords[i].text); i += 1 }
    while j < m { append(.kept, cleanedWords[j].text); j += 1 }

    return segments
  }

  /// The text with `restored` removals put back — what the bar should paste.
  public static func text(_ segments: [Segment], restoring restored: Set<Int>) -> String {
    segments
      .filter { $0.kind == .kept || restored.contains($0.id) }
      .map(\.text)
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private struct Word {
    /// Leading whitespace plus the word itself, so joining is lossless.
    let text: String
    /// Comparison form: letters and digits only, lowercased.
    let core: String
  }

  private static func words(of text: String) -> [Word] {
    var words: [Word] = []
    var pending = ""
    var current = ""
    for character in text {
      if character.isWhitespace {
        if current.isEmpty { pending.append(character) } else {
          words.append(Word(text: pending + current, core: core(current)))
          pending = String(character)
          current = ""
        }
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { words.append(Word(text: pending + current, core: core(current))) }
    return words
  }

  private static func core(_ word: String) -> String {
    word.lowercased().filter { $0.isLetter || $0.isNumber }
  }
}
