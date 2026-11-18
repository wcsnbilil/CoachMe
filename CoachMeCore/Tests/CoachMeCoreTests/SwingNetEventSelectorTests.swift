import XCTest
@testable import CoachMeCore

final class SwingNetEventSelectorTests: XCTestCase {
    func testPreservesOriginalTimestampsAndLowScoringAddress() throws {
        var selector = SwingNetEventSelector()
        // Original timestamps intentionally start after zero and are irregular.
        let times = [4.02, 4.17, 4.38, 4.56, 4.72, 4.79, 4.84, 5.13]
        for event in 0..<8 {
            var probabilities = Array(repeating: 0.0, count: 9)
            probabilities[event] = event == 0 ? 0.002 : 0.7
            probabilities[8] = 1 - probabilities[event]
            try selector.append(probabilities: probabilities, timestamp: times[event])
        }
        let marks = selector.keyframes()
        XCTAssertEqual(marks.map(\.phase), [.address, .takeaway, .midBackswing, .top, .midDownswing, .impact, .finish])
        XCTAssertEqual(marks.map(\.timestampSeconds), [4.02, 4.17, 4.38, 4.56, 4.72, 4.79, 5.13])
        XCTAssertTrue(marks.allSatisfy { !$0.markedByCoach && $0.note.contains("SwingNet") })
    }

    func testContradictoryOrderDoesNotCreateFalseMarkers() throws {
        var selector = SwingNetEventSelector()
        for event in (0..<8).reversed() {
            var p = Array(repeating: 0.0, count: 9); p[event] = 1
            try selector.append(probabilities: p, timestamp: Double(8 - event))
        }
        XCTAssertTrue(selector.keyframes().isEmpty)
    }

    func testLaterSetupDoesNotDiscardOrderedSwing() throws {
        var selector = SwingNetEventSelector()
        for i in 0..<9 {
            var p = Array(repeating: 0.0, count: 9)
            p[i < 8 ? i : 0] = i == 8 ? 0.9 : 0.5
            p[8] = 1 - p.reduce(0, +)
            try selector.append(probabilities: p, timestamp: Double(i))
        }
        XCTAssertEqual(selector.keyframes().map(\.timestampSeconds), [0, 1, 2, 3, 4, 5, 7])
    }

    func testEarlierFinishDoesNotDiscardOrderedSwing() throws {
        var selector = SwingNetEventSelector()
        var early = Array(repeating: 0.0, count: 9)
        early[7] = 0.9; early[8] = 0.1
        try selector.append(probabilities: early, timestamp: 0)
        for i in 0..<8 {
            var p = Array(repeating: 0.0, count: 9)
            p[i] = 0.5; p[8] = 0.5
            try selector.append(probabilities: p, timestamp: Double(i + 1))
        }
        XCTAssertEqual(selector.keyframes().map(\.timestampSeconds), [1, 2, 3, 4, 5, 6, 8])
    }

    func testMissingSetupEvidenceDoesNotInventBoundary() throws {
        var selector = SwingNetEventSelector()
        for i in 2..<8 {
            var p = Array(repeating: 0.0, count: 9)
            p[i] = 1
            try selector.append(probabilities: p, timestamp: Double(i))
        }
        var late = Array(repeating: 0.0, count: 9); late[0] = 1
        try selector.append(probabilities: late, timestamp: 8)
        XCTAssertTrue(selector.keyframes().isEmpty)
    }

    func testRejectsNonfiniteOrRepeatedTimestamps() throws {
        var selector = SwingNetEventSelector()
        let p = Array(repeating: 1.0 / 9, count: 9)
        XCTAssertThrowsError(try selector.append(probabilities: p, timestamp: .nan))
        try selector.append(probabilities: p, timestamp: 5)
        XCTAssertThrowsError(try selector.append(probabilities: p, timestamp: 5))
        XCTAssertThrowsError(try selector.append(probabilities: [0.1], timestamp: 6))
    }
}
