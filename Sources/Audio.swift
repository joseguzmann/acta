import CoreAudio
import Foundation

/// CoreAudio helpers: enumerating devices and reading the current output.
enum Audio {
  struct Device {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
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
      return Device(id: id, name: name(id), uid: u, inputChannels: inputChannels(id))
    }
  }

  static func currentOutput() -> Device? {
    var id: AudioDeviceID = 0
    guard property(AudioObjectID(kAudioObjectSystemObject),
                   kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &id)
    else { return nil }
    return all().first { $0.id == id }
  }

  static func microphone() -> Device? {
    let inputs = all().filter { $0.inputChannels > 0 }
    return inputs.first { $0.name.localizedCaseInsensitiveContains("microphone") } ?? inputs.first
  }
}
