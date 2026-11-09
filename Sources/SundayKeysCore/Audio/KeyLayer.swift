import Foundation

/// One layer of a patch: a key range, a transpose, a gain, a timbre and whether
/// the player has it switched on.
///
/// The range is the same `NoteRange` the split semantics already use, so a layer
/// is excluded from a note by construction rather than by a second, parallel
/// check somewhere else. A disabled layer is excluded by the router, which is why
/// the enabled flag lives here rather than in the UI.
public struct KeyLayer: Identifiable, Equatable, Sendable {
    public enum Timbre: String, Equatable, Sendable, Codable {
        case keys
        case bell
    }

    public var id: UInt8
    public var name: String
    public var range: NoteRange
    public var transpose: Int8
    public var gain: Float
    public var timbre: Timbre
    public var enabled: Bool

    public init(
        id: UInt8,
        name: String,
        range: NoteRange,
        transpose: Int8 = 0,
        gain: Float = 1,
        timbre: Timbre = .keys,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.range = range
        self.transpose = transpose
        self.gain = gain
        self.timbre = timbre
        self.enabled = enabled
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

// Custom decoding rather than the synthesised conformance: a bank written before
// a field existed must still load, with the field taking its documented default
// instead of failing the whole bank.
extension KeyLayer: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case range
        case transpose
        case gain
        case timbre
        case enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt8.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        range = try container.decode(NoteRange.self, forKey: .range)
        transpose = try container.decodeIfPresent(Int8.self, forKey: .transpose) ?? 0
        gain = try container.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        timbre = try container.decodeIfPresent(Timbre.self, forKey: .timbre) ?? .keys
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(range, forKey: .range)
        try container.encode(transpose, forKey: .transpose)
        try container.encode(gain, forKey: .gain)
        try container.encode(timbre, forKey: .timbre)
        try container.encode(enabled, forKey: .enabled)
    }
}
