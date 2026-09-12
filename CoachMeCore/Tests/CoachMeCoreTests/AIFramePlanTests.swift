import XCTest
@testable import CoachMeCore

final class AIFramePlanTests: XCTestCase {
    func testSevenAnchorsHaveSixExactMidpoints() {
        let marks = SwingPhase.allCases.enumerated().map {
            Keyframe(phase: $0.element, timestampSeconds: 5 + Double($0.offset)*2)
        }
        let plan = AIFramePlan(keyframes: marks, start: 5, end: 18)
        XCTAssertEqual(plan.samples.map(\.timestamp), (5...17).map(Double.init))
        XCTAssertTrue(plan.samples[2].label.contains("上杆下段"))
        XCTAssertTrue(plan.samples[1].label.contains("过渡"))
    }
    func testLegacySixAnchorsGainUnconfirmedTakeawayAndAllMidpoints() {
        let phases = SwingPhase.allCases.filter { $0 != .takeaway }
        let marks = phases.enumerated().map { Keyframe(phase: $0.element, timestampSeconds: Double($0.offset)*4) }
        let samples = AIFramePlan(keyframes: marks, start: 0, end: 21).samples
        XCTAssertEqual(samples.count,13)
        XCTAssertEqual(Array(samples.prefix(5)).map(\.timestamp),[0,1,2,3,4])
        XCTAssertFalse(samples[2].label.contains("已复核"))
        XCTAssertFalse(samples[2].label.contains("上杆下段"))
    }
    func testNoMarksSampleOnlySelectedRangeWithoutInventingPhases() {
        let samples = AIFramePlan(keyframes: [], start: 8, end: 10).samples
        XCTAssertEqual(samples.count,13)
        XCTAssertEqual(samples.first?.timestamp,8)
        XCTAssertTrue(samples.allSatisfy { $0.timestamp >= 8 && $0.timestamp < 10 && $0.label.contains("阶段未知") })
        XCTAssertTrue(AIFramePlan(keyframes: [], start: 8, end: 8).samples.isEmpty)
    }
}
