import Foundation

/// A line of transcript, already attributed to a source.
struct Line: Identifiable, Hashable, Codable {
  enum Speaker: String, Codable { case you, them }
  let id: UUID
  let speaker: Speaker
  let time: Date
  var text: String

  init(speaker: Speaker, time: Date = Date(), text: String) {
    self.id = UUID(); self.speaker = speaker; self.time = time; self.text = text
  }

  var shortTime: String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    return f.string(from: time)
  }
}

/// A stored meeting: a Markdown file anyone can read.
struct Meeting: Identifiable, Hashable {
  let id: String            // the file name, without extension
  var name: String
  var date: Date
  var url: URL

  var title: String { name.isEmpty ? "Untitled" : name }

  var readableDate: String {
    let f = DateFormatter()
    f.dateFormat = "MMMM d, HH:mm"
    return f.string(from: date)
  }
}

enum Paths {
  /// ~/Documents/Acta — outside the bundle, so meetings survive any reinstall
  /// and stay readable with `cat`.
  static var base: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir = docs.appendingPathComponent("Acta", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
  static var meetings: URL {
    let dir = base.appendingPathComponent("meetings", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
  static var corrections: URL { base.appendingPathComponent("corrections.tsv") }
}
