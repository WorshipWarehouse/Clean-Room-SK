import Foundation

/// The clock the window runs on.
///
/// The step clock never reads time itself: whatever advances time asks it to
/// `tick()`, and it reads the instant from a `HostClock`. The app therefore has
/// to hand it one, and this is that clock.
///
/// It reads the system's monotonic uptime rather than the wall clock, so a
/// machine synchronising its time mid-service cannot pull a pattern backwards
/// or skip a step. It owns no timer and no dispatch source: the caller that
/// owns time still decides when `tick()` happens, which is what keeps every
/// scheduling rule in `StepClock` and every test able to pin an instant.
public final class SystemHostClock: HostClock {
    public init() {}

    public var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
