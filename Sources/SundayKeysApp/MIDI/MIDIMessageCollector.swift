import Foundation
import SundayKeysCore

/// Collects what the input port's callback parsed.
///
/// The callback runs on a CoreMIDI thread while the probe waits on the main
/// thread, so the messages are kept behind a lock rather than read across threads.
/// Nothing here decides anything: `MIDIReceiveProbe` turns these into an outcome,
/// and the probe only ever asserts what this list actually holds.
final class MIDIMessageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MIDIMessage] = []

    func record(_ message: MIDIMessage) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }

    var messages: [MIDIMessage] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}
