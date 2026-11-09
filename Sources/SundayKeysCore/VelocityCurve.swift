import Foundation

/// Maps a MIDI velocity to a linear gain.
///
/// The original application carries a `KeyboardVelocityScaling` type whose curve
/// could not be read statically, so this is an independent curve with the same
/// purpose, not a reproduction of theirs: a floor so soft playing is audible, and
/// an exponent above one so the response is weighted towards harder playing.
/// Replace the constants when a captured reference makes the real curve known.
public struct VelocityCurve: Equatable, Sendable {
    public var floor: Float
    public var exponent: Float

    public init(floor: Float = 0.15, exponent: Float = 1.6) {
        self.floor = floor
        self.exponent = exponent
    }

    public func gain(forVelocity velocity: UInt8) -> Float {
        guard velocity > 0 else { return 0 }
        let normalized = Float(min(velocity, 127)) / 127
        let curved = powf(normalized, exponent)
        return floor + (1 - floor) * curved
    }
}
