import Foundation

/// Which arm or side a rule applies to.
public enum RuleSide: String, Sendable, Codable, CaseIterable {
    case leadArm, trailArm, left, right, bilateral

    /// Resolves to an anatomical side for a given player. Returns nil for
    /// bilateral metrics, which carry no side.
    public func resolve(handedness: Handedness) -> BodySide? {
        switch self {
        case .leadArm:   return handedness.leadSide
        case .trailArm:  return handedness.trailSide
        case .left:      return .left
        case .right:     return .right
        case .bilateral: return nil
        }
    }

    public var nameZH: String {
        switch self {
        case .leadArm:   return "引导臂"
        case .trailArm:  return "后侧臂"
        case .left:      return "左侧"
        case .right:     return "右侧"
        case .bilateral: return "整体"
        }
    }
}

/// A teaching reference range authored by the coach.
///
/// The app ships **no** built-in ranges. There is no "tour average", no single
/// optimal angle and no score. Everything here is the coach's own material, and
/// it carries the conditions under which the coach considers it applicable.
public struct CoachRule: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    /// Bumped by the coach whenever the meaning of the rule changes.
    public var version: Int

    public var metricID: MetricID
    /// The `MetricDefinition.definitionHash` this range was authored against.
    /// If the metric definition later changes, the range is refused rather than
    /// silently reinterpreted under the new definition.
    public var metricDefinitionHash: String

    public var phases: Set<SwingPhase>
    public var side: RuleSide
    public var clubs: Set<ClubType>
    public var views: Set<CameraView>

    /// Free text: which students or teaching goal this range is meant for.
    public var studentConditionNote: String

    /// Inclusive bounds. Either may be nil for a one-sided range. If both are
    /// nil the rule has no usable range and evaluates to `.noReferenceRange`.
    public var lowerBound: Double?
    public var upperBound: Double?
    public var unit: String

    /// Where the range came from — the coach's own observation, a book, a
    /// measurement study. Shown alongside every judgement.
    public var sourceNote: String
    public var coachNote: String
    /// What the coach wants said when a value falls outside the range.
    public var outOfRangeExplanation: String
    public var drillSuggestion: String

    public var createdAt: Date
    public var updatedAt: Date
    /// A paused rule is kept with its source and conditions but never evaluated.
    public var isEnabled: Bool

    public init(id: UUID = UUID(),
                version: Int = 1,
                metricID: MetricID,
                metricDefinitionHash: String,
                phases: Set<SwingPhase>,
                side: RuleSide,
                clubs: Set<ClubType> = Set(ClubType.allCases),
                views: Set<CameraView> = Set(CameraView.allCases),
                studentConditionNote: String = "",
                lowerBound: Double? = nil,
                upperBound: Double? = nil,
                unit: String = "°",
                sourceNote: String = "",
                coachNote: String = "",
                outOfRangeExplanation: String = "",
                drillSuggestion: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                isEnabled: Bool = true) {
        self.id = id
        self.version = version
        self.metricID = metricID
        self.metricDefinitionHash = metricDefinitionHash
        self.phases = phases
        self.side = side
        self.clubs = clubs
        self.views = views
        self.studentConditionNote = studentConditionNote
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.unit = unit
        self.sourceNote = sourceNote
        self.coachNote = coachNote
        self.outOfRangeExplanation = outOfRangeExplanation
        self.drillSuggestion = drillSuggestion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, metricID, metricDefinitionHash, phases, side, clubs, views
        case studentConditionNote, lowerBound, upperBound, unit, sourceNote, coachNote
        case outOfRangeExplanation, drillSuggestion, createdAt, updatedAt, isEnabled
    }

    /// Rules saved before `isEnabled` existed decode as enabled.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        version = try c.decode(Int.self, forKey: .version)
        metricID = try c.decode(MetricID.self, forKey: .metricID)
        metricDefinitionHash = try c.decode(String.self, forKey: .metricDefinitionHash)
        phases = try c.decode(Set<SwingPhase>.self, forKey: .phases)
        side = try c.decode(RuleSide.self, forKey: .side)
        clubs = try c.decode(Set<ClubType>.self, forKey: .clubs)
        views = try c.decode(Set<CameraView>.self, forKey: .views)
        studentConditionNote = try c.decode(String.self, forKey: .studentConditionNote)
        lowerBound = try c.decodeIfPresent(Double.self, forKey: .lowerBound)
        upperBound = try c.decodeIfPresent(Double.self, forKey: .upperBound)
        unit = try c.decode(String.self, forKey: .unit)
        sourceNote = try c.decode(String.self, forKey: .sourceNote)
        coachNote = try c.decode(String.self, forKey: .coachNote)
        outOfRangeExplanation = try c.decode(String.self, forKey: .outOfRangeExplanation)
        drillSuggestion = try c.decode(String.self, forKey: .drillSuggestion)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public var hasUsableRange: Bool { lowerBound != nil || upperBound != nil }
}
