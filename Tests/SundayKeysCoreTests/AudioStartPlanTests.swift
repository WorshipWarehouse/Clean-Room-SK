import XCTest
@testable import SundayKeysCore

final class AudioStartPlanTests: XCTestCase {
    func testNoReportedFormatMeansNoOutputDevice() {
        XCTAssertThrowsError(try AudioStartPlanner.plan(forReportedSampleRate: nil)) { error in
            XCTAssertEqual(error as? AudioStartFailure, .noOutputDevice)
            XCTAssertEqual((error as? AudioStartFailure)?.description, "No audio output device is available")
        }
    }

    func testAZeroRateFallsBackToTheInstrumentRate() throws {
        // A device that exists but has not named a rate is not a failure: macOS
        // reports zero until the engine is running, and refusing there would make
        // the instrument unusable on hardware that works.
        let plan = try AudioStartPlanner.plan(forReportedSampleRate: 0)
        XCTAssertEqual(plan.sampleRate, AudioStartPlanner.fallbackSampleRate)
        XCTAssertEqual(plan.channelCount, 2)
    }

    func testTheDeviceRateIsKept() throws {
        for rate in [44_100.0, 48_000.0, 88_200.0, 96_000.0, 22_050.0] {
            let plan = try AudioStartPlanner.plan(forReportedSampleRate: rate)
            XCTAssertEqual(plan.sampleRate, rate)
            XCTAssertEqual(plan.channelCount, 2)
        }
    }

    func testAnImpossibleRateIsRejected() {
        for rate in [-48_000.0, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try AudioStartPlanner.plan(forReportedSampleRate: rate)) { error in
                XCTAssertEqual(error as? AudioStartFailure, .unsupportedFormat(reportedSampleRate: rate))
                XCTAssertTrue(
                    (error as? AudioStartFailure)?.description.contains("unusable sample rate") ?? false
                )
            }
        }
    }

    func testTheStereoShapeIsAlwaysRequired() throws {
        let plan = try AudioStartPlanner.plan(forReportedSampleRate: 48_000)
        XCTAssertEqual(plan, AudioStartPlan(sampleRate: 48_000, channelCount: 2))
    }

    func testAnEngineFailureCarriesTheUnderlyingMessage() {
        let failure = AudioStartFailure.engineFailed("the device is busy")
        XCTAssertTrue(failure.description.contains("the device is busy"))
        XCTAssertTrue(failure.description.contains("could not start"))
    }
}
