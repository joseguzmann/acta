import CoreAudio
import AudioToolbox
import AVFoundation
import Foundation

/// Captures whatever is playing on the Mac using a CoreAudio *process tap*.
///
/// This is the right way since macOS 14.4: it taps system audio **without
/// changing the output device or the routing**, so it works even when the
/// meeting is already underway and apps are already playing. The earlier
/// approach — rerouting output through a virtual driver — forced you to start
/// recording before any sound began, which is exactly what nobody ever does.
final class SystemTap {

  private var tapID: AUAudioObjectID = 0
  private var aggregateID: AudioObjectID = 0
  private var ioProc: AudioDeviceIOProcID?
  private(set) var format: AVAudioFormat?
  private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

  static let aggregateUID = "dev.joseguzman.acta.tap"

  /// System audio has its own permission — "System Audio Recording Only",
  /// separate from screen recording — and there is no preflight API for it.
  ///
  /// The prompt is triggered by `AudioDeviceStart`, not by creating the tap, so
  /// the only honest way to know is to try. Gating on
  /// `CGPreflightScreenCaptureAccess` was wrong twice over: it asks about the
  /// wrong permission, and it refused before ever reaching the call that would
  /// have raised the right prompt.
  ///
  /// It also needs a stable signing identity: TCC keys its record off the
  /// signature, so an ad-hoc build asks again on every rebuild.

  /// Starts capturing. Returns false when the system does not allow it.
  func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
    self.onBuffer = onBuffer

    let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    desc.name = "Acta"
    desc.isPrivate = true
    desc.muteBehavior = .unmuted
    guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr, tapID != 0 else { return false }

    // A private aggregate device holding nothing but the tap.
    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey as String: "Acta (system audio)",
      kAudioAggregateDeviceUIDKey as String: SystemTap.aggregateUID,
      kAudioAggregateDeviceIsPrivateKey as String: true,
      kAudioAggregateDeviceIsStackedKey as String: false,
      kAudioAggregateDeviceTapAutoStartKey as String: true,
      kAudioAggregateDeviceSubDeviceListKey as String: [],
      kAudioAggregateDeviceTapListKey as String: [
        [kAudioSubTapUIDKey as String: desc.uuid.uuidString,
         kAudioSubTapDriftCompensationKey as String: true],
      ],
    ]
    guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr,
          aggregateID != 0 else { cleanUp(); return false }

    var formatAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &fsz, &asbd) == noErr,
          let fmt = AVAudioFormat(streamDescription: &asbd) else { cleanUp(); return false }
    format = fmt

    let created = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { [weak self] _, input, _, _, _ in
      guard let self, let fmt = self.format else { return }
      let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
      guard let first = abl.first, first.mDataByteSize > 0 else { return }
      let frames = AVAudioFrameCount(first.mDataByteSize / 4 / max(1, first.mNumberChannels))
      guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
      buffer.frameLength = frames
      if let dst = buffer.floatChannelData {
        for (i, b) in abl.enumerated() where i < Int(fmt.channelCount) {
          if let src = b.mData { memcpy(dst[i], src, Int(b.mDataByteSize)) }
        }
      }
      self.onBuffer?(buffer)
    }
    guard created == noErr, AudioDeviceStart(aggregateID, ioProc) == noErr else { cleanUp(); return false }
    return true
  }

  func stop() {
    if let p = ioProc, aggregateID != 0 {
      AudioDeviceStop(aggregateID, p)
      AudioDeviceDestroyIOProcID(aggregateID, p)
    }
    ioProc = nil
    cleanUp()
  }

  private func cleanUp() {
    if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
    if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    format = nil
  }

  deinit { stop() }
}
