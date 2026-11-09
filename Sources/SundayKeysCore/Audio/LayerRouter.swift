import Foundation

/// One layer's response to a played note.
public struct LayerNote: Equatable, Sendable {
    public var layer: UInt8
    public var note: UInt8
    public var gain: Float

    public init(layer: UInt8, note: UInt8, gain: Float) {
        self.layer = layer
        self.note = note
        self.gain = gain
    }
}

/// Maps a played key to the layers that should sound.
///
/// Runs on the control thread only: it allocates the result array there, which
/// is why the render thread never calls it. A layer is skipped when it is
/// disabled or when the played key is outside its range, so neither case can
/// reach the render thread at all.
public struct LayerRouter: Sendable {
    public let layers: [KeyLayer]

    public init(layers: [KeyLayer] = KeyLayer.defaultPatch) {
        self.layers = layers
    }

    public func route(note: UInt8, velocityGain: Float = 1) -> [LayerNote] {
        var result: [LayerNote] = []
        result.reserveCapacity(layers.count)
        for layer in layers where layer.enabled && layer.range.contains(note) {
            let gain = max(0, min(1, layer.gain * velocityGain))
            result.append(LayerNote(layer: layer.id, note: Self.transpose(note, by: layer.transpose), gain: gain))
        }
        return result
    }

    static func transpose(_ note: UInt8, by semitones: Int8) -> UInt8 {
        let shifted = Int(note) + Int(semitones)
        return UInt8(max(0, min(127, shifted)))
    }
}
