import Foundation

/// One layer of a patch: a key range, a transpose, a gain and a timbre.
///
/// The range is the same `NoteRange` the split semantics already use, so a layer
/// is excluded from a note by construction rather than by a second, parallel
/// check somewhere else.
public struct KeyLayer: Identifiable, Equatable, Sendable {
    public enum Timbre: String, Equatable, Sendable {
        case keys
        case bell
    }

    public var id: UInt8
    public var name: String
    public var range: NoteRange
    public var transpose: Int8
    public var gain: Float
    public var timbre: Timbre

    public init(
        id: UInt8,
        name: String,
        range: NoteRange,
        transpose: Int8 = 0,
        gain: Float = 1,
        timbre: Timbre = .keys
    ) {
        self.id = id
        self.name = name
        self.range = range
        self.transpose = transpose
        self.gain = gain
        self.timbre = timbre
    }

    /// The patch the instrument starts with: a full-range keys layer and a bell
    /// layer limited to the upper third, which exercises both layering (notes in
    /// the overlap sound twice) and exclusion (notes below the bell range sound
    /// once).
    public static let defaultPatch: [KeyLayer] = [
        KeyLayer(id: 0, name: "Keys", range: NoteRange(36, 96), gain: 0.85, timbre: .keys),
        KeyLayer(id: 1, name: "Bell", range: NoteRange(72, 96), gain: 0.45, timbre: .bell),
    ]
}
