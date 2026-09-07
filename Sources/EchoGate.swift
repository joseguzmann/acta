import Foundation

/// Keeps the speakers out of the microphone track by muting it while the call
/// is audible.
///
/// This is the approach the open source meeting recorders actually ship
/// (`AudioMixer.suppressEcho` in meeting-transcriber): crude, but it runs live,
/// needs no model, and — decisively — does not touch the audio anyone is
/// listening to.
///
/// The alternative considered and rejected was Apple's voice processing
/// (`setVoiceProcessingEnabled`). It cancels the echo properly — measured at
/// 97.6% less microphone energy — but it assumes it is running a call and ducks
/// everything else so the local speaker is heard over it. The ducking level can
/// be lowered, not turned off: the API's own floor is named `min`, not `none`.
/// Quieting the meeting the user is trying to hear is a worse failure than a
/// crude filter, which is presumably why none of the projects that solved this
/// use it.
///
/// The honest cost, the same one those projects carry: while the call is
/// talking, the microphone is muted — so a sentence spoken *over* someone else
/// is lost rather than doubled. Real echo cancellation with an aligned
/// reference signal is what removes that trade-off, and it is a model and an
/// alignment step away.
final class EchoGate: @unchecked Sendable {
  private let lock = NSLock()
  private var lastLoud = Date.distantPast
  private var floorLevel: Float = 0
  private(set) var lastLevel: Float = 0

  /// How long the microphone stays muted after the call goes quiet. Speaker
  /// echo arrives late and rings out, so the gate cannot close on the instant.
  private let hangover: TimeInterval = 0.35

  /// A fixed threshold was the first attempt and it never fired once: the
  /// process tap delivers far quieter samples than a microphone does, so a
  /// number picked to sound reasonable (0.012) sat above everything the channel
  /// ever produced. The level that matters is relative to the channel's own
  /// silence, so the floor is learned instead of assumed.
  private let riseOverFloor: Float = 3.5
  private let absoluteFloor: Float = 0.00015

  func noteCallLevel(_ rms: Float) {
    lock.lock(); defer { lock.unlock() }
    lastLevel = rms

    // The floor drifts down fast and up slowly, so it settles on the quiet
    // moments rather than following the speech it is meant to be measured
    // against.
    if floorLevel == 0 { floorLevel = rms }
    else if rms < floorLevel { floorLevel += (rms - floorLevel) * 0.25 }
    else { floorLevel += (rms - floorLevel) * 0.002 }

    let threshold = max(absoluteFloor, floorLevel * riseOverFloor)
    if rms > threshold { lastLoud = Date() }
  }

  /// For the interface, so a gate that never closes is visible rather than
  /// inferred from the transcript.
  var diagnostics: (level: Float, floor: Float, open: Bool) {
    lock.lock(); defer { lock.unlock() }
    return (lastLevel, floorLevel, Date().timeIntervalSince(lastLoud) >= hangover)
  }

  /// True while the call is audible, or was until a moment ago.
  var callIsTalking: Bool {
    lock.lock(); defer { lock.unlock() }
    return Date().timeIntervalSince(lastLoud) < hangover
  }

  func reset() {
    lock.lock(); lastLoud = .distantPast; floorLevel = 0; lastLevel = 0; lock.unlock()
  }
}
