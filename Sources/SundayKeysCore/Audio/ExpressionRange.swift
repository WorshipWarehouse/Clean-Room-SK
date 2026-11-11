import Foundation

/// The wire range of a MIDI expression event, reduced to the -1 to 1 and 0 to 1
/// ranges the keysound engine takes.
///
/// A fourteen bit bend is centred at 8192 and runs to 16383 and to 0, and each
/// half is 8191 or 8192 steps, so this type scales the two halves separately and
/// each end reaches exactly 1 and -1. Pressure is a seven bit value and needs no
/// centre at all.
///
/// The engine's instrument applies its own two semitone bend range, so the
/// conversion between wire and sound lives here, once, where a test can assert
/// the ends without a render thread. The original's bend range and aftertouch
/// response are Unknown; both numbers are this repository's own.
public enum ExpressionRange {
    /// The centre of a fourteen bit bend.
    public static let bendCentre: UInt16 = 8_192

    /// `value` as -1 to 1, clamped to what the wire can carry.
    public static func normalisedBend(_ value: UInt16) -> Float {
        let clamped = min(value, 16_383)
        if clamped == bendCentre {
            return 0
        }
        if clamped > bendCentre {
            return Float(clamped - bendCentre) / 8_191
        }
        return -Float(bendCentre - clamped) / 8_192
    }

    /// `value` as 0 to 1.
    public static func normalisedPressure(_ value: UInt8) -> Float {
        Float(min(value, 127)) / 127
    }
}
