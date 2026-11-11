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
        /// Retargets a layer's timbre without touching any sounding voice.
        /// `note` carries the timbre index here (0 for keys, 1 for bell) because
        /// the command is a fixed-size slot and the field is free for this kind.
        case setLayerTimbre = 4

        /// Transposes every sounding voice by a normalised bend: -1 to 1, one
        /// being the full two semitone range the instrument documents.
        case pitchBend = 5
        /// Trims the finished mix by a normalised pressure: 0 is neutral.
        case channelPressure = 6
    }

    public var kind: Kind
    public var layer: UInt8
    public var note: UInt8
    public var velocity: Float

    public init(kind: Kind, layer: UInt8 = 0, note: UInt8 = 0, velocity: Float = 0) {
        self.kind = kind
        self.layer = layer
        self.note = note
        self.velocity = velocity
    }

    /// Neutral contents used to initialise the ring buffer's slots.
    public static let silent = RenderCommand(kind: .noteOff)
}
