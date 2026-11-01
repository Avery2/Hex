import Foundation

/// How much Hex is allowed to tidy a transcript before it becomes the text you get.
///
/// The ladder is ordered by how far each step gets from what was literally said, which is the only
/// ordering that matters for dictation: paragraphs and punctuation are whitespace and marks, filler
/// words are noise, and collapsing a self-correction throws away a sentence you actually spoke.
/// Every step is a deletion or whitespace — nothing here rewrites, reorders or adds a word, so the
/// worst case is "less clean than I hoped", never "different from what I said".
public enum CleanupLevel: String, Codable, CaseIterable, Equatable, Sendable {
  /// Paste exactly what was transcribed.
  case off
  /// Fillers, accidental repeats, punctuation repair and paragraph breaks.
  case light
  /// Also collapses a spoken self-correction to the version you landed on.
  case full

  public var label: String {
    switch self {
    case .off: "Off"
    case .light: "Light"
    case .full: "Full"
    }
  }

  public var explanation: String {
    switch self {
    case .off: "Paste exactly what you said."
    case .light: "Remove “like,” and “you know,”, split paragraphs, tidy punctuation."
    case .full: "Also collapse “no wait, I mean…” self-corrections to what you settled on."
    }
  }
}

/// What a cleanup pass did, in a form the bar can show as a one-line receipt.
public struct CleanupSummary: Equatable, Sendable {
  public var fillers = 0
  public var repeats = 0
  public var repairs = 0
  public var paragraphs = 0

  public var isEmpty: Bool {
    fillers == 0 && repeats == 0 && repairs == 0 && paragraphs == 0
  }

  /// e.g. "3 fillers · 1 repeat · 2 paragraphs"
  public var sentence: String {
    var parts: [String] = []
    if fillers > 0 { parts.append("\(fillers) filler\(fillers == 1 ? "" : "s")") }
    if repeats > 0 { parts.append("\(repeats) repeat\(repeats == 1 ? "" : "s")") }
    if repairs > 0 { parts.append("\(repairs) self-correction\(repairs == 1 ? "" : "s")") }
    if paragraphs > 0 { parts.append("\(paragraphs) paragraph\(paragraphs == 1 ? "" : "s")") }
    return parts.joined(separator: " · ")
  }
}

/// A transcript and the tidied version of it.
public struct CleanedTranscript: Equatable, Sendable {
  /// Exactly what the transcriber produced.
  public var raw: String
  /// What gets pasted.
  public var text: String
  public var summary: CleanupSummary

  public var hasChanges: Bool { text != raw }
}

/// Tidies dictation without changing what it says.
///
/// Deliberately rule-based rather than a model. Measured on the author's own 528 transcripts and
/// probed against Apple's on-device model: the model dropped clauses, substituted ~1 word per 300
/// (e.g. "there's" → "there are") and left the `like`s in, while these rules removed 2.3% of words
/// and every one of them was a filler or a doubled function word. For dictation, boring rules that
/// cannot invent text beat a model that can.
public enum TranscriptCleanup {
  /// Only delete. Words that happen to be fillers in one place are content in another, so "like"
  /// survives comparisons and quotations.
  private static let likeIsComparison = try! NSRegularExpression(
    pattern: #"\b(?:was|were|is|are|am|be|been|being|looks?|sounds?|feels?|seems?|something|anything|nothing|more|just|stuff|things|much|very)\s+$"#,
    options: [.caseInsensitive]
  )

  /// Function words repeat by accident ("the the", "i i"). Anything else repeating is more likely
  /// emphasis — "no no no" — so it is left alone.
  private static let repeatableWords: Set<String> = [
    "the", "a", "an", "this", "these", "those", "i", "you", "we", "they", "he", "she", "it",
    "to", "of", "in", "on", "at", "for", "with", "and", "but", "or", "so", "is", "was", "are",
    "were", "be", "been", "being", "my", "your", "his", "her", "their", "our", "what", "if", "as",
    "do", "does", "did",
  ]

  private static let fillerPatterns: [(String, String)] = [
    // ", like, " — the pure interjection form, including chains of them. Both commas go: they
    // existed only to fence the filler off.
    (#",\s*like\s*,"#, " "),
    (#",\s*you know\s*,"#, " "),
    (#",\s*i mean\s*,"#, " "),
    // "..., you know." / "..., i mean?" — trailing, where the marker is all that's left of the clause.
    (#",\s*you know\s*([.!?])"#, "$1"),
    (#",\s*i mean\s*([.!?])"#, "$1"),
  ]

  /// A marker at the start of a clause, always followed by a comma: "so like, we…".
  private static let clauseInitialFiller = try! NSRegularExpression(
    pattern: #"(^|[.!?]\s+|\b(?:and|but|so|because|where|which|that|then|or|if|when|while|also|plus)\s+)(?:like|you know|i mean)\s*,\s*"#,
    options: [.caseInsensitive]
  )

  private static let repairMarker = try! NSRegularExpression(
    pattern: #"(?:no wait|wait no|scratch that|never mind|nevermind)"#,
    options: [.caseInsensitive]
  )

  private static let discourseStarts = try! NSRegularExpression(
    pattern: #"^(?:so|and then|then|but|anyway|anyways|okay|alright|now|also|plus|because|which|where|like)\b"#,
    options: [.caseInsensitive]
  )

  public static func clean(_ raw: String, level: CleanupLevel) -> CleanedTranscript {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard level != .off, !trimmed.isEmpty else {
      return CleanedTranscript(raw: raw, text: raw, summary: CleanupSummary())
    }

    var summary = CleanupSummary()
    var text = typography(trimmed)
    text = removeFillers(text, summary: &summary)
    text = collapseRepeats(text, summary: &summary)
    text = mergeFragments(text, summary: &summary)
    if level == .full {
      text = collapseRepair(text, summary: &summary)
    }
    text = paragraphs(text, summary: &summary)
    text = typography(text)

    return CleanedTranscript(raw: raw, text: text, summary: summary)
  }

  // MARK: - Passes

  /// Whitespace and marks only: no word moves.
  static func typography(_ text: String) -> String {
    var out = text
    out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    out = out.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
    out = out.replacingOccurrences(of: #",{2,}"#, with: ",", options: .regularExpression)
    out = out.replacingOccurrences(of: #"\s*,\s*"#, with: ", ", options: .regularExpression)
    out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    // Speech ends when it ends: a transcript with no closing mark reads as broken once pasted.
    if let last = out.last, last.isLetter || last.isNumber {
      out += "."
    }
    return out
  }

  static func removeFillers(_ text: String, summary: inout CleanupSummary) -> String {
    var out = text

    // Chains (", like, you know,") need more than one pass, and each edit counts.
    for _ in 0..<4 {
      let before = out
      for (pattern, replacement) in fillerPatterns {
        let matches = matches(of: pattern, in: out)
        summary.fillers += matches.count
        out = regexReplace(pattern, in: out, with: replacement)
      }
      if out == before { break }
    }

    // "so like, accuracy is…" — keep the conjunction, drop the marker.
    out = replaceMatches(clauseInitialFiller, in: out) { match, string in
      guard let prefixRange = Range(match.range(at: 1), in: string) else { return nil }
      let prefix = String(string[prefixRange])
      // "…was like," and friends are quotations, not fillers.
      if likeIsComparison.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil {
        return nil
      }
      summary.fillers += 1
      return prefix
    }

    return out
  }

  static func collapseRepeats(_ text: String, summary: inout CleanupSummary) -> String {
    let pattern = try! NSRegularExpression(
      pattern: #"\b(\w+)\s+\1\b(?!\s+\1)"#,
      options: [.caseInsensitive]
    )
    return replaceMatches(pattern, in: text) { match, string in
      guard let word = Range(match.range(at: 1), in: string).map({ String(string[$0]) }) else { return nil }
      let lowered = word.lowercased()
      // "that that" is grammatical more often than it is a stutter, so it stays.
      guard repeatableWords.contains(lowered), lowered != "that" else { return nil }
      summary.repeats += 1
      return word
    }
  }

  /// A phrase said twice in a row, and a word cut off mid-air before its own retry.
  ///
  /// Only adjacent, identical phrases are collapsed ("the thing is the thing is"), never a phrase
  /// that merely recurs later, and never emphatic reduplication ("very, very") — the stoplist is
  /// the one Germesin & Becker used for the same rule (P/R ≈ .88 on AMI).
  static func mergeFragments(_ text: String, summary: inout CleanupSummary) -> String {
    var out = text

    // "proc- we processed" / "the the" fragments: a hyphen says the word was cut off on purpose.
    let fragments = try! NSRegularExpression(
      pattern: #"\b(\w{2,})-\s*(\w+)\b"#,
      options: [.caseInsensitive]
    )
    out = replaceMatches(fragments, in: out) { match, string in
      guard let aRange = Range(match.range(at: 1), in: string),
            let bRange = Range(match.range(at: 2), in: string) else { return nil }
      let a = String(string[aRange]).lowercased()
      let b = String(string[bRange]).lowercased()
      guard a.count >= 2, b.hasPrefix(a), !fragmentFalseFriends.contains(a) else { return nil }
      summary.repeats += 1
      return String(string[bRange])
    }

    // Whole phrases repeated back to back, up to six words.
    let phrases = try! NSRegularExpression(
      pattern: #"\b((?:\w+[',]?\s+){1,5}\w+)[,\s]+\1\b"#,
      options: [.caseInsensitive]
    )
    out = replaceMatches(phrases, in: out) { match, string in
      guard let range = Range(match.range(at: 1), in: string) else { return nil }
      let phrase = String(string[range])
      let words = phrase.lowercased().split(whereSeparator: { !$0.isLetter })
      // "no no no" style emphasis and tiny repeats are left alone.
      guard words.count >= 2, words.count <= 6 else { return nil }
      guard !words.allSatisfy({ reduplicationWords.contains(String($0)) }) else { return nil }
      summary.repeats += 1
      return phrase
    }
    return out
  }

  /// Words whose repetition is usually deliberate.
  private static let reduplicationWords: Set<String> = [
    "very", "really", "no", "yes", "right", "okay", "bye", "ha", "so", "like", "now", "just",
  ]

  /// Collapses a spoken repair to what you kept, using Levelt's rule.
  ///
  /// The marker only says "a repair happened here" — nothing is deleted because a marker appears.
  /// The words before it are compared with the words after it, and only the stretch that is
  /// *repeated* is deleted (Levelt 1983, via Heeman & Allen 1994: works on ~50% of repairs, provably
  /// wrong on ~2%). "the other driver was, i mean, was going through" → "…was going through", while
  /// "staging cluster, no wait, production cluster" is left exactly as said, because deciding which
  /// of those you meant is rewriting, not cleanup.
  static func collapseRepair(_ text: String, summary: inout CleanupSummary) -> String {
    var out = text
    let markers = matches(of: repairMarkers, in: out)
    guard !markers.isEmpty else { return out }

    for marker in markers.reversed() {
      guard let markerRange = Range(marker.range, in: out) else { continue }

      // The words on each side of the marker, each bounded to six (Heeman & Allen 1994; Shriberg
      // found fewer than 1% of disfluencies delete more than six words).
      let before = Array(tokens(of: out[out.startIndex..<markerRange.lowerBound]).suffix(6))
      let after = Array(tokens(of: out[markerRange.upperBound...]).prefix(6))

      // Longest suffix of `before` that is also the start of `after`.
      var overlap = 0
      for length in stride(from: min(before.count, after.count), through: 1, by: -1) {
        if Array(before.suffix(length)) == Array(after.prefix(length)) {
          overlap = length
          break
        }
      }
      // One repeated word is too thin to be sure ("I think it was — I think"), so require two.
      guard overlap >= 2 else { continue }

      // Delete from the start of the repeated stretch through the end of the marker (and the
      // punctuation that fenced it). The repair keeps its own copy of those words.
      let stretch = before.suffix(overlap).joined(separator: " ")
      guard let stretchStart = out.range(of: stretch, options: [.caseInsensitive, .backwards], range: out.startIndex..<markerRange.lowerBound)?.lowerBound else { continue }
      var end = markerRange.upperBound
      while let next = out[end...].first, next == "," || next == ";" || next.isWhitespace {
        end = out.index(after: end)
        if end == out.endIndex { break }
      }
      // Leave the punctuation that ended the pre-marker clause where it is.
      out.replaceSubrange(stretchStart..<end, with: "")
      summary.repairs += 1
    }
    return out
  }

  /// Editing terms from the annotation literature (Switchboard/Meteer, Shriberg, LARD), not
  /// invented here. They license a repair; they are never deleted on their own.
  static let repairMarkers = #"(?:no wait|wait no|scratch that|never mind|nevermind|i mean|i meant to say|or rather|let me rephrase|make that|i should say|sorry|oops|excuse me)"#

  /// Very short words that are more likely a real word than a cut-off fragment.
  private static let fragmentFalseFriends: Set<String> = ["for", "the", "and", "but", "you", "not", "one", "two", "his", "her", "our", "its", "was", "were", "have", "will", "with", "this", "that", "they", "them"]

  /// Long dictation arrives as one wall of sentences. Break it where the speaker changes gear.
  static func paragraphs(_ text: String, summary: inout CleanupSummary) -> String {
    guard text.split(whereSeparator: \.isWhitespace).count >= 80 else { return text }
    let sentences = splitSentences(text)
    guard sentences.count > 3 else { return text }

    var out: [String] = []
    var buffer: [String] = []
    for (index, sentence) in sentences.enumerated() {
      buffer.append(sentence)
      let next = index + 1 < sentences.count ? sentences[index + 1] : nil
      guard let next else { continue }
      let nextStartsNewThought = discourseStarts.firstMatch(
        in: next, range: NSRange(next.startIndex..., in: next)
      ) != nil
      if buffer.count >= 5 || (buffer.count >= 3 && nextStartsNewThought) {
        out.append(buffer.joined(separator: " "))
        buffer = []
      }
    }
    if !buffer.isEmpty { out.append(buffer.joined(separator: " ")) }
    summary.paragraphs = max(0, out.count - 1)
    return out.joined(separator: "\n\n")
  }

  // MARK: - Helpers

  /// Splits on sentence endings without needing capital letters to tell it where they are.
  static func splitSentences(_ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+"#)
    let ns = text as NSString
    var sentences: [String] = []
    var cursor = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      sentences.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
      cursor = match.range.location + match.range.length
    }
    sentences.append(ns.substring(from: cursor))
    return sentences
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// Words in order, punctuation dropped, for alignment.
  private static func tokens(of text: Substring) -> [String] {
    text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }

  /// Comparison form of a clause: lowercase words, punctuation dropped.
  private static func words(_ text: Substring) -> [String] {
    text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
      .filter { !$0.isEmpty }
  }

  private static func contentWords(_ text: Substring) -> [String] {
    text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
      .filter { $0.count > 2 && !repeatableWords.contains($0) }
  }

  private static func matches(of pattern: String, in text: String) -> [NSTextCheckingResult] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
  }

  private static func regexReplace(_ pattern: String, in text: String, with replacement: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
    return regex.stringByReplacingMatches(
      in: text,
      range: NSRange(text.startIndex..., in: text),
      withTemplate: replacement
    )
  }

  /// Applies a match-by-match edit back to front, so ranges stay valid. `transform` returns the
  /// replacement for the whole match, or nil to leave it alone.
  private static func replaceMatches(
    _ regex: NSRegularExpression,
    in text: String,
    transform: (NSTextCheckingResult, String) -> String?
  ) -> String {
    var out = text
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let range = Range(match.range, in: out) ?? Range(match.range, in: text),
            let replacement = transform(match, text)
      else { continue }
      out.replaceSubrange(range, with: replacement)
    }
    return out
  }
}

// MARK: - What the levels actually do

/// One rule, as the app shows it: the pattern the code runs and what it becomes.
public struct CleanupRule: Identifiable, Equatable, Sendable {
  public let id: String
  public let pattern: String
  public let replacement: String
  /// A sentence this rule changes; the tests require it to actually change it.
  public let sample: String
}

/// A named group of rules with the one sentence that explains it.
///
/// Grouped and explained rather than dumped: a bare regex table is precise and unreadable, and a
/// paragraph about "filler words" is readable and useless. Each group states what happens, shows the
/// pattern, and demonstrates it on a real sentence.
public struct CleanupGroup: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let explanation: String
  public let minimumLevel: CleanupLevel
  public let rules: [CleanupRule]
  /// Run through the current level to produce the example line under the group.
  public let sample: String
}

public extension TranscriptCleanup {
  /// The rules, grouped as the app shows them, in the order they are applied.
  static var groups: [CleanupGroup] {
    [
      CleanupGroup(
        id: "commas",
        title: "Fillers inside commas",
        explanation: "Only when a comma sits on both sides, so “I was like” and “looks like that” survive.",
        minimumLevel: .light,
        rules: [
          CleanupRule(id: "like", pattern: #",\s*like\s*,"#, replacement: "removed", sample: "so, like, we could try it."),
          CleanupRule(id: "you-know", pattern: #",\s*you know\s*,"#, replacement: "removed", sample: "we could, you know, try it."),
          CleanupRule(id: "i-mean", pattern: #",\s*i mean\s*,"#, replacement: "removed", sample: "it is, i mean, fine."),
          CleanupRule(id: "trailing", pattern: #",\s*(you know|i mean)\s*([.!?])"#, replacement: "$2", sample: "i finished it, you know."),
        ],
        sample: "so, like, we could, you know, try it."
      ),
      CleanupGroup(
        id: "clause",
        title: "Fillers after a joining word",
        explanation: "“so like, accuracy matters” loses the “like”. Never after “was”, “looks” or “something”.",
        minimumLevel: .light,
        rules: [
          CleanupRule(
            id: "clause",
            pattern: #"(\band|\bbut|\bso|\bbecause|\bwhere|\bwhich|\bthen)\s+(like|you know|i mean)\s*,\s*"#,
            replacement: "$1 ",
            sample: "so like, accuracy matters."
          ),
        ],
        sample: "so like, accuracy matters more than speed."
      ),
      CleanupGroup(
        id: "repeats",
        title: "Words said twice",
        explanation: "A repeated function word, or a phrase repeated straight away. Emphasis (“no no no”, “very, very”) is left alone.",
        minimumLevel: .light,
        rules: [
          CleanupRule(id: "repeats", pattern: #"\b(\w+)\s+\1\b"#, replacement: "$1", sample: "pour the the water."),
          CleanupRule(id: "phrases", pattern: #"\b((\w+\s+){1,5}\w+)[,\s]+\1\b"#, replacement: "$1", sample: "the thing is the thing is that it broke."),
        ],
        sample: "pour the the water, and the thing is the thing is fine."
      ),
      CleanupGroup(
        id: "fragments",
        title: "Cut-off words",
        explanation: "A word the transcriber broke off with a hyphen, when the next word finishes it.",
        minimumLevel: .light,
        rules: [
          CleanupRule(id: "fragments", pattern: #"\b(\w{2,})-\s*(\w+)\b"#, replacement: "$2", sample: "i was th- thinking about it."),
        ],
        sample: "i was th- thinking about it."
      ),
      CleanupGroup(
        id: "marks",
        title: "Punctuation and spacing",
        explanation: "Marks tidied, stray commas removed, and a take that stops mid-air gets a full stop.",
        minimumLevel: .light,
        rules: [
          CleanupRule(id: "marks-space", pattern: #"\s+([,.;:!?])"#, replacement: "$1", sample: "hello , world."),
          CleanupRule(id: "marks-commas", pattern: #"\s*,\s*"#, replacement: ", ", sample: "hello ,  world."),
          CleanupRule(id: "marks-gaps", pattern: #"[ \t]{2,}"#, replacement: " ", sample: "two  spaces"),
          CleanupRule(id: "marks-stop", pattern: #"[a-z0-9]$"#, replacement: "$0.", sample: "and that is the end"),
        ],
        sample: "hello ,  world from  the the other side"
      ),
      CleanupGroup(
        id: "paragraphs",
        title: "Paragraphs",
        explanation: "Takes past about eighty words break every five sentences — or three, when the next one starts with “so”, “but”, “then”.",
        minimumLevel: .light,
        rules: [
          CleanupRule(
            id: "paragraphs",
            pattern: #"(?<=[.!?])\s+"#,
            replacement: #"\n\n"#,
            sample: (1...14).map { "sentence number \($0) is here and it has a few words" }.joined(separator: ". ") + "."
          ),
        ],
        sample: (1...14).map { "sentence number \($0) is here and it has a few words" }.joined(separator: ". ") + "."
      ),
      CleanupGroup(
        id: "repairs",
        title: "Self-corrections",
        explanation: "Only the repeated stretch is dropped: the words before and after the marker have to overlap by two or more. “staging cluster, no wait, production cluster” is left exactly as said.",
        minimumLevel: .full,
        rules: [
          CleanupRule(
            id: "repairs",
            pattern: #"(no wait|wait no|i mean|sorry|oops|or rather|make that|never mind|…)"#,
            replacement: "the repeated words around it",
            sample: "i think it was, sorry, i think it was fine."
          ),
        ],
        sample: "i think it was, sorry, i think it was fine."
      ),
    ]
  }

  static var rules: [CleanupRule] { groups.flatMap(\.rules) }
}
