import XCTest
@testable import AutolevelerCore

final class GainPlanTests: XCTestCase {
    private func frame(_ db: Double) -> EnergyFrame {
        EnergyFrame(rms: pow(10, db / 20), peak: pow(10, db / 20))
    }

    private func speech(_ start: Double = 0, _ end: Double = 1, _ confidence: Double = 0.9) -> SpeechWindow {
        SpeechWindow(start: start, end: end, confidence: confidence)
    }

    func testSilenceReceivesNoGain() {
        let plan = GainPlan.make(energy: Array(repeating: frame(-120), count: 20), speech: [])
        XCTAssertFalse(plan.speechDetected)
        XCTAssertTrue(plan.decibels.allSatisfy { abs($0) < 0.001 })
    }

    func testQuietConfidentSpeechIsBoosted() {
        let plan = GainPlan.make(energy: Array(repeating: frame(-40), count: 20), speech: [speech(0, 1)])
        XCTAssertTrue(plan.speechDetected)
        XCTAssertGreaterThan(plan.decibels.max() ?? 0, 10)
    }

    func testGainIsCapped() {
        let plan = GainPlan.make(energy: Array(repeating: frame(-65), count: 20), speech: [speech(0, 1)])
        XCTAssertGreaterThan(plan.decibels.max() ?? 0, 20)
        XCTAssertLessThanOrEqual(plan.decibels.max() ?? .infinity, 24.001)
    }

    func testNoiseWithoutSpeechIsNotBoosted() {
        let plan = GainPlan.make(energy: Array(repeating: frame(-45), count: 20), speech: [])
        XCTAssertFalse(plan.speechDetected)
        XCTAssertTrue(plan.decibels.allSatisfy { abs($0) < 0.001 })
    }

    func testLoudSpeechIsAttenuated() {
        let plan = GainPlan.make(energy: Array(repeating: frame(-8), count: 20), speech: [speech(0, 1)])
        XCTAssertTrue(plan.speechDetected)
        XCTAssertLessThan(plan.decibels.max() ?? 0, 0)
    }

    func testGainReturnsTowardUnityAcrossPause() {
        let energy = Array(repeating: frame(-40), count: 10) + Array(repeating: frame(-120), count: 10)
        let plan = GainPlan.make(energy: energy, speech: [speech(0, 0.5)])
        XCTAssertGreaterThan(plan.decibels[3], plan.decibels[15])
        XCTAssertLessThan(abs(plan.decibels[19]), abs(plan.decibels[3]))
    }

    func testCancellationTokenCheckThrowsAfterCancel() {
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try token.check()) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
}
