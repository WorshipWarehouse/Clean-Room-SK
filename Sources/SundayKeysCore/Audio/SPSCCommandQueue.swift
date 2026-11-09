import CSync
import Foundation

/// Lock-free single-producer / single-consumer ring buffer carrying keysound
/// events from the control thread to the audio render thread.
///
/// Threads
/// -------
/// Producer: the MIDI thread and the main thread, serialised by the caller so
/// that only one of them pushes at a time. Consumer: the render thread, alone.
///
/// Memory ordering
/// ---------------
/// The producer writes a slot, then publishes the new write index with a
/// release store. The consumer acquires the write index before reading the slot,
/// so the slot contents are guaranteed visible. Symmetrically the consumer
/// release-stores the read index after it has copied a command out, and the
/// producer acquires the read index before it reuses that slot, so a slot is
/// never overwritten while it is still being read. Each thread loads its own
/// index relaxed because only that thread writes it. The indices are
/// free-running `UInt64` counters, so there is no wraparound ambiguity to
/// disambiguate and the ring position is simply `index & mask`.
///
/// Capacity and latency
/// --------------------
/// The ring is rounded up to a power of two and holds `capacity` commands. At
/// 48 kHz with a 512 frame block the render thread drains every 10.7 ms, so the
/// default 2048 slots cover more than forty blocks of dense traffic before a
/// producer would ever have to wait. Only the producer can wait, and it waits by
/// spinning in its own thread; the render thread never blocks, never allocates
/// and never retries. A full queue therefore delays a keystroke by at most one
/// buffer period and never drops it.
public final class SPSCCommandQueue {
    public let capacity: Int

    private let mask: UInt64
    private let slots: UnsafeMutablePointer<RenderCommand>
    private let writeIndex: UnsafeMutablePointer<UInt64>
    private let readIndex: UnsafeMutablePointer<UInt64>

    public init(capacity requested: Int = 2048) {
        var size = 16
        while size < requested {
            size <<= 1
        }
        capacity = size
        mask = UInt64(size - 1)

        slots = UnsafeMutablePointer<RenderCommand>.allocate(capacity: size)
        slots.initialize(repeating: .silent, count: size)

        writeIndex = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        writeIndex.initialize(to: 0)

        readIndex = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        readIndex.initialize(to: 0)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
        writeIndex.deinitialize(count: 1)
        writeIndex.deallocate()
        readIndex.deinitialize(count: 1)
        readIndex.deallocate()
    }

    /// Commands currently in the queue. Safe to call from either side; the value
    /// is a snapshot and may be stale by the time the caller looks at it.
    public var count: Int {
        let write = csync_load_acquire(writeIndex)
        let read = csync_load_acquire(readIndex)
        return Int(write &- read)
    }

    /// Producer side. Returns false when the ring is full; the caller decides
    /// whether to spin or to give up. Never blocks and never allocates.
    @discardableResult
    public func push(_ command: RenderCommand) -> Bool {
        let write = csync_load_relaxed(writeIndex)
        let read = csync_load_acquire(readIndex)
        if write &- read >= UInt64(capacity) {
            return false
        }
        slots[Int(write & mask)] = command
        csync_store_release(writeIndex, write &+ 1)
        return true
    }

    /// Consumer side, render thread only.
    public func pop() -> RenderCommand? {
        let read = csync_load_relaxed(readIndex)
        let write = csync_load_acquire(writeIndex)
        if read == write {
            return nil
        }
        let command = slots[Int(read & mask)]
        csync_store_release(readIndex, read &+ 1)
        return command
    }
}
