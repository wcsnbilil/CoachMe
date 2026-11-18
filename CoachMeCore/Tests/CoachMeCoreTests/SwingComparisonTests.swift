import XCTest
@testable import CoachMeCore

/// Same cases as `tools/reference/verify_comparison.py`.
final class SwingComparisonTests: XCTestCase {

    private func reading(_ metric: MetricID, _ side: BodySide?, _ phase: SwingPhase, _ value: Double?,
                         hash: String = "h1", unit: String = "°") -> SwingAnalysisContext.MetricReading {
        .init(metricID: metric, nameZH: "", side: side, phase: phase, timestampSeconds: 0,
              value: value, unit: unit, unavailableReason: nil, space: .worldEstimate3D,
              definitionFormula: "", definitionHash: hash, caveatZH: "", coachRange: nil)
    }

    private func context(_ readings: [SwingAnalysisContext.MetricReading], _ phases: [SwingPhase],
                         handedness: Handedness = .rightHanded, view: CameraView = .faceOn,
                         club: ClubType = .iron) -> SwingAnalysisContext {
        SwingAnalysisContext(swingID: UUID(), analysisVersion: 1, handedness: handedness, club: club,
                             cameraView: view, markedPhases: phases, selectedPhase: nil,
                             selectedTimestampSeconds: nil, readings: readings,
                             quality: .init(framesAnalysed: 0, framesWithNoPerson: 0,
                                            framesWithMultiplePeople: 0, metricsUnavailable: [],
                                            statedLimitationsZH: []),
                             comparison: nil)
    }

    func testAlignsOnCommonPhasesAndSubtractsOther() {
        let a = context([reading(.elbowInteriorAngle, .left, .top, 150),
                         reading(.elbowInteriorAngle, .left, .impact, 170)], [.address, .top, .impact])
        let b = context([reading(.elbowInteriorAngle, .left, .top, 140),
                         reading(.elbowInteriorAngle, .left, .impact, 175)], [.top, .impact, .finish])
        let r = SwingComparison.summary(this: a, other: b)
        XCTAssertEqual(r.otherSwingID, b.swingID)
        XCTAssertEqual(r.alignedPhases, [.top, .impact])
        XCTAssertEqual(r.deltas.map(\.delta), [10, -5])
        XCTAssertEqual(r.warningsZH, [])
    }

    func testNoCommonPhaseGivesNoDeltasAndAWarning() {
        let r = SwingComparison.summary(
            this: context([reading(.kneeInteriorAngle, .left, .address, 160)], [.address]),
            other: context([reading(.kneeInteriorAngle, .left, .address, 150)], [.top]))
        XCTAssertTrue(r.deltas.isEmpty)
        XCTAssertTrue(r.warningsZH.first?.hasPrefix("两次挥杆没有共同") ?? false)
    }

    func testMissingAndNonFiniteValuesNeverBecomeANumber() {
        let a = context([reading(.elbowInteriorAngle, .left, .top, nil),
                         reading(.elbowInteriorAngle, .right, .top, .nan),
                         reading(.kneeInteriorAngle, .left, .top, 150)], [.top])
        let b = context([reading(.elbowInteriorAngle, .left, .top, 140),
                         reading(.elbowInteriorAngle, .right, .top, 120)], [.top])
        let d = SwingComparison.summary(this: a, other: b).deltas
        XCTAssertNil(d[0].delta)
        XCTAssertNil(d[1].thisValue)
        XCTAssertNil(d[1].delta)
        XCTAssertNil(d[2].otherValue)
        XCTAssertNil(d[2].delta)
    }

    func testHandednessMatchesLeadArmWithLeadArm() {
        let a = context([reading(.elbowInteriorAngle, .left, .top, 150)], [.top], handedness: .rightHanded)
        let b = context([reading(.elbowInteriorAngle, .left, .top, 100),
                         reading(.elbowInteriorAngle, .right, .top, 145)], [.top], handedness: .leftHanded)
        let r = SwingComparison.summary(this: a, other: b)
        XCTAssertEqual(r.deltas[0].otherValue, 145)
        XCTAssertEqual(r.deltas[0].delta, 5)
        XCTAssertTrue(r.warningsZH.contains { $0.contains("持杆手不同") })
    }

    func testBilateralMetricsMatch() {
        let r = SwingComparison.summary(
            this: context([reading(.shoulderLineRotation, nil, .top, -44)], [.top]),
            other: context([reading(.shoulderLineRotation, nil, .top, -50)], [.top]))
        XCTAssertEqual(r.deltas[0].delta, 6)
    }

    func testDefinitionOrUnitMismatchKeepsValuesButNoDelta() {
        let a = context([reading(.elbowInteriorAngle, .left, .top, 150, hash: "new"),
                         reading(.kneeInteriorAngle, .left, .top, 150)], [.top])
        let b = context([reading(.elbowInteriorAngle, .left, .top, 140, hash: "old"),
                         reading(.kneeInteriorAngle, .left, .top, 2.6, unit: "rad")], [.top])
        let r = SwingComparison.summary(this: a, other: b)
        XCTAssertNil(r.deltas[0].delta)
        XCTAssertNil(r.deltas[1].delta)
        XCTAssertEqual(r.deltas[0].thisValue, 150)
        XCTAssertEqual(r.deltas[0].otherValue, 140)
        XCTAssertTrue(r.warningsZH.contains { $0.contains("有 2 项指标定义版本不同") })
    }

    func testViewWarningComesBeforeClubWarning() {
        let w = SwingComparison.summary(this: context([], [.top], view: .faceOn, club: .driver),
                                        other: context([], [.top], view: .downTheLine, club: .iron)).warningsZH
        XCTAssertTrue(w[0].hasPrefix("机位不同（正面 / 沿目标线后方）"))
        XCTAssertTrue(w[1].hasPrefix("球杆不同"))
    }

    func testDeltaOrderFollowsThisSwing() {
        let a = context([reading(.kneeInteriorAngle, .left, .impact, 1),
                         reading(.elbowInteriorAngle, .left, .top, 2)], [.top, .impact])
        let d = SwingComparison.summary(this: a, other: context([], [.top, .impact])).deltas
        XCTAssertEqual(d.map(\.metricID), [.kneeInteriorAngle, .elbowInteriorAngle])
        XCTAssertEqual(d.map(\.phase), [.impact, .top])
    }

    func testWithComparisonKeepsEverythingElse() {
        var a = context([reading(.elbowInteriorAngle, .left, .top, 150)], [.top])
        a.analysisDetails = "details"
        let summary = SwingComparison.summary(this: a, other: context([], [.top]))
        let attached = a.withComparison(summary)
        XCTAssertEqual(attached.comparison, summary)
        XCTAssertEqual(attached.analysisDetails, "details")
        XCTAssertEqual(attached.withComparison(nil), a)
    }
}
