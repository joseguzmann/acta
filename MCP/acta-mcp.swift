import Foundation

// Acta's MCP server over stdio: exposes meetings to an agent without it having
// to guess paths or parse the disk.
//
// Tools:
//   list_meetings    — the latest N, with name and date
//   read_meeting     — one meeting's text, by id or "current"
//   meeting_running  — whether something is being recorded right now

struct Meeting {
  let id: String, name: String, date: Date, url: URL
}

func meetingsDirectory() -> URL {
  let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  return docs.appendingPathComponent("Acta/meetings", isDirectory: true)
}

func meetings() -> [Meeting] {
  let fm = FileManager.default
  let urls = (try? fm.contentsOfDirectory(at: meetingsDirectory(),
              includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
  let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
  return urls.filter { $0.pathExtension == "md" }.map { url in
    let base = url.deletingPathExtension().lastPathComponent
    let parts = base.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
    var date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate ?? Date()
    var name = base
    if parts.count == 4, let d = f.date(from: parts[0...2].joined(separator: "-")) {
      date = d; name = String(parts[3])
    }
    return Meeting(id: base, name: name, date: date, url: url)
  }.sorted { $0.date > $1.date }
}

/// A meeting counts as running when its file was touched under 90 seconds ago.
func running() -> Meeting? {
  guard let u = meetings().first else { return nil }
  let mod = (try? u.url.resourceValues(forKeys: [.contentModificationDateKey]))?
              .contentModificationDate ?? .distantPast
  return Date().timeIntervalSince(mod) < 90 ? u : nil
}

func iso(_ d: Date) -> String {
  let f = ISO8601DateFormatter(); return f.string(from: d)
}

// --- minimal MCP over stdio ---

func respond(_ id: Any?, _ result: [String: Any]) {
  var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
  if let id { msg["id"] = id }
  guard let d = try? JSONSerialization.data(withJSONObject: msg) else { return }
  FileHandle.standardOutput.write(d)
  FileHandle.standardOutput.write(Data("\n".utf8))
}

func text(_ s: String) -> [String: Any] {
  ["content": [["type": "text", "text": s]]]
}

let tools: [[String: Any]] = [
  ["name": "list_meetings",
   "description": "Lists meetings recorded with Acta, newest first.",
   "inputSchema": ["type": "object",
     "properties": ["limit": ["type": "integer", "description": "how many to return (default 20)"]]]],
  ["name": "read_meeting",
   "description": "Returns a meeting transcript. The id 'current' returns the one being recorded right now, and it can be re-read as often as needed while the meeting is still going.",
   "inputSchema": ["type": "object",
     "properties": ["id": ["type": "string", "description": "the meeting id, or 'current'"]],
     "required": ["id"]]],
  ["name": "meeting_running",
   "description": "Says whether Acta is recording anything right now.",
   "inputSchema": ["type": "object", "properties": [:]]],
]

while let linea = readLine(strippingNewline: true) {
  guard let d = linea.data(using: .utf8),
        let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
        let method = msg["method"] as? String else { continue }
  let id = msg["id"]

  switch method {
  case "initialize":
    respond(id, ["protocolVersion": "2024-11-05",
                   "capabilities": ["tools": [:]],
                   "serverInfo": ["name": "acta", "version": "1.0"]])
  case "tools/list":
    respond(id, ["tools": tools])
  case "tools/call":
    let params = msg["params"] as? [String: Any] ?? [:]
    let toolName = params["name"] as? String ?? ""
    let args = params["arguments"] as? [String: Any] ?? [:]

    switch toolName {
    case "list_meetings":
      let limit = args["limit"] as? Int ?? 20
      let list = meetings().prefix(limit).map { m in
        "\(m.id)  ·  \(m.name)  ·  \(iso(m.date))"
      }.joined(separator: "\n")
      respond(id, text(list.isEmpty ? "No meetings recorded yet." : list))

    case "read_meeting":
      let which = args["id"] as? String ?? ""
      let meeting = which == "current" ? running() : meetings().first { $0.id == which }
      guard let meeting else {
        respond(id, text(which == "current"
          ? "Nothing is being recorded right now."
          : "No meeting called '\(which)'. Try list_meetings."))
        break
      }
      let body = (try? String(contentsOf: meeting.url, encoding: .utf8)) ?? ""
      respond(id, text(body.isEmpty ? "The meeting is still empty." : body))

    case "meeting_running":
      if let m = running() {
        respond(id, text("Yes: \"\(m.name)\", started \(iso(m.date)). id: \(m.id)"))
      } else {
        respond(id, text("Nothing is being recorded right now."))
      }

    default:
      respond(id, text("Unknown tool: \(toolName)"))
    }
  default:
    if id != nil { respond(id, [:]) }
  }
}
