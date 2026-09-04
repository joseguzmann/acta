import SwiftUI
import UserNotifications

@main
struct ActaApp: App {
  @StateObject private var recorder = Recorder()
  @StateObject private var library = Library()
  @StateObject private var detector = MeetingDetector()

  var body: some Scene {
    WindowGroup("Acta") {
      MainView(recorder: recorder, library: library, detector: detector)
        .frame(minWidth: 820, minHeight: 520)
        .task {
          detector.start()
          _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        }
    }
    .defaultSize(width: 980, height: 640)
    .commands {
      CommandGroup(after: .newItem) {
        Button(recorder.recording ? "Stop Recording" : "Record Meeting") {
          Task { recorder.recording ? recorder.stop() : await recorder.start(name: "meeting") }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      }
    }

    MenuBarExtra {
      MenuBarContent(recorder: recorder, detector: detector, library: library)
    } label: {
      Image(systemName: menuBarIcon)
    }

    Settings {
      SettingsView(recorder: recorder)
    }
  }

  private var menuBarIcon: String {
    if recorder.recording { return "record.circle.fill" }
    if detector.inMeeting != nil { return "waveform.badge.exclamationmark" }
    return "waveform"
  }
}

// MARK: - Menu bar

struct MenuBarContent: View {
  @ObservedObject var recorder: Recorder
  @ObservedObject var detector: MeetingDetector
  @ObservedObject var library: Library

  var body: some View {
    if recorder.recording {
      Text("Recording · \(recorder.elapsed)")
      Button("Stop and save") { recorder.stop(); library.reload() }
    } else {
      if let app = detector.inMeeting {
        Text("Looks like you are in a meeting (\(app))")
        Button("Record this meeting") {
          Task { await recorder.start(name: app) }
        }
      } else {
        Text("No meeting detected")
      }
      Button("Record now") { Task { await recorder.start(name: "meeting") } }
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
    Divider()
    Button("Open Acta") {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
    Button("Quit") { NSApp.terminate(nil) }
  }
}

// MARK: - Settings

struct SettingsView: View {
  @ObservedObject var recorder: Recorder
  @State private var installed: [String] = []
  @State private var installing = false
  private let languages = ["en-US", "es-MX", "es-ES", "es-CL", "es-US", "fr-FR", "de-DE", "it-IT", "pt-BR"]

  var body: some View {
    Form {
      Section("Meeting language") {
        Picker("Transcribe in", selection: $recorder.locale) {
          ForEach(languages, id: \.self) { id in
            Text(installed.contains(id) ? "\(id) ✓" : "\(id) — not downloaded").tag(id)
          }
        }
        if !installed.contains(recorder.locale) {
          HStack {
            Text("That model is not on this Mac.").foregroundStyle(.secondary)
            Button(installing ? "Downloading…" : "Download") {
              installing = true
              Task {
                try? await Recorder.installModel(recorder.locale)
                installed = await Recorder.installedLocales()
                installing = false
              }
            }
            .disabled(installing)
          }
          .font(.callout)
        }
        Text("Adding a language in System Settings does not download the speech model. It has to be asked for here.")
          .font(.caption).foregroundStyle(.tertiary)
      }

      Section("System audio") {
        Text("To hear the call, Acta needs the \"System Audio Recording Only\" permission — the second list under Screen & System Audio Recording. macOS asks the first time you record; there is no way to check it beforehand.")
          .foregroundStyle(.secondary).font(.callout)
        Button("Open Privacy settings") {
          NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
      }

      Section("Access from an agent") {
        Text("Acta ships an MCP server: it lets an agent read your meetings — including the one in progress — without knowing paths or parsing files.")
          .foregroundStyle(.secondary).font(.callout)
        Button("Copy MCP configuration") {
          let config = """
          "acta": {
            "type": "stdio",
            "command": "/path/to/acta/MCP/acta-mcp",
            "args": []
          }
          """
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(config, forType: .string)
        }
      }

      Section("Proper nouns") {
        Text("Speech recognition mangles proper nouns. Acta fixes them on the way out, using a file you own.")
          .foregroundStyle(.secondary).font(.callout)
        Button("Open corrections.tsv") { NSWorkspace.shared.open(Paths.corrections) }
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .task { installed = await Recorder.installedLocales() }
  }
}
