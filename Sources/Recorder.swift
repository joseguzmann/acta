import Speech
import AVFoundation
import CoreAudio
import Foundation
import Combine

/// The engine: captures the microphone and system audio in parallel,
/// transcribes both on device with Apple Speech, and writes an incremental
/// Markdown file as it goes.
@MainActor
final class Recorder: ObservableObject {

  @Published private(set) var recording = false
  @Published private(set) var lines: [Line] = []
  @Published private(set) var problem: String?
  @Published private(set) var startedAt: Date?
  /// Spanish by default: that is what the meetings are in. Remembered across
  /// launches, because nobody wants to pick it every time.
  @Published var locale: String = UserDefaults.standard.string(forKey: "locale") ?? "es-MX" {
    didSet { UserDefaults.standard.set(locale, forKey: "locale") }
  }

  /// What is being said *right now* on each channel, not yet settled. This is
  /// what makes the text flow instead of landing in ten-second blocks.
  @Published private(set) var draftYou = ""
  @Published private(set) var draftThem = ""

  /// What each channel latched onto. When the meeting channel fails, everything
  /// gets attributed to the user, and that has to be said on screen.
  @Published private(set) var channels: [String: String] = [:]
  /// Whether the system's acoustic echo cancellation took. When it does, the
  /// microphone no longer carries the speakers and the text filter is nearly
  /// redundant.
  @Published private(set) var echoCancelled = false
  @Published private(set) var level: [String: Float] = [:]
  private var lastSound: [String: Date] = [:]

  private var engines: [AVAudioEngine] = []
  private var analyzers: [SpeechAnalyzer] = []
  private var tasks: [Task<Void, Never>] = []
  private var file: FileHandle?
  private var currentURL: URL?
  private var currentName = ""
  private let tap = SystemTap()
  private let echo = EchoFilter()
  private var corrections = Corrections(url: Paths.corrections)

  /// How long the microphone channel waits before a phrase counts as real.
  ///
  /// The wait only exists to let the text filter compare against the call, and
  /// echo sometimes gets transcribed *before* the original. With hardware echo
  /// cancellation doing the real work, the backstop barely needs a margin — and
  /// that wait was the entire reason your own words showed up late.
  private var holdBack: UInt64 { echoCancelled ? 1_000_000_000 : 7_000_000_000 }

  var missingMeetingChannel: Bool { channels["them"] == nil }

  /// Only warns when the meeting channel never received anything at all. Audio
  /// stopping is normal — meetings have silences.
  var meetingChannelSilent: Bool {
    guard recording, channels["them"] != nil, let started = startedAt,
          Date().timeIntervalSince(started) > 20 else { return false }
    return lastSound["them"] == nil
  }

  var elapsed: String {
    guard let started = startedAt else { return "00:00" }
    let s = Int(Date().timeIntervalSince(started))
    return String(format: "%02d:%02d", s / 60, s % 60)
  }

  var currentMeetingURL: URL? { currentURL }

  // MARK: - Setup

  static func installedLocales() async -> [String] {
    await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }.sorted()
  }

  /// Adding a language in System Settings does *not* download the speech model.
  /// It has to be asked for explicitly.
  static func installModel(_ id: String) async throws {
    let t = SpeechTranscriber(locale: Locale(identifier: id), preset: .transcription)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
      try await request.downloadAndInstall()
    }
  }

  // MARK: - Recording

  func start(name: String) async {
    guard !recording else { return }
    problem = nil
    lines = []
    draftYou = ""; draftThem = ""
    channels = [:]; level = [:]; lastSound = [:]
    echoCancelled = false
    await echo.clear()
    corrections = Corrections(url: Paths.corrections)

    let installed = await Recorder.installedLocales()
    guard installed.contains(locale) else {
      problem = "The \(locale) speech model is missing. Install it from Settings."
      return
    }

    let clean = name.trimmingCharacters(in: .whitespaces).isEmpty ? "meeting" : name
    let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd_HHmm"
    let fileName = "\(stamp.string(from: Date()))-\(clean.replacingOccurrences(of: "/", with: "-")).md"
    let url = Paths.meetings.appendingPathComponent(fileName)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    file = FileHandle(forWritingAtPath: url.path)
    currentURL = url
    currentName = clean
    write("# \(clean)\n\n\(Date())\n\n")

    await openMicrophoneChannel()
    await openSystemChannel()

    recording = true
    startedAt = Date()
  }

  private func openMicrophoneChannel() async {
    guard let device = Audio.microphone()?.id else {
      problem = "No microphone found."; return
    }
    let transcriber = SpeechTranscriber(locale: Locale(identifier: locale),
                                        preset: .progressiveTranscription)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
      problem = "No compatible audio format for the microphone."; return
    }
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    tasks.append(consumeResults(.you, transcriber))

    let engine = AVAudioEngine()

    // Cancel the echo in the audio, not in the text.
    //
    // Comparing transcripts to spot the speakers bleeding into the microphone
    // was solving the symptom: it runs late, it cannot judge short phrases, and
    // every near-miss shows up as the same sentence on both sides. Apple's voice
    // processing subtracts the output signal from the input before a single word
    // is recognised, which is what every serious implementation does.
    //
    // It has to be enabled while the engine is stopped, and it is not available
    // on every device, so the text filter stays as a backstop.
    do {
      try engine.inputNode.setVoiceProcessingEnabled(true)
      echoCancelled = true
    } catch {
      echoCancelled = false
    }
    await echo.setBackstopOnly(echoCancelled)

    guard let unit = engine.inputNode.audioUnit else { problem = "Microphone has no audio unit."; return }
    var d = device
    let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &d,
                                      UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else {
      problem = "Could not point at \(Audio.name(device)) (\(status))."; return
    }
    engine.reset()
    let inputFormat = engine.inputNode.inputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0,
          let converter = AVAudioConverter(from: inputFormat, to: target) else {
      problem = "Invalid format on \(Audio.name(device))."; return
    }

    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      self?.meter(.you, buffer)
      guard let converted = Recorder.convert(buffer, to: target, with: converter) else { return }
      continuation.yield(AnalyzerInput(buffer: converted))
    }
    do {
      try await analyzer.start(inputSequence: stream)
      engine.prepare()
      try engine.start()
      engines.append(engine)
      analyzers.append(analyzer)
      channels["you"] = "\(Audio.name(device)) · \(Int(inputFormat.sampleRate/1000))kHz"
    } catch {
      problem = "Microphone channel did not start: \(error.localizedDescription)"
    }
  }

  /// The meeting channel: everything playing on the Mac, tapped without touching
  /// the output. It does not matter whether the audio was already playing when
  /// recording started.
  private func openSystemChannel() async {
    let transcriber = SpeechTranscriber(locale: Locale(identifier: locale),
                                        preset: .progressiveTranscription)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
      problem = "No compatible audio format for system audio."; return
    }
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    tasks.append(consumeResults(.them, transcriber))

    var converter: AVAudioConverter?
    let started = tap.start { [weak self] buffer in
      guard let self else { return }
      self.meter(.them, buffer)
      if converter == nil { converter = AVAudioConverter(from: buffer.format, to: target) }
      guard let converter,
            let converted = Recorder.convert(buffer, to: target, with: converter) else { return }
      continuation.yield(AnalyzerInput(buffer: converted))
    }
    guard started else {
      problem = "Could not capture system audio. Allow Acta under System Settings › "
        + "Privacy & Security › Screen & System Audio Recording — it appears in the "
        + "\"System Audio Recording Only\" list."
      return
    }
    do {
      try await analyzer.start(inputSequence: stream)
      analyzers.append(analyzer)
      channels["them"] = "system audio · \(Int((tap.format?.sampleRate ?? 48000)/1000))kHz"
    } catch {
      problem = "Meeting channel did not start: \(error.localizedDescription)"
    }
  }

  private static func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat,
                              with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
    let ratio = target.sampleRate / buffer.format.sampleRate
    guard let out = AVAudioPCMBuffer(pcmFormat: target,
            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024) else { return nil }
    var error: NSError?
    var delivered = false
    converter.convert(to: out, error: &error) { _, status in
      if delivered { status.pointee = .noDataNow; return nil }
      delivered = true; status.pointee = .haveData; return buffer
    }
    return (error == nil && out.frameLength > 0) ? out : nil
  }

  private nonisolated func meter(_ speaker: Line.Speaker, _ buffer: AVAudioPCMBuffer) {
    guard let channel = buffer.floatChannelData?[0] else { return }
    var sum: Float = 0
    let n = Int(buffer.frameLength)
    for i in 0..<n { sum += channel[i] * channel[i] }
    let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
    Task { @MainActor in self.record(level: rms, for: speaker) }
  }

  private func record(level rms: Float, for speaker: Line.Speaker) {
    let key = speaker.rawValue
    level[key] = min(1, rms * 12)
    if rms > 0.004 { lastSound[key] = Date() }
  }

  /// Consume one channel's results: drafts show up as they come, settled text is
  /// committed — and on the microphone, checked against the echo first.
  private func consumeResults(_ speaker: Line.Speaker, _ transcriber: SpeechTranscriber) -> Task<Void, Never> {
    Task { [weak self] in
      do {
        for try await result in transcriber.results {
          guard let self else { return }
          let text = String(result.text.characters)
          guard result.isFinal else { await self.showDraft(speaker, text); continue }
          await self.showDraft(speaker, "")
          if speaker == .them {
            await self.echo.record(fromSystem: text)
            await self.append(speaker, text)
          } else {
            let pending = text
            Task { [weak self] in
              guard let self else { return }
              try? await Task.sleep(nanoseconds: self.holdBack)
              if await self.echo.isEcho(pending) { return }
              await self.append(speaker, pending)
            }
          }
        }
      } catch {
        await MainActor.run {
          self?.problem = "\(speaker.rawValue) channel: \(error.localizedDescription)"
        }
      }
    }
  }

  private func showDraft(_ speaker: Line.Speaker, _ text: String) async {
    let t = corrections.apply(text)
    if speaker == .them { draftThem = t; return }
    // Speaker echo comes in here too: if it is already playing on the meeting
    // channel, there is no reason to show it on the user's side.
    if !t.isEmpty, await echo.isEcho(t) { draftYou = ""; return }
    draftYou = t
  }

  private func append(_ speaker: Line.Speaker, _ text: String) async {
    let t = corrections.apply(text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    let line = Line(speaker: speaker, text: t)
    lines.append(line)
    write("[\(line.shortTime)] **\(speaker.rawValue)**: \(t)\n\n")
  }

  private func write(_ s: String) { file?.write(Data(s.utf8)) }

  /// Renaming while recording. Moving the file does not invalidate the open
  /// descriptor — it points at the inode — so writing continues uninterrupted.
  func rename(to newName: String) {
    let clean = newName.trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: "/", with: "-")
    guard recording, !clean.isEmpty, let current = currentURL else { return }
    let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd_HHmm"
    let destination = current.deletingLastPathComponent()
      .appendingPathComponent("\(stamp.string(from: startedAt ?? Date()))-\(clean).md")
    guard destination != current else { return }
    do {
      try FileManager.default.moveItem(at: current, to: destination)
      currentURL = destination
      currentName = clean
    } catch { }
  }

  /// The heading was written with the original name; if it changed, it gets
  /// fixed on close, when the name is final.
  private func fixHeading() {
    guard let url = currentURL,
          let text = try? String(contentsOf: url, encoding: .utf8) else { return }
    var lines = text.components(separatedBy: "\n")
    guard let i = lines.firstIndex(where: { $0.hasPrefix("# ") }) else { return }
    lines[i] = "# \(currentName)"
    try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  func stop() {
    guard recording else { return }
    tap.stop()
    for e in engines { e.inputNode.removeTap(onBus: 0); e.stop() }
    engines.removeAll(); analyzers.removeAll()
    for t in tasks { t.cancel() }
    tasks.removeAll()
    try? file?.close()
    file = nil
    fixHeading()
    recording = false
    startedAt = nil
    draftYou = ""; draftThem = ""
  }
}
