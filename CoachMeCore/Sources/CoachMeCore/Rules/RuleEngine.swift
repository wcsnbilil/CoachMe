import Foundation

/// The result of checking one measured value against one coach rule.
///
/// `outOfRange` deliberately does not say the movement is wrong. It says the
/// value sits outside the range **this coach** configured, and carries the
/// coach's own explanation. The distinction is enforced by the type: there is no
/// "incorrect" case anywhere in this enum.
public enum RuleEvaluation: Sendable, Equatable {
    case inRange(value: Double)
    case outOfRange(value: Double, deviation: Double, direction: Direction)
    /// No range configured for this metric/phase/side combination.
    case noReferenceRange
    /// The rule exists but its conditions do not match this swing.
    case notApplicable(reason: NotApplicableReason)
    /// The measurement itself could not be produced.
    case dataQualityInsufficient(MetricUnavailableReason)
    /// The metric definition changed since the rule was authored.
    case definitionMismatch(authoredAgainst: String, current: String)

    public enum Direction: String, Sendable, Codable {
        case below, above
        public var nameZH: String { self == .below ? "低于" : "高于" }
    }

    public enum NotApplicableReason: String, Sendable, Codable {
        case phaseMismatch, clubMismatch, viewMismatch, sideMismatch
        public var nameZH: String {
            switch self {
            case .phaseMismatch: return "该规则不适用于此动作阶段"
            case .clubMismatch:  return "该规则不适用于此球杆"
            case .viewMismatch:  return "该规则不适用于此拍摄视角"
            case .sideMismatch:  return "该规则不适用于此侧"
            }
        }
    }
}

/// One line of the report: value → phase → range → deviation → explanation.
public struct RuleFinding: Sendable, Identifiable {
    public let id: UUID
    public let rule: CoachRule
    public let definition: MetricDefinition
    public let phase: SwingPhase
    /// Frame this finding was measured on — every finding is traceable to a frame.
    public let timestampSeconds: Double
    public let side: BodySide?
    public let evaluation: RuleEvaluation

    public init(id: UUID = UUID(),
                rule: CoachRule,
                definition: MetricDefinition,
                phase: SwingPhase,
                timestampSeconds: Double,
                side: BodySide?,
                evaluation: RuleEvaluation) {
        self.id = id
        self.rule = rule
        self.definition = definition
        self.phase = phase
        self.timestampSeconds = timestampSeconds
        self.side = side
        self.evaluation = evaluation
    }
}

public struct RuleEngine: Sendable {

    public init() {}

    /// Checks a single measured outcome against a single rule.
    public func evaluate(rule: CoachRule,
                         outcome: MetricOutcome,
                         phase: SwingPhase,
                         club: ClubType,
                         view: CameraView) -> RuleEvaluation {

        // 1. Definition binding. A range authored against an older definition of
        //    the metric is not reused under the new one.
        let definition = MetricCatalog.definition(for: rule.metricID)
        let currentHash = definition.definitionHash
        guard rule.metricDefinitionHash == currentHash else {
            return .definitionMismatch(authoredAgainst: rule.metricDefinitionHash, current: currentHash)
        }

        // 2. Applicability. Checked before data quality so the user is told the
        //    honest reason: "this rule does not apply here", not "bad data".
        guard rule.phases.contains(phase) else { return .notApplicable(reason: .phaseMismatch) }
        guard rule.clubs.contains(club) else { return .notApplicable(reason: .clubMismatch) }
        guard rule.views.contains(view) else { return .notApplicable(reason: .viewMismatch) }

        // 3. The metric's own stated camera conditions.
        guard definition.applicableViews.contains(view) else {
            return .notApplicable(reason: .viewMismatch)
        }

        // 4. Data quality. No deterministic judgement on data we could not measure.
        guard case .value(let value) = outcome else {
            if case .unavailable(let reason) = outcome {
                return .dataQualityInsufficient(reason)
            }
            return .dataQualityInsufficient(.missingLandmark)
        }

        // 5. The range itself.
        guard rule.hasUsableRange else { return .noReferenceRange }

        if let lower = rule.lowerBound, value < lower {
            return .outOfRange(value: value, deviation: lower - value, direction: .below)
        }
        if let upper = rule.upperBound, value > upper {
            return .outOfRange(value: value, deviation: value - upper, direction: .above)
        }
        return .inRange(value: value)
    }

    /// Produces every finding for a swing: for each rule, at each phase it
    /// covers, using the frame the coach marked for that phase.
    ///
    /// - Parameter metricsByPhase: the computed metrics at each marked keyframe.
    public func findings(rules: [CoachRule],
                         metricsByPhase: [SwingPhase: FrameMetrics],
                         handedness: Handedness,
                         club: ClubType,
                         view: CameraView) -> [RuleFinding] {
        var out: [RuleFinding] = []

        for rule in rules {
            let definition = MetricCatalog.definition(for: rule.metricID)
            for phase in rule.phases.sorted(by: { $0.order < $1.order }) {
                guard let metrics = metricsByPhase[phase] else {
                    // The coach has not marked this phase; nothing to measure against.
                    continue
                }

                let side = rule.side.resolve(handedness: handedness)
                // A sided rule pointing at a bilateral metric (or vice versa) is
                // a configuration error, surfaced rather than guessed around.
                let bilateralMetric = MetricCatalog.isBilateral(rule.metricID)
                if bilateralMetric != (side == nil) {
                    out.append(RuleFinding(rule: rule, definition: definition, phase: phase,
                                           timestampSeconds: metrics.timestampSeconds, side: side,
                                           evaluation: .notApplicable(reason: .sideMismatch)))
                    continue
                }

                let outcome = metrics.outcome(rule.metricID, side)
                let evaluation = evaluate(rule: rule, outcome: outcome, phase: phase, club: club, view: view)
                out.append(RuleFinding(rule: rule, definition: definition, phase: phase,
                                       timestampSeconds: metrics.timestampSeconds, side: side,
                                       evaluation: evaluation))
            }
        }
        return out
    }

    /// Metrics that were computed but have no rule covering them, so the report
    /// can say "暂无参考范围" instead of leaving them out silently.
    public func metricsWithoutRules(rules: [CoachRule],
                                    metricsByPhase: [SwingPhase: FrameMetrics]) -> [MetricID] {
        let covered = Set(rules.map(\.metricID))
        return MetricID.allCases.filter { !covered.contains($0) }
    }
}
