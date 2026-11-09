import Foundation

/// A key range for one layer of a patch.
///
/// The original models expose a `layerRange` plus a `RangeApi` whose field names
/// were not recovered. Inversions are handled explicitly here because a range is
/// frequently authored high to low in the UI, and silently producing an empty
/// layer would be the wrong failure mode.
public struct NoteRange: Equatable, Sendable {
    public var lower: UInt8
    public var upper: UInt8

    public init(lower: UInt8, upper: UInt8) {
        self.lower = lower
        self.upper = upper
    }

    public init(_ lower: UInt8, _ upper: UInt8) {
        self.init(lower: lower, upper: upper)
    }

    public var isInverted: Bool { lower > upper }

    public var bounds: (low: UInt8, high: UInt8) {
        isInverted ? (upper, lower) : (lower, upper)
    }

    public func contains(_ note: UInt8) -> Bool {
        let range = bounds
        return note >= range.low && note <= range.high
    }

    /// Pull a note into the range, used for octave wrapping and transposition.
    public func clamped(_ note: UInt8) -> UInt8 {
        let range = bounds
        if note < range.low { return range.low }
        if note > range.high { return range.high }
        return note
    }
}

extension NoteRange: Codable {
    private enum CodingKeys: String, CodingKey {
        case lower
        case upper
    }
}
