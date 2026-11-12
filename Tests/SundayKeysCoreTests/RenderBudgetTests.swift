import Foundation
import XCTest
@testable import SundayKeysCore

/// What one render block costs on the path a live patch actually uses.
///
/// The block is 512 frames at 48 kHz: the size `AudioEngineController` documents
/// ("512 frames is 10.7 ms at 48 kHz") and the size the stereo tests drive. One
/// block therefore has 512 / 48,000 s = 10.67 ms of wall clock to finish inside,
/// and that derivation - not a hand-picked number - is the budget the assertions
/// below compare against.
///
/// Ten voices sound through the whole chain (EQ, chorus, delay and reverb all
/// engaged), then the same ten voices run through the same engine with the chain
/// bypassed, so the test states what the chain costs over the dry path and not
/// only an absolute figure.
///
/// This is DSP cost in isolation. There is no audio device in this environment, so
/// a pass here means the chain fits inside one block's worth of time on this
/// machine; it is not evidence of glitch-free playback, and it says nothing about
/// the device's own latency.
/// The gate is the sustained cost, not the single worst block. On a shared
/// runner the host can preempt the thread mid-block, and this measurement
/// shows it: on 2026-11-12 the bypassed dry path ran a 636 us median with a
/// 2245 us worst block, so that maximum described the scheduler rather than
/// the chain. A real regression moves the median and the tail of the
/// distribution; a preemption moves one block. So the assertions below are
/// the median, the 95th percentile and a four-block ceiling that only a
/// genuine blow-up can cross.
final class RenderBudgetTests: XCTestCase {
    private let sampleRate: Double = 48_000
    private let frameCount = 512

    /// Warm-up is discarded: the first blocks drain the command ring, start the
    /// oscillators and touch every buffer in the chain for the first time.
    private let warmupBlocks = 60
    private let measuredBlocks = 240

    /// The wall clock one block must finish inside to keep up with the device.
    private var blockBudgetNanoseconds: Double {
        Double(frameCount) / sampleRate * 1_000_000_000
    }

    /// Every stage engaged, at the settings a played patch would carry.
    private func engagedChain() -> EffectsSettings {
        var settings = EffectsSettings()
        settings.eq.enabled = true
        settings.eq.lowGain = 4
        settings.eq.midGain = -3
        settings.eq.highGain = 3
        settings.chorus.enabled = true
        settings.chorus.mix = 0.4
        settings.chorus.rate = 0.8
        settings.chorus.depth = 0.8
        settings.delay.enabled = true
        settings.delay.mix = 0.35
        settings.delay.feedback = 0.45
        settings.delay.leftTime = 0.19
        settings.delay.rightTime = 0.28
        settings.reverb.enabled = true
        settings.reverb.mix = 0.5
        settings.reverb.decay = 0.8
        settings.reverb.damping = 0.4
        return settings
    }

    /// Per-block cost in nanoseconds with the warm-up excluded. The clock is read
    /// around `renderStereo` only: clearing the buffers and the note-on traffic
    /// belong to the harness, not to the render path.
    private func blockCosts(engaged: Bool) -> [Double] {
        let patch = Patch(
            name: engaged ? "Engaged" : "Bypassed",
            layers: KeyLayer.defaultPatch,
            effects: engaged ? engagedChain() : EffectsSettings()
        )
        let engine = RealtimeKeysoundEngine(sampleRate: sampleRate, layers: patch.layers)
        engine.setPatch(patch)
        var note = UInt8(48)
        while note <= 57 {
            engine.noteOn(note: note, velocity: 100)
            note += 1
        }

        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        var costs: [Double] = []
        costs.reserveCapacity(measuredBlocks)

        var block = 0
        while block < warmupBlocks + measuredBlocks {
            var index = 0
            while index < frameCount {
                left[index] = 0
                right[index] = 0
                index += 1
            }

            let start = DispatchTime.now().uptimeNanoseconds
            left.withUnsafeMutableBufferPointer { leftPointer in
                right.withUnsafeMutableBufferPointer { rightPointer in
                    engine.renderStereo(
                        intoLeft: leftPointer,
                        intoRight: rightPointer,
                        frameCount: frameCount
                    )
                }
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)

            if block >= warmupBlocks {
                costs.append(elapsed)
            }
            block += 1
        }
        return costs
    }

        private func percentile(_ values: [Double], at fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Int((Double(sorted.count) - 1) * min(max(fraction, 0), 1))
        return sorted[position]
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    func testEveryStageEngagedStaysInsideOneBlock() {
        let engaged = blockCosts(engaged: true)
        let bypassed = blockCosts(engaged: false)

        let budget = blockBudgetNanoseconds
        let engagedMedian = median(engaged)
        let engagedWorst = engaged.max() ?? 0
        let engagedP95 = percentile(engaged, at: 0.95)
        let engagedTail = engaged.filter { $0 > budget * 0.5 }.count
        let bypassedMedian = median(bypassed)
        let bypassedWorst = bypassed.max() ?? 0
        let bypassedP95 = percentile(bypassed, at: 0.95)
        let share = { (nanoseconds: Double) in nanoseconds / budget * 100 }
        let chainOverhead = bypassedMedian > 0 ? engagedMedian / bypassedMedian : 0

        let summary = String(
            format: "%d frames at %.0f Hz = %.0f us per block; engaged median %.1f us (%.1f%% of the block), worst %.1f us (%.1f%%); bypassed median %.1f us (%.1f%%), worst %.1f us (%.1f%%); chain %.1fx the bypassed path",
            frameCount, sampleRate, budget / 1_000,
            engagedMedian / 1_000, share(engagedMedian),
            engagedWorst / 1_000, share(engagedWorst),
            bypassedMedian / 1_000, share(bypassedMedian),
            bypassedWorst / 1_000, share(bypassedWorst),
            chainOverhead
        )
        print("RENDER_BUDGET \(summary)")

        // The tail is printed as well, so a run that passes still records
        // the distribution the gate was applied to.
        print(
            String(
                format: "RENDER_BUDGET_TAIL engaged p95 %.1f us (%.1f%%), %d blocks over half; "
                    + "bypassed p95 %.1f us (%.1f%%)",
                engagedP95 / 1_000, share(engagedP95), engagedTail,
                bypassedP95 / 1_000, share(bypassedP95)
            )
        )

        XCTAssertGreaterThan(engagedMedian, 0, "the measurement has to be real, not zero: \(summary)")
        XCTAssertGreaterThan(
            engagedMedian,
            bypassedMedian,
            "the engaged chain has to cost more than the dry path, or it is not running: \(summary)"
        )
        XCTAssertLessThan(
            engagedMedian,
            budget * 0.25,
            "the engaged chain must leave three quarters of the block free: \(summary)"
        )
        XCTAssertLessThan(
            engagedP95,
            budget * 0.6,
            "the engaged chain's tail must leave two fifths of the block free: \(summary)"
        )
        XCTAssertLessThanOrEqual(
            engagedTail,
            engaged.count / 20 + 1,
            "at most a twentieth of engaged blocks may take half the block: \(summary)"
        )
        XCTAssertLessThan(
            engagedWorst,
            budget * 4,
            "no engaged block may overrun four blocks' worth of time: \(summary)"
        )
        XCTAssertLessThan(
            bypassedP95,
            budget * 0.6,
            "the dry path's tail must leave two fifths of the block free: \(summary)"
        )
        XCTAssertLessThan(
            bypassedWorst,
            budget * 4,
            "even a preempted dry block stays inside four blocks: \(summary)"
        )
    }
}
