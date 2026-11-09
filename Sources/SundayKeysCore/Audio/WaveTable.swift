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
}
