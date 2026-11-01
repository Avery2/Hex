import Foundation
import Testing
@testable import HexCore

@Suite("Transcript cleanup")
struct TranscriptCleanupTests {
  private func light(_ text: String) -> CleanedTranscript {
    TranscriptCleanup.clean(text, level: .light)
  }

  @Test("Off changes nothing")
  func offIsUntouched() {
    let raw = "so, like, this is  a  test"
    #expect(TranscriptCleanup.clean(raw, level: .off).text == raw)
  }

  @Test("Comma-flanked fillers go, including chains")
  func removesFlankedFillers() {
    #expect(light("so, like, we could, you know, try it.").text == "so we could try it.")
    #expect(light("and, like, you know, maybe.").text == "and maybe.")
    #expect(light("it is, i mean, fine.").text == "it is fine.")
  }

  @Test("A filler at the start of a clause keeps the conjunction")
  func removesClauseInitialFiller() {
    #expect(light("so like, accuracy is the most important.").text == "so accuracy is the most important.")
    #expect(light("then like, we left.").text == "then we left.")
  }

  @Test("Comparisons and quotations keep their like")
  func keepsLikeThatIsNotAFiller() {
    for sentence in [
      "it was like, no way.",
      "that looks like the one.",
      "i want something like that.",
      "i was like, what?",
      "more like a suggestion.",
    ] {
      #expect(light(sentence).text == sentence, "should not touch: \(sentence)")
    }
  }

  @Test("Trailing discourse markers are dropped but questions are not")
  func keepsRealQuestions() {
    #expect(light("i finished it, you know.").text == "i finished it.")
    #expect(light("you know what i mean?").text == "you know what i mean?")
  }

  @Test("Accidental repeats of function words collapse; emphasis does not")
  func collapsesOnlyAccidentalRepeats() {
    #expect(light("pour the the water.").text == "pour the water.")
    #expect(light("i i think so.").text == "i think so.")
    #expect(light("no no no, stop.").text == "no no no, stop.")
    #expect(light("the idea that that was wrong.").text == "the idea that that was wrong.")
    #expect(light("very very good.").text == "very very good.")
  }

  @Test("Punctuation and whitespace are repaired, and speech gets a full stop")
  func tidiesMarks() {
    #expect(light("hello , world").text == "hello, world.")
    #expect(light("two  spaces   here.").text == "two spaces here.")
    #expect(light("already fine.").text == "already fine.")
  }

  @Test("Long transcripts get paragraphs, short ones do not")
  func paragraphBreaks() {
    let short = "this is one sentence. and another one. that is all."
    #expect(!light(short).text.contains("\n\n"))

    let sentences = (1...14).map { "sentence number \($0) is here and it has some words in it" }
    let long = sentences.joined(separator: ". ") + "."
    let cleaned = light(long)
    #expect(cleaned.text.contains("\n\n"), "a 140-word wall should be broken up")
    let paragraphWordCounts = cleaned.text.components(separatedBy: "\n\n").map { $0.split(separator: " ").count }
    #expect(paragraphWordCounts.allSatisfy { $0 >= 20 }, "no tiny orphan paragraphs: \(paragraphWordCounts)")
  }

  @Test("A spoken restatement collapses to one copy, at full level")
  func collapsesRestatement() {
    let raw = "put it on the desk, no wait, put it on the desk."
    let cleaned = TranscriptCleanup.clean(raw, level: .full)
    #expect(cleaned.text == "put it on the desk.")
    #expect(cleaned.summary.repairs == 1)
    // A real correction changes a word; choosing between them is rewriting, so it is left alone.
    let correction = "staging cluster, no wait, production cluster."
    #expect(TranscriptCleanup.clean(correction, level: .full).text == correction)
  }

  @Test("A marker that is not a self-correction is left alone")
  func leavesNonRepairs() {
    let raw = "i meant the three crossfit things, and that that is what i meant."
    let cleaned = TranscriptCleanup.clean(raw, level: .full)
    #expect(!cleaned.text.contains("no wait"))
    #expect(cleaned.text.contains("i meant the three crossfit things"))
  }

  @Test("The summary counts what it did")
  func summaryCounts() {
    let cleaned = light("so, like, i i went to the the shop, you know.")
    #expect(cleaned.summary.fillers == 2)
    #expect(cleaned.summary.repeats == 2)
    #expect(cleaned.summary.sentence.contains("filler"))
  }

  @Test("Cleaning is idempotent")
  func idempotent() {
    let raw = "so, like, we could, you know, try the the thing. i i think so."
    let once = light(raw).text
    #expect(light(once).text == once)
  }

  @Test("Nothing is ever added")
  func deletesOnly() {
    let samples = [
      "so, like, we could, you know, try it.",
      "the the thing is is that i i do not know, actually.",
      "pour the the water , and then  wait.",
    ]
    for raw in samples {
      let cleaned = light(raw).text
      let rawWords = raw.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      let cleanedWords = cleaned.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      // Every output word must have appeared, in order, in the input.
      var cursor = rawWords.startIndex
      for word in cleanedWords {
        guard let found = rawWords[cursor...].firstIndex(of: word) else {
          Issue.record("word \"\(word)\" was added to: \(cleaned)")
          break
        }
        cursor = rawWords.index(after: found)
      }
    }
  }
}

@Suite("Cleanup rules table")
struct CleanupRuleTests {
  @Test("Every group runs, and its rules are real patterns that act on their own sample")
  func groupsAreHonest() {
    for group in TranscriptCleanup.groups {
      let atLevel = TranscriptCleanup.clean(group.sample, level: group.minimumLevel)
      #expect(atLevel.text != group.sample, "\(group.id) does not act on its own sample")
      if group.minimumLevel == .full {
        #expect(TranscriptCleanup.clean(group.sample, level: .light).text == group.sample,
                "\(group.id) claims to be full-only but fires at light")
      }
      for rule in group.rules {
        #expect((try? NSRegularExpression(pattern: rule.pattern)) != nil, "\(rule.id) is not a valid pattern")
        #expect(TranscriptCleanup.clean(rule.sample, level: group.minimumLevel).text != rule.sample,
                "\(rule.id) does not act on its own sample")
      }
    }
  }

  @Test("A real correction is left as said; a repeated repair is collapsed")
  func repairsAreConservative() {
    let correction = "staging cluster, no wait, production cluster."
    #expect(TranscriptCleanup.clean(correction, level: .full).text == correction)
    #expect(TranscriptCleanup.clean("put it on the desk, no wait, put it on the desk.", level: .full).text
            == "put it on the desk.")
    // Levelt's classic: one repeated word either side of the marker is enough.
    #expect(TranscriptCleanup.clean("the other driver was, i mean, was going through.", level: .full).text
            == "the other driver was going through.")
  }

  @Test("Emphasis is never collapsed")
  func emphasisSurvives() {
    for text in ["no no no, stop.", "it was very, very cold.", "the idea that that was wrong."] {
      #expect(TranscriptCleanup.clean(text, level: .full).text == text)
    }
  }
}
