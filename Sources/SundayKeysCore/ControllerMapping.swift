import Foundation

/// What a continuous controller can move while the player is playing.
///
/// The list is deliberately short: the layer gains and the effect parameters the
/// chain actually exposes. Sunday Keys' own controller assignments are recorded in
/// the analysis as Unknown, so nothing here claims to reproduce them. These are
/// this instrument's targets, and any of them can be relearned.
public enum ControllerTarget: Hashable, Codable, Sendable {
    case layerGain(layerID: UInt8)
    case reverbMix
    case reverbDecay
    case delayMix
    case delayFeedback
    case chorusMix
    case chorusDepth
    case eqLow
    case eqHigh

    public var label: String {
        switch self {
        case .layerGain(let layerID): return "layer \(layerID) gain"
        case .reverbMix: return "reverb mix"
        case .reverbDecay: return "reverb decay"
        case .delayMix: return "delay mix"
        case .delayFeedback: return "delay feedback"
        case .chorusMix: return "chorus mix"
        case .chorusDepth: return "chorus depth"
        case .eqLow: return "eq low"
        case .eqHigh: return "eq high"
        }
    }

    /// Every target a patch of this shape offers: one per layer, then the effects.
    /// Taking the layer list rather than assuming two layers means a patch that
    /// added a third gets a mapping row for it without any other change.
    public static func all(for layers: [KeyLayer]) -> [ControllerTarget] {
        var targets = layers.map { ControllerTarget.layerGain(layerID: $0.id) }
        targets.append(contentsOf: [
            .reverbMix, .reverbDecay,
            .delayMix, .delayFeedback,
            .chorusMix, .chorusDepth,
            .eqLow, .eqHigh,
        ])
        return targets
    }
}

/// One controller assignment.
public struct ControllerBinding: Codable, Equatable, Sendable {
    public var controller: UInt8
    /// nil means any channel, which is what most controllers send on the part they
    /// are configured for. A specific channel is available for a split setup.
    public var channel: UInt8?
    public var target: ControllerTarget

    public init(controller: UInt8, channel: UInt8? = nil, target: ControllerTarget) {
        self.controller = controller
        self.channel = channel
        self.target = target
    }
}

/// The controller layout of one patch.
///
/// It lives in the patch rather than in the app because two patches can want the
/// same knob to do different things, and because a set list that is restored has to
/// restore what the knobs do as well as what the keys sound like.
public struct ControllerMapping: Codable, Equatable, Sendable {
    public var bindings: [ControllerBinding]

    public init(bindings: [ControllerBinding] = []) {
        self.bindings = bindings
    }

    /// The layout a new patch starts with: mod wheel to reverb mix, expression to
    /// delay mix, CC 74 to chorus mix and CC 7 to the first layer's gain. These are
    /// chosen for this instrument, not recovered from the original app.
    public static let standard = ControllerMapping(bindings: [
        ControllerBinding(controller: 7, target: .layerGain(layerID: 0)),
        ControllerBinding(controller: 1, target: .reverbMix),
        ControllerBinding(controller: 11, target: .delayMix),
        ControllerBinding(controller: 74, target: .chorusMix),
    ])

    /// A binding for the exact channel wins over a wildcard one, so a controller
    /// split across channels can be assigned per channel while the any-channel
    /// default keeps answering everywhere else.
    public func target(forController controller: UInt8, channel: UInt8) -> ControllerTarget? {
        if let specific = bindings.last(where: { $0.controller == controller && $0.channel == channel }) {
            return specific.target
        }
        return bindings.last(where: { $0.controller == controller && $0.channel == nil })?.target
    }

    public func binding(for target: ControllerTarget) -> ControllerBinding? {
        bindings.last(where: { $0.target == target })
    }

    /// Binds a controller to a target. A target carries one controller and a
    /// controller carries one target, so learning replaces both directions instead
    /// of stacking a second assignment on top of the first.
    public mutating func bind(controller: UInt8, channel: UInt8? = nil, to target: ControllerTarget) {
        bindings.removeAll { $0.target == target }
        bindings.removeAll { $0.controller == controller && $0.channel == channel }
        bindings.append(ControllerBinding(controller: controller, channel: channel, target: target))
    }

    public mutating func unbind(_ target: ControllerTarget) {
        bindings.removeAll { $0.target == target }
    }

    public mutating func unbind(controller: UInt8, channel: UInt8? = nil) {
        bindings.removeAll { $0.controller == controller && $0.channel == channel }
    }
}

/// Turning a 7-bit controller value into a parameter value.
public enum ControllerValue {
    /// The range a layer gain is clamped to, matching the layer editor.
    public static let layerGainRange: ClosedRange<Float> = 0...1.5

    /// 0 maps to exactly 0 and 127 to exactly 1.
    public static func normalised(_ value: UInt8) -> Float {
        Float(min(value, 127)) / 127
    }

    /// Maps 7-bit onto a range. Both ends are reached exactly, so a control can
    /// dial a parameter fully off and fully on with no dead zone at either end.
    public static func map(_ value: UInt8, to range: ClosedRange<Float>) -> Float {
        range.lowerBound + normalised(value) * (range.upperBound - range.lowerBound)
    }
}

// Applying a controller to a patch lives here rather than in the app model so the
// mapping and the parameters it moves stay in one file: the app only has to say
// which message arrived.
extension Patch {
    /// Applies a bound controller value to this patch. Returns the target it moved,
    /// or nil when the controller is not bound, so the caller can report what
    /// happened instead of guessing.
    @discardableResult
    public mutating func apply(
        controllerValue value: UInt8,
        fromController controller: UInt8,
        channel: UInt8
    ) -> ControllerTarget? {
        guard let target = controllerMapping.target(forController: controller, channel: channel) else {
            return nil
        }
        return apply(value: value, to: target) ? target : nil
    }

    /// Moves one target. Returns false when the target names a layer this patch no
    /// longer has: a mapping can outlive an edit that removed a layer, and a missing
    /// layer is not a reason to move anything else.
    @discardableResult
    public mutating func apply(value: UInt8, to target: ControllerTarget) -> Bool {
        switch target {
        case .layerGain(let layerID):
            guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return false }
            layers[index].gain = ControllerValue.map(value, to: ControllerValue.layerGainRange)
            return true
        case .reverbMix:
            effects.reverb.mix = ControllerValue.map(value, to: EffectRanges.mix)
        case .reverbDecay:
            effects.reverb.decay = ControllerValue.map(value, to: EffectRanges.reverbDecay)
        case .delayMix:
            effects.delay.mix = ControllerValue.map(value, to: EffectRanges.mix)
        case .delayFeedback:
            effects.delay.feedback = ControllerValue.map(value, to: EffectRanges.delayFeedback)
        case .chorusMix:
            effects.chorus.mix = ControllerValue.map(value, to: EffectRanges.mix)
        case .chorusDepth:
            effects.chorus.depth = ControllerValue.map(value, to: EffectRanges.chorusDepth)
        case .eqLow:
            effects.eq.lowGain = ControllerValue.map(value, to: EffectRanges.eqGainDB)
        case .eqHigh:
            effects.eq.highGain = ControllerValue.map(value, to: EffectRanges.eqGainDB)
        }
        return true
    }
}
