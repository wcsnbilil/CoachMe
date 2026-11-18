import XCTest
@testable import CoachMeCore

/// Expected outcomes verified by `tools/reference/verify_rules.mjs` (25/25 passing).
///
/// NOT YET EXECUTED in Swift — no toolchain on the development machine.
final class RuleEngineTests: XCTestCase {

    private let engine = RuleEngine()

    private func rule(metric: MetricID = .elbowInteriorAngle,
                      hash: String? = nil,
                      phases: Set<SwingPhase> = [.top],
                      side: RuleSide = .leadArm,
                      clubs: Set<ClubType> = [.driver, .iron],
                      views: Set<CameraView> = [.faceOn, .downTheLine],
                      lower: Double? = 150,
                      upper: Double? = 175) -> CoachRule {
        CoachRule(metricID: metric,
                  metricDefinitionHash: hash ?? MetricCatalog.definition(for: metric).definitionHash,
                  phases: phases, side: side, clubs: clubs, views: views,
                  lowerBound: lower, upperBound: upper)
    }

    // MARK: - Range comparison

    func testValueInsideRange() {
        let result = engine.evaluate(rule: rule(), outcome: .value(160),
                                     phase: .top, club: .driver, view: .faceOn)
        XCTAssertEqual(result, .inRange(value: 160))
    }

    func testBoundsAreInclusive() {
        XCTAssertEqual(engine.evaluate(rule: rule(), outcome: .value(150),
                                       phase: .top, club: .driver, view: .faceOn),
                       .inRange(value: 150))
        XCTAssertEqual(engine.evaluate(rule: rule(), outcome: .value(175),
                                       phase: .top, club: .driver, view: .faceOn),
                       .inRange(value: 175))
    }

    func testDeviationIsReportedWithDirection() {
        XCTAssertEqual(engine.evaluate(rule: rule(), outcome: .value(142.5),
                                       phase: .top, club: .driver, view: .faceOn),
                       .outOfRange(value: 142.5, deviation: 7.5, direction: .below))
        XCTAssertEqual(engine.evaluate(rule: rule(), outcome: .value(180),
                                       phase: .top, club: .driver, view: .faceOn),
                       .outOfRange(value: 180, deviation: 5, direction: .above))
    }

    func testNoBoundsMeansNoReferenceRange() {
        let result = engine.evaluate(rule: rule(lower: nil, upper: nil), outcome: .value(160),
                                     phase: .top, club: .driver, view: .faceOn)
        XCTAssertEqual(result, .noReferenceRange)
    }

    // MARK: - Applicability

    func testApplicabilityGates() {
        XCTAssertEqual(engine.evaluate(rule: rule(), outcome: .value(160),
                                       phase: .impact, club: .driver, view: .faceOn),
                       .notApplicable(reason: .phaseMismatch))
        XCTAssertEqual(engine.evaluate(rule: rule(), outcome: .value(160),
                                       phase: .top, club: .putter, view: .faceOn),
                       .notApplicable(reason: .clubMismatch))
        XCTAssertEqual(engine.evaluate(rule: rule(), outcome: .value(160),
                                       phase: .top, club: .driver, view: .unknown),
                       .notApplicable(reason: .viewMismatch))
    }

    // MARK: - Data quality is never judged

    func testUnavailableMetricIsNeverJudged() {
        let reasons: [MetricUnavailableReason] = [
            .lowVisibility, .degenerateGeometry, .worldLandmarksMissing,
            .addressReferenceMissing, .multiplePeople, .noPersonDetected, .missingLandmark
        ]
        for reason in reasons {
            let result = engine.evaluate(rule: rule(), outcome: .unavailable(reason),
                                         phase: .top, club: .driver, view: .faceOn)
            XCTAssertEqual(result, .dataQualityInsufficient(reason),
                           "unavailable(\(reason)) must not be scored")
        }
    }

    // MARK: - Precedence

    func testStaleDefinitionBeatsEverythingElse() {
        let result = engine.evaluate(rule: rule(hash: "OLDHASH00000000"),
                                     outcome: .unavailable(.lowVisibility),
                                     phase: .impact, club: .putter, view: .unknown)
        guard case .definitionMismatch = result else {
            return XCTFail("expected definitionMismatch, got \(result)")
        }
    }

    func testApplicabilityIsCheckedBeforeDataQuality() {
        let result = engine.evaluate(rule: rule(), outcome: .unavailable(.lowVisibility),
                                     phase: .impact, club: .driver, view: .faceOn)
        XCTAssertEqual(result, .notApplicable(reason: .phaseMismatch))
    }

    func testDataQualityIsCheckedBeforeRange() {
        let result = engine.evaluate(rule: rule(), outcome: .unavailable(.multiplePeople),
                                     phase: .top, club: .driver, view: .faceOn)
        XCTAssertEqual(result, .dataQualityInsufficient(.multiplePeople))
    }

    // MARK: - Definition binding

    func testChangingTheDefinitionInvalidatesTheRange() {
        // A rule authored against the current definition evaluates normally...
        let current = rule()
        XCTAssertEqual(engine.evaluate(rule: current, outcome: .value(160),
                                       phase: .top, club: .driver, view: .faceOn),
                       .inRange(value: 160))
        // ...but the same range bound to a different definition hash is refused.
        let stale = rule(hash: "0000000000000000")
        guard case .definitionMismatch = engine.evaluate(rule: stale, outcome: .value(160),
                                                         phase: .top, club: .driver, view: .faceOn) else {
            return XCTFail("a range authored against an old definition must not be reused")
        }
    }

    func testDefinitionHashIsStableAndDistinct() {
        let hashes = MetricCatalog.all.map(\.definitionHash)
        XCTAssertEqual(Set(hashes).count, hashes.count, "every metric needs a distinct hash")
        // Stability: recomputing gives the same value.
        XCTAssertEqual(MetricCatalog.elbowInteriorAngle.definitionHash,
                       MetricCatalog.elbowInteriorAngle.definitionHash)
    }

    // MARK: - Side resolution

    func testRuleSideResolution() {
        XCTAssertEqual(RuleSide.leadArm.resolve(handedness: .rightHanded), .left)
        XCTAssertEqual(RuleSide.trailArm.resolve(handedness: .leftHanded), .left)
        XCTAssertNil(RuleSide.bilateral.resolve(handedness: .rightHanded))
    }

    func testCatalogCoversEveryMetricID() {
        XCTAssertEqual(Set(MetricCatalog.all.map(\.id)), Set(MetricID.allCases))
    }
}
