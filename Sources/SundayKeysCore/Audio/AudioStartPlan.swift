import Foundation

/// What the audio graph needs before it can be built, decided from what the
/// output hardware reports.
///
/// This lives in the core module, away from AVFoundation, for one reason: the
/// decision is testable here. Asking `AVAudioEngine` for its output format
/// touches the hardware and can raise an Objective-C exception that Swift cannot
/// catch, so the caller checks for a device first and passes the reported sample
/// rate in. A missing device is `nil`, and that is a case this type can pin down
/// in a test.
public struct AudioStartPlan: Equatable {
    public let sampleRate: Double
    public let channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Why the graph could not be started.
///
/// The messages are written to be shown to a player as they are, because
/// `AppModel` puts them straight into its status line, and to be grepped by
/// `tools/audio_smoke.sh`, which has to tell a machine with no output device
/// apart from a real failure.
///
/// Equality is written out rather than synthesised, because one of the values
/// this type carries is a `Double` that may be NaN, and NaN is never equal to
/// itself. Synthesised equality would make a rejected NaN rate impossible to
/// assert or to compare in a test, so two rejections are equal when they report
/// the same rate down to the bits.
public enum AudioStartFailure: Error, CustomStringConvertible {
    /// No default output device is present. Starting anyway would raise inside
    /// `AVAudioEngine` and take the process with it.
    case noOutputDevice
    /// A device is present but reported a rate that cannot describe a format.
    case unsupportedFormat(reportedSampleRate: Double)
    /// The graph was built and `AVAudioEngine.start` refused it.
    case engineFailed(String)

    public var description: String {
        switch self {
        case .noOutputDevice:
            return "No audio output device is available"
        case let .unsupportedFormat(reportedSampleRate):
            return "The output device reported an unusable sample rate (\(reportedSampleRate) Hz)"
        case let .engineFailed(message):
            return "The audio engine could not start: \(message)"
        }
    }
}

extension AudioStartFailure: Equatable {
    public static func == (lhs: AudioStartFailure, rhs: AudioStartFailure) -> Bool {
        switch (lhs, rhs) {
        case (.noOutputDevice, .noOutputDevice):
            return true
        case let (.unsupportedFormat(left), .unsupportedFormat(right)):
            return left.bitPattern == right.bitPattern
        case let (.engineFailed(left), .engineFailed(right)):
            return left == right
        default:
            return false
        }
    }
}

/// Chooses the render format, or refuses.
public enum AudioStartPlanner {
    /// Used when a device exists but will not name a rate before the engine runs.
    /// 48 kHz is what the instrument renders at when the hardware is silent about
    /// its preference, and the instrument was written for it.
    public static let fallbackSampleRate: Double = 48_000

    /// The keysound engine is stereo: one buffer is computed and copied to the
    /// remaining channels, so a mono plan would leave half the graph unused.
    public static let requiredChannelCount = 2

    public static func plan(forReportedSampleRate reported: Double?) throws -> AudioStartPlan {
        guard let reported else { throw AudioStartFailure.noOutputDevice }
        guard reported.isFinite, reported >= 0 else {
            throw AudioStartFailure.unsupportedFormat(reportedSampleRate: reported)
        }

        let rate = reported > 0 ? reported : fallbackSampleRate
        return AudioStartPlan(sampleRate: rate, channelCount: requiredChannelCount)
    }
}
