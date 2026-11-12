import Foundation

/// One message from the control thread to the render thread.
///
/// Deliberately trivial: a fixed-size value with no references, so it can sit in
/// a preallocated ring buffer and be moved by plain assignment on the audio
/// thread. Nothing on the render path retains, releases or allocates it.
public struct RenderCommand: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case noteOn = 1
        case noteOff = 2
        case allNotesOff = 3
        /// Retargets a layer's instrument without touching any sounding voice.
        /// `note` carries the instrument's rung in the catalogue's table strip
        /// (0 for the default instrument) because the command is a fixed-size slot
        /// and the field is free for this kind.
        case setLayerTimbre = 4

        /// Transposes every sounding voice by a normalised bend: -1 to 1, one
        /// being the full two semitone range the instrument documents.
        case pitchBend = 5

        /// Trims the finished mix by a normalised pressure: 0 is neutral.
        case channelPressure = 6

        /// Moves a layer between the speakers. `velocity` carries the
        /// position, -1 fully left to 1 fully right, because the command is
        /// a fixed-size slot and the field is free for this kind.
        case setLayerPan = 7

        /// Sets a layer's low-pass corner and resonance without touching a
        /// voice. `velocity` carries the corner in hertz and `amount` the
        /// resonance from 0 to 1, because one float payload is not enough for
        /// both and the command is a fixed-size slot.
        case setLayerFilter = 8

        /// Sets a layer's attack and decay, in seconds. `velocity` carries the attack
        /// and `amount` the decay, because one float is not enough for both and the
        /// command is a fixed-size slot. Split from the sustain and release below so
        /// neither command needs a field the struct does not have.
        case setLayerAttackDecay = 9

        /// Sets a layer's sustain level (0 to 1, in `velocity`) and its release time in
        /// seconds (`amount`).
        case setLayerSustainRelease = 10
    }

    public var kind: Kind
    public var layer: UInt8
    public var note: UInt8
    public var velocity: Float
    public var amount: Float

    public init(kind: Kind, layer: UInt8 = 0, note: UInt8 = 0, velocity: Float = 0, amount: Float = 0) {
        self.kind = kind
        self.layer = layer
        self.note = note
        self.velocity = velocity
        self.amount = amount
    }

    /// Neutral contents used to initialise the ring buffer's slots.
    public static let silent = RenderCommand(kind: .noteOff)
}
