import XCTest
@testable import CoachMeCore

final class RuleEnabledTests: XCTestCase {

    func testRulesSavedBeforeEnableFlagDecodeAsEnabled() throws {
        let rule = CoachRule(metricID: .elbowInteriorAngle, metricDefinitionHash: "hash",
                             phases: [.top], side: .leadArm, lowerBound: 150, upperBound: 175)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        XCTAssertEqual(object["isEnabled"] as? Bool, true)

        object.removeValue(forKey: "isEnabled")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CoachRule.self, from: legacy)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded, rule)
    }

    func testDisabledRuleLeavesMetricUncovered() {
        var rule = CoachRule(metricID: .elbowInteriorAngle,
                             metricDefinitionHash: MetricCatalog.definition(for: .elbowInteriorAngle).definitionHash,
                             phases: [.top], side: .leadArm, lowerBound: 150, upperBound: 175)
        let engine = RuleEngine()
        XCTAssertFalse(engine.metricsWithoutRules(rules: [rule], metricsByPhase: [:]).contains(.elbowInteriorAngle))
        rule.isEnabled = false
        XCTAssertTrue(engine.metricsWithoutRules(rules: [rule], metricsByPhase: [:]).contains(.elbowInteriorAngle))
    }
}
