import XCTest
@testable import CoachMeCore

final class AIFramePlanTests: XCTestCase {
    func testSevenAnchorsRemainInThirtyChronologicalSamples() {
        let times = [5.0, 6, 7, 8, 8.15, 8.3, 17]
        let marks = zip(SwingPhase.allCases, times).map {
            Keyframe(phase: $0.0, timestampSeconds: $0.1, markedByCoach: true)
        }
        let samples = AIFramePlan(keyframes: marks, start: 5, end: 18).samples
        XCTAssertEqual(samples.count, 30)
        XCTAssertEqual(samples.map(\.timestamp), samples.map(\.timestamp).sorted())
        XCTAssertEqual(Set(samples.map(\.timestamp)).count, 30)
        for mark in marks {
            XCTAssertTrue(samples.contains { $0.timestamp == mark.timestampSeconds && $0.label.contains(mark.phase.nameZH) })
        }
        XCTAssertEqual(samples.filter { $0.label.contains("已复核") }.count, 7)
        XCTAssertEqual(samples.filter { $0.label.contains("过渡") }.count, 23)
        XCTAssertEqual(samples.filter { $0.timestamp > 8.15 && $0.timestamp < 8.3 }.count, 4)
        XCTAssertEqual(samples.first?.timestamp, 5)
        XCTAssertEqual(samples.last?.timestamp, 17)
    }

    func testLegacySixAnchorsGainUnconfirmedTakeaway() throws {
        let phases = SwingPhase.allCases.filter { $0 != .takeaway }
        let marks = phases.enumerated().map { Keyframe(phase: $0.element, timestampSeconds: Double($0.offset)*4) }
        let samples = AIFramePlan(keyframes: marks, start: 0, end: 21).samples
        XCTAssertEqual(samples.count, 30)
        let inserted = try XCTUnwrap(samples.first { $0.timestamp == 2 })
        XCTAssertFalse(inserted.label.contains("已复核"))
        XCTAssertFalse(inserted.label.contains("上杆下段"))
    }

    func testNoMarksSampleOnlySelectedRangeWithoutInventingPhases() {
        let samples = AIFramePlan(keyframes: [], start: 8, end: 10).samples
        XCTAssertEqual(samples.count, 30)
        XCTAssertEqual(samples.first?.timestamp, 8)
        XCTAssertTrue(samples.allSatisfy { $0.timestamp >= 8 && $0.timestamp < 10 && $0.label.contains("阶段未知") })
        XCTAssertTrue(AIFramePlan(keyframes: [], start: 8, end: 8).samples.isEmpty)
    }

    func testPartialAndDuplicateMarksStillProduceThirtyBoundedSamples() {
        let marks = [Keyframe(phase: .top, timestampSeconds: 9, markedByCoach: false),
                     Keyframe(phase: .impact, timestampSeconds: 9, markedByCoach: true),
                     Keyframe(phase: .finish, timestampSeconds: 99)]
        let samples = AIFramePlan(keyframes: marks, start: 8, end: 10).samples
        XCTAssertEqual(samples.count, 30)
        XCTAssertEqual(Set(samples.map(\.timestamp)).count, 30)
        XCTAssertTrue(samples.allSatisfy { $0.timestamp >= 8 && $0.timestamp < 10 })
        XCTAssertTrue(samples.contains { $0.timestamp == 9 && $0.label.contains("已复核") })
        XCTAssertFalse(samples.contains { $0.label.contains(SwingPhase.top.nameZH) })
    }
}
