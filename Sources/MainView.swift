import SwiftUI

struct MainView: View {
  @ObservedObject var recorder: Recorder
  @ObservedObject var library: Library
  @ObservedObject var detector: MeetingDetector
  @State private var selection: Meeting.ID?
  @State private var currentName = ""

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        if recorder.recording {
          Section("Recording") {
            HStack(spacing: 7) {
              RecordingDot()
              VStack(alignment: .leading, spacing: 2) {
                Text(currentName.isEmpty ? "meeting" : currentName)
                  .lineLimit(1).fontWeight(.medium)
                Text(recorder.elapsed)
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 2)
          }
        }
        Section("Meetings") {
          ForEach(library.meetings) { meeting in
            VStack(alignment: .leading, spacing: 2) {
              Text(meeting.title).lineLimit(1)
              Text(meeting.readableDate).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .tag(meeting.id)
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 240)
      .overlay(alignment: .center) {
        if library.meetings.isEmpty && !recorder.recording {
          Text("No meetings yet").font(.callout).foregroundStyle(.tertiary).padding()
        }
      }
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 8) {
          if let app = detector.inMeeting, !recorder.recording {
            MeetingPrompt(app: app) {
              currentName = app
              Task { await recorder.start(name: currentName) }
            } onDismiss: { detector.dismiss() }
          }
          Button {
            if recorder.recording { stop() } else {
              if currentName.isEmpty { currentName = "meeting" }
              Task { await recorder.start(name: currentName) }
            }
          } label: {
            Label(recorder.recording ? "Stop" : "Record",
                  systemImage: recorder.recording ? "stop.fill" : "record.circle")
              .frame(maxWidth: .infinity)
          }
          .controlSize(.large)
          .buttonStyle(.borderedProminent)
          .tint(recorder.recording ? .red : .accentColor)

          if !recorder.recording {
            LanguagePicker(recorder: recorder)
              .foregroundStyle(.secondary)
          }
        }
        .padding(10)
      }
    } detail: {
      if recorder.recording {
        VStack(spacing: 0) {
          RecordingBar(recorder: recorder, name: $currentName, onStop: stop)
          if let p = recorder.problem { Warning(text: p) }
          else if recorder.missingMeetingChannel {
            Warning(text: "No meeting channel: everything heard will be attributed to you.")
          } else if recorder.meetingChannelSilent {
            Warning(text: "No audio is coming from the call. Check that Acta has screen and system audio recording permission.")
          }
          Divider()
          ColumnHeaders()
          Divider()
          LiveTranscript(recorder: recorder)
        }
      } else if let id = selection, let meeting = library.meetings.first(where: { $0.id == id }) {
        MeetingView(meeting: meeting, library: library)
      } else {
        VStack(spacing: 10) {
          Image(systemName: "text.bubble").font(.system(size: 40)).foregroundStyle(.tertiary)
          Text("Pick a meeting, or start recording").foregroundStyle(.secondary)
        }
      }
    }
    .onChange(of: recorder.recording) { _, now in
      if !now { library.reload() }
    }
  }

  private func stop() {
    recorder.rename(to: currentName)
    library.reload()
    recorder.stop()
    library.reload()
    selection = library.meetings.first?.id
    currentName = ""
  }
}

struct MeetingPrompt: View {
  let app: String
  let onRecord: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "dot.radiowaves.left.and.right")
        Text("Meeting on \(app)").font(.callout.weight(.medium))
        Spacer()
        Button { onDismiss() } label: { Image(systemName: "xmark") }
          .buttonStyle(.borderless).foregroundStyle(.secondary)
      }
      Button("Record", action: onRecord)
        .buttonStyle(.borderedProminent).controlSize(.small)
    }
    .padding(10)
    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
  }
}
