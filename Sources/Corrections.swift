import Foundation

/// Apple Speech takes no custom vocabulary, so proper nouns get fixed on the way
/// out. The file belongs to the user and is meant to be edited.
struct Corrections {
  private var pairs: [(String, String)] = []

  init(url: URL) {
    if !FileManager.default.fileExists(atPath: url.path) {
      try? Corrections.template.write(to: url, atomically: true, encoding: .utf8)
    }
    guard let txt = try? String(contentsOf: url, encoding: .utf8) else { return }
    pairs = txt.split(separator: "\n").compactMap { line in
      let l = line.trimmingCharacters(in: .whitespaces)
      guard !l.hasPrefix("#"), !l.isEmpty else { return nil }
      let p = l.components(separatedBy: "\t")
      guard p.count == 2, !p[0].isEmpty else { return nil }
      return (p[0], p[1])
    }
  }

  var count: Int { pairs.count }

  func apply(_ t: String) -> String {
    var r = t
    for (wrong, right) in pairs {
      r = r.replacingOccurrences(of: wrong, with: right,
                                 options: [.caseInsensitive, .diacriticInsensitive])
    }
    return r
  }

  static let template = """
  # Acta — proper noun corrections
  #
  # Speech recognition mangles proper nouns and there is no way to feed it a
  # vocabulary up front, so they get fixed on the way out.
  #
  # Format:   whatcomesout <TAB> whatitshouldbe
  # Case and accents are ignored. Read at the start of every recording.
  #
  # Add the variants you see repeat: the engine invents a different one every
  # time, so this file fills up with use.

  """
}
