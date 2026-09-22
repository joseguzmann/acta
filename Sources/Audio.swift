import CoreAudio
import Foundation

/// CoreAudio helpers: enumerating devices and reading the current output.
enum Audio {
  struct Device: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
    let transport: UInt32

    /// The Mac's own microphone. Not a guess from the name: macOS says so.
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    /// Sound leaves this device into the room, so a microphone can hear it
    /// back. Headphones — wired, USB or Bluetooth — cannot feed the microphone,
    /// which changes whether any echo handling is needed at all.
    var isLoudspeaker: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    /// An iPhone offered over Continuity, a loopback driver, an aggregate. All
    /// of them are real input devices and none of them is what someone means by
    /// "my microphone" when they start recording a meeting.
    var isBorrowed: Bool {
      transport == kAudioDeviceTransportTypeContinuityCaptureWired
        || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
        || transport == kAudioDeviceTransportTypeVirtual
        || transport == kAudioDeviceTransportTypeAggregate
    }
  }

  static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          _ value: inout T) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var sz = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &value) == noErr
  }

  static func name(_ id: AudioDeviceID) -> String {
    var s = "" as CFString
    return property(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &s) ? s as String : "?"
  }

  static func uid(_ id: AudioDeviceID) -> String? {
    var s = "" as CFString
    return property(id, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &s) ? s as String : nil
  }

  static func transportType(_ id: AudioDeviceID) -> UInt32 {
    var t: UInt32 = 0
    return property(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &t) ? t : 0
  }

  static func inputChannels(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16)
    defer { ptr.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, ptr) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(ptr.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  static func all() -> [Device] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz)
    var ids = [AudioDeviceID](repeating: 0, count: Int(sz)/MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &ids) == noErr
    else { return [] }
    return ids.compactMap { id in
      guard let u = uid(id) else { return nil }
      return Device(id: id, name: name(id), uid: u,
                    inputChannels: inputChannels(id), transport: transportType(id))
    }
  }

  static func currentOutput() -> Device? {
    var id: AudioDeviceID = 0
    guard property(AudioObjectID(kAudioObjectSystemObject),
                   kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &id)
    else { return nil }
    return all().first { $0.id == id }
  }

  static func inputs() -> [Device] {
    all().filter { $0.inputChannels > 0 }
  }

  static func defaultInput() -> Device? {
    var id: AudioDeviceID = 0
    guard property(AudioObjectID(kAudioObjectSystemObject),
                   kAudioHardwarePropertyDefaultInputDevice,
                   kAudioObjectPropertyScopeGlobal, &id) else { return nil }
    return all().first { $0.id == id }
  }

  /// Which microphone to record.
  ///
  /// Matching on the name was wrong and picked the wrong device the moment an
  /// iPhone was nearby: "iPhone Microphone" contains "microphone" too, and
  /// enumerates first. A phone handed over by Continuity is a real input device
  /// and never the one someone means when they start recording a meeting.
  ///
  /// - an explicit choice always wins
  /// - otherwise the system default, unless it is borrowed or virtual
  /// - otherwise the Mac's own microphone, by transport type rather than by name
  static func microphone(preferred uid: String? = nil) -> Device? {
    let candidates = inputs()
    if let uid, !uid.isEmpty, let chosen = candidates.first(where: { $0.uid == uid }) {
      return chosen
    }
    if let fallback = defaultInput(), fallback.inputChannels > 0, !fallback.isBorrowed {
      return fallback
    }
    return candidates.first { $0.isBuiltIn } ?? candidates.first { !$0.isBorrowed } ?? candidates.first
  }
}
