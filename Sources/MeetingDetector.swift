import CoreAudio
import Foundation
import Combine
import AppKit

/// Notices when you are about to join — or already joined — a meeting.
///
/// Two signals, because one is not enough:
///
/// 1. **Who grabbed the microphone.** The strong signal: if Zoom holds audio
///    input, you are in a call. No permissions needed and no false positives.
///
/// 2. **What page is open.** Needed for browsers: in a Meet lobby the browser is
///    already playing audio while the microphone still reads as free, so the
///    first signal arrives too late — and the lobby is exactly when the prompt
///    is useful.
@MainActor
final class MeetingDetector: ObservableObject {

  @Published private(set) var inMeeting: String?
  @Published var promptVisible = false

  private var timer: Timer?
  private var alreadyPrompted = false

  /// Matched by prefix: browsers use child processes
  /// (`com.google.Chrome.helper`) and an exact name never matches.
  private static let apps: [(String, String)] = [
    ("us.zoom.xos", "Zoom"),
    ("com.microsoft.teams", "Teams"),
    ("com.hnc.Discord", "Discord"),
    ("com.apple.FaceTime", "FaceTime"),
    ("com.tinyspeck.slackmacgap", "Slack"),
    ("com.cisco.webexmeetingsapp", "Webex"),
  ]

  private static let browsers: [(bundle: String, app: String)] = [
    ("com.google.Chrome", "Google Chrome"),
    ("com.brave.Browser", "Brave Browser"),
    ("company.thebrowser.Browser", "Arc"),
    ("com.microsoft.edgemac", "Microsoft Edge"),
  ]

  private static let domains: [(String, String)] = [
    ("meet.google.com", "Meet"),
    ("zoom.us/j/", "Zoom"),
    ("zoom.us/wc/", "Zoom"),
    ("teams.microsoft.com", "Teams"),
    ("teams.live.com", "Teams"),
    ("whereby.com", "Whereby"),
  ]

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.check() }
    }
    check()
  }

  func stop() { timer?.invalidate(); timer = nil }
  func dismiss() { promptVisible = false }

  private func check() {
    let found = byMicrophone() ?? byOpenTab()
    inMeeting = found
    if found != nil {
      if !alreadyPrompted { alreadyPrompted = true; promptVisible = true }
    } else {
      alreadyPrompted = false
      promptVisible = false
    }
  }

  private func byMicrophone() -> String? {
    for bundle in processesWithAudio(inputOnly: true) {
      if let match = MeetingDetector.apps.first(where: { bundle.hasPrefix($0.0) }) { return match.1 }
      if MeetingDetector.browsers.contains(where: { bundle.hasPrefix($0.bundle) }) {
        return byOpenTab() ?? "your browser"
      }
    }
    return nil
  }

  /// Bundle IDs of processes with active audio. `inputOnly: false` includes the
  /// ones that are only playing, which is the lobby case.
  private func processesWithAudio(inputOnly: Bool) -> [String] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz) == noErr
    else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(sz)/MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &ids) == noErr
    else { return [] }

    return ids.compactMap { object in
      func flag(_ selector: AudioObjectPropertySelector) -> Bool {
        var v: UInt32 = 0
        var a = AudioObjectPropertyAddress(mSelector: selector,
          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &s, &v) == noErr && v != 0
      }
      let active = inputOnly ? flag(kAudioProcessPropertyIsRunningInput)
        : (flag(kAudioProcessPropertyIsRunningInput) || flag(kAudioProcessPropertyIsRunningOutput))
      guard active else { return nil }
      var bundle: CFString = "" as CFString
      var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      var s = UInt32(MemoryLayout<CFString>.size)
      guard AudioObjectGetPropertyData(object, &a, 0, nil, &s, &bundle) == noErr else { return nil }
      let id = bundle as String
      return id.isEmpty ? nil : id
    }
  }

  /// Only asks browsers that are already running, and only when they also have
  /// audio going: a Meet tab forgotten in the background is not a meeting.
  private func byOpenTab() -> String? {
    let withAudio = processesWithAudio(inputOnly: false)
    let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }

    for browser in MeetingDetector.browsers {
      guard running.contains(where: { $0.hasPrefix(browser.bundle) }),
            withAudio.contains(where: { $0.hasPrefix(browser.bundle) }),
            let urls = openTabs(app: browser.app) else { continue }
      for (domain, service) in MeetingDetector.domains where urls.contains(domain) {
        return service
      }
    }
    return nil
  }

  private func openTabs(app: String) -> String? {
    let source = """
    tell application "\(app)"
      set out to ""
      repeat with w in windows
        repeat with t in tabs of w
          set out to out & (URL of t) & "\n"
        end repeat
      end repeat
      return out
    end tell
    """
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    return error == nil ? result?.stringValue : nil
  }
}
