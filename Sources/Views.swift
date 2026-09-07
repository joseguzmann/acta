import SwiftUI

// MARK: - Indicators

struct RecordingDot: View {
  @State private var lit = false
  var body: some View {
    Circle()
      .fill(Color.red)
      .frame(width: 9, height: 9)
      .opacity(lit ? 1 : 0.25)
      .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: lit)
      .onAppear { lit = true }
      .accessibilityLabel("Recording")
  }
}

/// The three dots that say something is being heard right now.
struct TypingDots: View {
  @State private var phase = 0
  private let clock = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<3, id: \.self) { i in
        Circle().frame(width: 4, height: 4).opacity(phase == i ? 0.85 : 0.25)
      }
    }
    .foregroundStyle(.secondary)
    .onReceive(clock) { _ in phase = (phase + 1) % 3 }
    .accessibilityHidden(true)
  }
}

/// Four bars that rise with the signal. A channel that is open but silent shows
/// up immediately, instead of being discovered once the transcript is already
/// wrong.
struct LevelMeter: View {
  let level: Float
  var body: some View {
    HStack(alignment: .bottom, spacing: 1.5) {
      ForEach(0..<4, id: \.self) { i in
        let threshold = Float(i + 1) / 5
        RoundedRectangle(cornerRadius: 1)
          .fill(level > threshold ? Color.green : Color.secondary.opacity(0.25))
          .frame(width: 2.5, height: 4 + CGFloat(i) * 2.5)
      }
    }
    .frame(height: 12)
    .animation(.easeOut(duration: 0.15), value: level)
  }
}

/// Picking the meeting language, next to the title where it is actually needed.
/// Buried in Settings it was one screen too far, and getting it wrong wastes the
/// whole recording.
struct LanguagePicker: View {
  @ObservedObject var recorder: Recorder
  @State private var installed: [String] = []
  @State private var installing: String?
  var disabled = false
  /// Full-width form under the record button; compact inline in the toolbar.
  var wide = false

  static let languages: [(String, String)] = [
    ("es-MX", "Español (MX)"),
    ("es-ES", "Español (ES)"),
    ("es-CL", "Español (CL)"),
    ("es-US", "Español (US)"),
    ("en-US", "English (US)"),
    ("en-GB", "English (UK)"),
    ("pt-BR", "Português (BR)"),
    ("fr-FR", "Français"),
    ("de-DE", "Deutsch"),
    ("it-IT", "Italiano"),
  ]

  private var label: String {
    LanguagePicker.languages.first { $0.0 == recorder.locale }?.1 ?? recorder.locale
  }

  var body: some View {
    Menu {
      ForEach(LanguagePicker.languages, id: \.0) { code, name in
        Button {
          recorder.locale = code
          if !installed.contains(code) { download(code) }
        } label: {
          if code == recorder.locale { Label(name, systemImage: "checkmark") }
          else if installed.contains(code) { Text(name) }
          else { Text("\(name) — download") }
        }
      }
    } label: {
      if wide {
        HStack(spacing: 6) {
          Image(systemName: "globe")
          Text(installing == recorder.locale ? "downloading…" : label)
          Spacer(minLength: 0)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .contentShape(Rectangle())
      } else {
        HStack(spacing: 4) {
          Image(systemName: "globe").font(.caption)
          Text(installing == recorder.locale ? "downloading…" : label).font(.caption)
        }
      }
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .modifier(WideMenuChrome(active: wide))
    .fixedSize(horizontal: !wide, vertical: true)
    .frame(maxWidth: wide ? .infinity : nil)
    .disabled(disabled || installing != nil)
    .help(disabled ? "The language cannot change mid-recording" : "Meeting language")
    .task { installed = await Recorder.installedLocales() }
  }

  private func download(_ code: String) {
    installing = code
    Task {
      try? await Recorder.installModel(code)
      installed = await Recorder.installedLocales()
      installing = nil
    }
  }
}

/// The picker sits right under the record button, so it reads as one control
/// pair instead of a menu floating loose on the sidebar.
private struct WideMenuChrome: ViewModifier {
  let active: Bool
  func body(content: Content) -> some View {
    if active {
      content
        .background(Color.secondary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    } else {
      content
    }
  }
}

// MARK: - Bubble

/// One turn. `them` falls left, `you` falls right: the column says who is
/// speaking before you read a word.
struct Bubble: View {
  let speaker: Line.Speaker
  let time: String?
  let text: String
  var draft = false

  private var isYou: Bool { speaker == .you }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      if isYou { Color.clear.frame(maxWidth: .infinity) }

      VStack(alignment: isYou ? .trailing : .leading, spacing: 4) {
        HStack(spacing: 6) {
          if isYou, let t = time { stamp(t) }
          Text(isYou ? "you" : "them")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isYou ? Color.accentColor : Color.secondary)
          if !isYou, let t = time { stamp(t) }
          if draft { TypingDots() }
        }
        Text(text)
          .textSelection(.enabled)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(draft ? .secondary : .primary)
          .padding(.horizontal, 13).padding(.vertical, 10)
          .lineSpacing(2)
          .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(draft ? Color.secondary.opacity(0.25) : .clear,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          )
      }
      .frame(maxWidth: .infinity, alignment: isYou ? .trailing : .leading)
      .padding(isYou ? .leading : .trailing, 28)

      if !isYou { Color.clear.frame(maxWidth: .infinity) }
    }
    .transition(.opacity)
  }

  private func stamp(_ t: String) -> some View {
    Text(t).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
  }

  private var background: Color {
    if draft { return Color.secondary.opacity(0.06) }
    return isYou ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12)
  }
}

/// Fixed labels so the sides do not depend on colour alone.
struct ColumnHeaders: View {
  var body: some View {
    HStack(spacing: 0) {
      Text("the call").frame(maxWidth: .infinity, alignment: .leading)
      Text("you").frame(maxWidth: .infinity, alignment: .trailing)
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(.tertiary)
    .textCase(.uppercase)
    .padding(.horizontal, 20).padding(.vertical, 7)
    .background(.bar)
  }
}

// MARK: - Live transcript

struct LiveTranscript: View {
  @ObservedObject var recorder: Recorder

  private var isEmpty: Bool {
    recorder.lines.isEmpty && recorder.draftYou.isEmpty && recorder.draftThem.isEmpty
  }

  var body: some View {
    ScrollViewReader { scroll in
      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach(recorder.lines) { line in
            Bubble(speaker: line.speaker, time: line.shortTime, text: line.text).id(line.id)
          }
          if !recorder.draftThem.isEmpty {
            Bubble(speaker: .them, time: nil, text: recorder.draftThem, draft: true).id("draft-them")
          }
          if !recorder.draftYou.isEmpty {
            Bubble(speaker: .you, time: nil, text: recorder.draftYou, draft: true).id("draft-you")
          }
          Color.clear.frame(height: 1).id("bottom")
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .animation(.easeOut(duration: 0.18), value: recorder.lines.count)
      }
      .background(alignment: .center) {
        if !isEmpty {
          Rectangle().fill(Color.secondary.opacity(0.12)).frame(width: 1)
        }
      }
      .onChange(of: recorder.lines.count) { scrollToBottom(scroll) }
      .onChange(of: recorder.draftThem) { scrollToBottom(scroll) }
      .onChange(of: recorder.draftYou) { scrollToBottom(scroll) }
      .overlay(alignment: .center) {
        if isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Listening…").foregroundStyle(.secondary)
            Text("The call shows on the left, you on the right.")
              .font(.caption).foregroundStyle(.tertiary)
          }
          .padding(40)
        }
      }
    }
  }

  private func scrollToBottom(_ scroll: ScrollViewProxy) {
    withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo("bottom", anchor: .bottom) }
  }
}

// MARK: - Recording header

struct RecordingBar: View {
  @ObservedObject var recorder: Recorder
  @Binding var name: String
  let onStop: () -> Void
  @State private var tick = Date()
  @State private var renameTask: Task<Void, Never>?
  private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(spacing: 12) {
      RecordingDot()
      TextField("Meeting name", text: $name)
        .textFieldStyle(.plain)
        .font(.title3.weight(.medium))
        .frame(maxWidth: 300)
        .onSubmit { recorder.rename(to: name) }
        .onChange(of: name) { _, newName in
          renameTask?.cancel()
          renameTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            recorder.rename(to: newName)
          }
        }
      Text(recorder.elapsed)
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(.secondary)
        .onReceive(clock) { tick = $0 }
      Spacer()
      ForEach(["them", "you"], id: \.self) { key in
        if recorder.channels[key] != nil {
          HStack(spacing: 5) {
            LevelMeter(level: recorder.level[key] ?? 0)
            Text(key == "them" ? "the call" : "you")
              .font(.caption2).foregroundStyle(.tertiary)
          }
          .help(recorder.channels[key] ?? "")
          if key == "you" && recorder.micGated {
            Image(systemName: "mic.slash.fill")
              .font(.caption2).foregroundStyle(.orange)
              .help("Muted while the call is talking, so the speakers do not come back in as you")
          }
        } else {
          Label("\(key): no channel", systemImage: "exclamationmark.circle")
            .font(.caption2).foregroundStyle(.orange)
        }
      }
      Button(role: .destructive, action: onStop) {
        Label("Stop", systemImage: "stop.fill")
      }
      .keyboardShortcut(".", modifiers: .command)
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(.bar)
  }
}

// MARK: - A stored meeting

struct MeetingView: View {
  let meeting: Meeting
  @ObservedObject var library: Library
  @State private var name = ""
  @State private var editing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        if editing {
          TextField("Name", text: $name, onCommit: save)
            .textFieldStyle(.plain).font(.title2.weight(.semibold))
        } else {
          Text(meeting.title).font(.title2.weight(.semibold))
        }
        Button(editing ? "Save" : "Rename") {
          if editing { save() } else { name = meeting.name; editing = true }
        }
        .buttonStyle(.link)
        Spacer()
        Button { library.revealInFinder(meeting) } label: { Image(systemName: "folder") }
          .buttonStyle(.borderless).help("Show the file")
        Button(role: .destructive) { library.delete(meeting) } label: { Image(systemName: "trash") }
          .buttonStyle(.borderless).help("Move to Trash")
      }
      Text(meeting.readableDate).font(.caption).foregroundStyle(.secondary)
      Divider().padding(.vertical, 10)
      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach(library.lines(meeting)) { line in
            Bubble(speaker: line.speaker, time: line.shortTime, text: line.text)
          }
        }
        .padding(.vertical, 6)
      }
      .background(alignment: .center) {
        Rectangle().fill(Color.secondary.opacity(0.12)).frame(width: 1)
      }
    }
    .padding(16)
    .id(meeting.id)
  }

  private func save() {
    library.rename(meeting, to: name)
    editing = false
  }
}

struct Warning: View {
  let text: String
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text(text).font(.callout)
      Spacer()
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
    .background(Color.orange.opacity(0.12))
  }
}
