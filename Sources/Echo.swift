import Foundation

/// The microphone also picks up whatever the speakers are playing. Since the
/// system channel is clean — it never hears the microphone — it can be
/// subtracted: a stretch of microphone audio that already showed up on the
/// system side is echo.
///
/// Both channels transcribe the *same* audio down different paths, so the text
/// never matches exactly: "Yeah, nothing's wrong" against "Well, nothing's
/// wrong". Comparing exact trigrams was too rigid and let obvious echo through,
/// so two yardsticks are used and either one is enough:
///   - bigrams: catches a repeated word order
///   - bare words: catches the resemblance even when the order breaks
///
/// The thresholds lean conservative on purpose: letting extra echo through is
/// visible and ignorable, losing the user's own words is not.
actor EchoFilter {
  private var window: [(Date, words: Set<String>, bigrams: Set<String>, flat: String)] = []
  private let memory: TimeInterval = 60
  private let bigramThreshold = 0.42
  private let wordThreshold = 0.62

  private func split(_ t: String) -> (Set<String>, Set<String>) {
    let p = t.lowercased()
      .folding(options: .diacriticInsensitive, locale: nil)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count > 2 }
    let words = Set(p)
    guard p.count >= 2 else { return (words, []) }
    let bigrams = Set((0...(p.count - 2)).map { "\(p[$0]) \(p[$0+1])" })
    return (words, bigrams)
  }

  /// Every word kept, in order, stripped to bare letters. Used for the short
  /// phrases the statistical comparison refuses to judge.
  private func flatten(_ t: String) -> String {
    t.lowercased()
      .folding(options: .diacriticInsensitive, locale: nil)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  func record(fromSystem text: String) {
    let (w, b) = split(text)
    window.append((Date(), w, b, flatten(text)))
    let cutoff = Date().addingTimeInterval(-memory)
    window.removeAll { $0.0 < cutoff }
  }

  /// With hardware echo cancellation doing the real work, only the literal
  /// match stays on — the statistical thresholds exist for the case where the
  /// speakers still bleed through, and they are the ones that can swallow a
  /// legitimate sentence.
  var backstopOnly = false

  func setBackstopOnly(_ on: Bool) { backstopOnly = on }

  func isEcho(_ text: String) -> Bool {
    let (words, bigrams) = split(text)

    // Short phrases cannot be judged statistically — "yes" or "exactly" would
    // match anything — but they can be matched literally: if the call said
    // those exact words moments ago, hearing them on the microphone is echo.
    // "A puerta o." carries one long word and used to slip through untouched.
    let flat = flatten(text)
    if flat.count >= 4, window.contains(where: { $0.flat.contains(flat) }) { return true }

    guard !backstopOnly, words.count >= 4 else { return false }
    let seenWords = window.reduce(into: Set<String>()) { $0.formUnion($1.words) }
    let seenBigrams = window.reduce(into: Set<String>()) { $0.formUnion($1.bigrams) }
    let byWords = Double(words.intersection(seenWords).count) / Double(words.count)
    let byBigrams = bigrams.isEmpty ? 0
      : Double(bigrams.intersection(seenBigrams).count) / Double(bigrams.count)
    return byBigrams > bigramThreshold || byWords > wordThreshold
  }

  func clear() { window.removeAll() }
}
