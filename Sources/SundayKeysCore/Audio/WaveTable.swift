import Foundation

/// One cycle of a waveform, generated deterministically on the control thread
/// and read-only afterwards.
///
/// This package ships no sampled instruments, so the keysounds are synthesised
/// from partials written into a table at startup. The table is original: the
/// partial sets below were chosen for a usable keyboard tone, not copied from
/// the application being studied.
public struct WaveTable: Sendable {
    public let samples: [Float]
    public let size: Int

    init(partials: [(multiple: Double, amplitude: Double)], size: Int) {
        var table = [Float](repeating: 0, count: size)
        for index in 0..<size {
            let phase = (Double(index) / Double(size)) * 2 * Double.pi
            var value = 0.0
            for partial in partials {
                value += partial.amplitude * sin(phase * partial.multiple)
            }
            table[index] = Float(value)
        }
        self.init(normalising: table)
    }

    init(normalising table: [Float]) {
        var peak: Float = 0
        for value in table {
            peak = max(peak, abs(value))
        }
        samples = peak > 0 ? table.map { $0 / peak } : table
        size = table.count
    }

    /// Additive table: a fundamental plus decaying upper partials, even partials
    /// attenuated, which reads as a soft electric piano rather than a pure tone.
    public static func keys() -> WaveTable {
        var partials: [(multiple: Double, amplitude: Double)] = []
        for harmonic in 1...12 {
            let amplitude = 1.0 / pow(Double(harmonic), 1.9)
            let weight = harmonic % 2 == 0 ? 0.55 : 1.0
            partials.append((Double(harmonic), amplitude * weight))
        }
        return WaveTable(partials: partials, size: 2048)
    }

    /// Two-operator FM table with a static modulation index, giving a bell-like
    /// upper layer for splits and layers.
    public static func bell() -> WaveTable {
        let size = 2048
        var table = [Float](repeating: 0, count: size)
        for index in 0..<size {
            let phase = (Double(index) / Double(size)) * 2 * Double.pi
            let modulator = sin(phase * 3.0) * 1.6
            let carrier = sin(phase + modulator)
            let upper = 0.35 * sin(phase * 2.0)
            table[index] = Float(carrier * 0.8 + upper)
        }
        return WaveTable(normalising: table)
    }

    /// Soft pad: the same additive idea as `keys` with a steeper roll-off and the
    /// even partials pushed further down, so it sits under a band without the
    /// struck upper harmonics. Chosen for a sustained layer, not traced from the
    /// application being studied.
    public static func pad() -> WaveTable {
        var partials: [(multiple: Double, amplitude: Double)] = []
        for harmonic in 1...8 {
            let amplitude = 1.0 / pow(Double(harmonic), 2.6)
            let weight = harmonic % 2 == 0 ? 0.35 : 1.0
            partials.append((Double(harmonic), amplitude * weight))
        }
        return WaveTable(partials: partials, size: 2048)
    }

    /// Drawbar organ: odd partials only, each at one over its harmonic number,
    /// which is the hollow square-ish tone an organ registration is built from.
    /// The registration itself is this repository's own.
    public static func organ() -> WaveTable {
        var partials: [(multiple: Double, amplitude: Double)] = []
        for harmonic in 1...9 where harmonic % 2 == 1 {
            partials.append((Double(harmonic), 1.0 / Double(harmonic)))
        }
        return WaveTable(partials: partials, size: 2048)
    }

    /// Tine piano: two-operator FM at a lower modulation index than `bell`, plus a
    /// quiet third-harmonic body, so it is rounder than the bell and brighter
    /// than the additive keys table.
    public static func electricPiano() -> WaveTable {
        let size = 2048
        var table = [Float](repeating: 0, count: size)
        for index in 0..<size {
            let phase = (Double(index) / Double(size)) * 2 * Double.pi
            let modulator = sin(phase * 2.0) * 0.9
            let carrier = sin(phase + modulator)
            let body = 0.18 * sin(phase * 3.0)
            table[index] = Float(carrier * 0.9 + body)
        }
        return WaveTable(normalising: table)
    }
}
