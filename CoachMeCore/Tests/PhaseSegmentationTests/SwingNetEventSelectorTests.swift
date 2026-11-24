import XCTest
@testable import Model
@testable import PhaseSegmentation

final class SwingNetEventSelectorTests: XCTestCase {
    private func run(_ rows: [[Double]], times: [Double]? = nil) throws -> [Keyframe] {
        var selector = SwingNetEventSelector()
        for (i, row) in rows.enumerated() {
            try selector.append(probabilities: row, timestamp: times?[i] ?? Double(i))
        }
        return selector.keyframes()
    }

    private func row(_ event: Int, _ value: Double) -> [Double] {
        var p = Array(repeating: 0.0, count: 9)
        p[event] = value
        p[8] = 1 - value
        return p
    }

    func testPreservesOriginalTimestampsAndLowScoringAddress() throws {
        let times = [4.02, 4.17, 4.38, 4.56, 4.72, 4.79, 4.84, 5.13]
        let marks = try run((0..<8).map { row($0, $0 == 0 ? 0.002 : 0.7) }, times: times)
        XCTAssertEqual(marks.map(\.phase), [.address, .takeaway, .midBackswing, .top, .midDownswing, .impact, .finish])
        XCTAssertEqual(marks.map(\.timestampSeconds), [4.02, 4.17, 4.38, 4.56, 4.72, 4.79, 5.13])
        XCTAssertTrue(marks.allSatisfy { !$0.markedByCoach && $0.note.contains("SwingNet") })
    }

    func testReversedSwingIsNotOneSwing() throws {
        XCTAssertTrue(try run((0..<8).reversed().map { row($0, 1) }).isEmpty)
    }

    func testOrderedPicksIgnoreALaterStrongerPeak() throws {
        let marks = try run((0..<8).map { row($0, 0.6) } + [row(3, 0.9)])
        XCTAssertEqual(marks.map(\.timestampSeconds), [0, 1, 2, 3, 4, 5, 7])
    }

    func testLaterSetupDoesNotDiscardOrderedSwing() throws {
        let marks = try run((0..<8).map { row($0, 0.5) } + [row(0, 0.9)])
        XCTAssertEqual(marks.map(\.timestampSeconds), [0, 1, 2, 3, 4, 5, 7])
    }

    func testEarlierFinishDoesNotDiscardOrderedSwing() throws {
        let marks = try run([row(7, 0.9)] + (0..<8).map { row($0, 0.5) })
        XCTAssertEqual(marks.map(\.timestampSeconds), [1, 2, 3, 4, 5, 6, 8])
    }

    func testTiesGoToTheEarliestFrame() throws {
        let marks = try run((0..<8).map { row($0, 0.5) } + [row(7, 0.5)])
        XCTAssertEqual(marks.last?.timestampSeconds, 7)
    }

    func testTwoEventsWithoutEvidenceIsNotOneSwing() throws {
        XCTAssertTrue(try run([row(8, 1), row(8, 1)] + (2..<8).map { row($0, 1) }).isEmpty)
    }

    func testFewerFramesThanEventsGivesNoMarks() throws {
        XCTAssertTrue(try run((0..<7).map { row($0, 1) }).isEmpty)
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
