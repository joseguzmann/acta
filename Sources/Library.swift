import Foundation
import Combine
import AppKit

/// The history. No database: every meeting is a Markdown file in
/// ~/Documents/Acta/meetings, readable and editable with anything.
@MainActor
final class Library: ObservableObject {
  @Published private(set) var meetings: [Meeting] = []

  init() { reload() }

  func reload() {
    let fm = FileManager.default
    let urls = (try? fm.contentsOfDirectory(at: Paths.meetings,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    meetings = urls
      .filter { $0.pathExtension == "md" }
      .map { url in
        let base = url.deletingPathExtension().lastPathComponent
        let (date, name) = Library.parse(base, url: url)
        return Meeting(id: base, name: name, date: date, url: url)
      }
      .sorted { $0.date > $1.date }
  }

  /// Files are named `YYYY-MM-DD_HHmm-name.md`.
  private static func parse(_ base: String, url: URL) -> (Date, String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
    let parts = base.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
    if parts.count == 4, let d = f.date(from: parts[0...2].joined(separator: "-")) {
      return (d, String(parts[3]))
    }
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    return (modified ?? Date(), base)
  }

  func text(_ m: Meeting) -> String {
    (try? String(contentsOf: m.url, encoding: .utf8)) ?? ""
  }

  /// Re-reads a meeting's lines from disk, which also works for one in progress.
  func lines(_ m: Meeting) -> [Line] {
    text(m).split(separator: "\n").compactMap { raw in
      let s = String(raw)
      guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return nil }
      let rest = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
      let speaker: Line.Speaker = rest.hasPrefix("**them**") ? .them : .you
      guard let colon = rest.firstIndex(of: ":") else { return nil }
      let text = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      return Line(speaker: speaker, text: text)
    }
  }

  func rename(_ m: Meeting, to newName: String) {
    let clean = newName.trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: "/", with: "-")
    guard !clean.isEmpty, clean != m.name else { return }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
    let destination = m.url.deletingLastPathComponent()
      .appendingPathComponent("\(f.string(from: m.date))-\(clean).md")
    try? FileManager.default.moveItem(at: m.url, to: destination)
    reload()
  }

  /// Deleting means the Trash, not destruction.
  func delete(_ m: Meeting) {
    try? FileManager.default.trashItem(at: m.url, resultingItemURL: nil)
    reload()
  }

  func revealInFinder(_ m: Meeting) {
    NSWorkspace.shared.activateFileViewerSelecting([m.url])
  }
}
