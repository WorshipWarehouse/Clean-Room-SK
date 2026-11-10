import Foundation

/// The three calls a note path makes on whatever holds the voices.
///
/// `KeysoundNoteTarget` is the two-method view the step clock plays into; the keysound engine
/// already has those two methods and conforms as it stands. This protocol is the wider view the
/// app's controller holds: it adds the release-everything call a stopped graph needs, so a build of
/// the controller can be given a recorder instead of a render thread, and a test can assert what
/// reached the engine rather than what the code intended.
///
/// It exists for that reason only. The engine's interface does not move: `RealtimeKeysoundEngine`
/// already had all three methods, so the conformance below is a name over the path that exists.
public protocol KeysoundVoicing: AnyObject {
    func noteOn(note: UInt8, velocity: UInt8)
    func noteOff(note: UInt8)
    func allNotesOff()
}

extension RealtimeKeysoundEngine: KeysoundVoicing {}
