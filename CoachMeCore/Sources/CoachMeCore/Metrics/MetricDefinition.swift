import Foundation

public enum MetricID: String, Sendable, Codable, CaseIterable {
    // Group 1 — computed from a single frame, no address reference needed.
    case elbowInteriorAngle
    case upperArmToTorsoAngle
    case betweenUpperArmsAngle
    case kneeInteriorAngle
    case wristPathBodyReferenced

    // Group 2 — estimates. Require 3D world landmarks AND an address reference.
    case shoulderLineRotation
    case hipLineRotation
    case shoulderHipSeparation
}

/// Identifies one measured quantity: a metric, plus the side it applies to.
/// `side` is nil for bilateral metrics (e.g. the angle between the two upper arms).
public struct MetricKey: Hashable, Sendable, Codable {
    public let id: MetricID
    public let side: BodySide?

    public init(_ id: MetricID, _ side: BodySide? = nil) {
        self.id = id
        self.side = side
    }
}

/// Why a metric could not be produced. Never substituted with 0 or a default.
public enum MetricUnavailableReason: String, Sendable, Codable, Equatable, Error {
    case missingLandmark          // landmark index absent from the frame
    case lowVisibility            // model visibility below the configured gate
    case degenerateGeometry       // coincident points; angle undefined
    case worldLandmarksMissing    // 3D estimate required but not produced
    case addressReferenceMissing  // rotation needs an address keyframe
    case multiplePeople           // more than one subject detected
    case noPersonDetected
    case notApplicableToView      // camera view outside the metric's stated conditions

    public var localizedZH: String {
        switch self {
        case .missingLandmark:        return "关键点缺失"
        case .lowVisibility:          return "关键点可见度不足"
        case .degenerateGeometry:     return "关键点重合，角度无定义"
        case .worldLandmarksMissing:  return "缺少三维估计数据"
        case .addressReferenceMissing: return "尚未标记准备姿势关键帧"
        case .multiplePeople:         return "画面中有多人"
        case .noPersonDetected:       return "未检测到人物"
        case .notApplicableToView:    return "当前拍摄视角不适用"
        }
    }
}

public enum MetricOutcome: Sendable, Equatable, Codable {
    case value(Double)
    case unavailable(MetricUnavailableReason)

    public var value: Double? {
        if case .value(let v) = self { return v }
        return nil
    }

    public var isAvailable: Bool { value != nil }

    /// Text shown wherever a number would otherwise appear.
    public var displayZH: String {
        switch self {
        case .value(let v): return String(format: "%.1f", v)
        case .unavailable:  return "无法可靠计算"
        }
    }
}

/// The full, auditable description of a metric.
///
/// Every field the coach or the report may rely on is recorded here, and
/// `definitionHash` is derived from the fields that change the *meaning* of the
/// number. A saved coach rule stores the hash it was authored against; if the
/// definition later changes, the old reference range is refused rather than
/// silently reused.
public struct MetricDefinition: Sendable, Codable, Identifiable {
    public let id: MetricID
    public let nameZH: String
    public let nameEN: String
    /// Landmarks used, in the order they appear in the formula.
    public let joints: [PoseJoint]
    /// Human-readable formula, precise enough to reimplement from.
    public let formula: String
    /// The coordinate space the computation is performed in.
    public let space: MeasurementSpace
    /// What the numbers are measured against.
    public let referenceFrameZH: String
    /// Projection plane, or a statement that the computation is fully 3D.
    public let projectionZH: String
    /// Where zero is and which direction is positive.
    public let zeroAndSignZH: String
    public let range: ClosedRange<Double>
    public let unit: String
    /// Camera views under which the value is meaningful.
    public let applicableViews: Set<CameraView>
    /// True when the metric needs an address keyframe as its reference.
    public let requiresAddressReference: Bool
    /// What this metric must not be read as. Rendered in the UI next to the value.
    public let caveatZH: String

    public init(id: MetricID,
                nameZH: String,
                nameEN: String,
                joints: [PoseJoint],
                formula: String,
                space: MeasurementSpace,
                referenceFrameZH: String,
                projectionZH: String,
                zeroAndSignZH: String,
                range: ClosedRange<Double>,
                unit: String,
                applicableViews: Set<CameraView>,
                requiresAddressReference: Bool,
                caveatZH: String) {
        self.id = id
        self.nameZH = nameZH
        self.nameEN = nameEN
        self.joints = joints
        self.formula = formula
        self.space = space
        self.referenceFrameZH = referenceFrameZH
        self.projectionZH = projectionZH
        self.zeroAndSignZH = zeroAndSignZH
        self.range = range
        self.unit = unit
        self.applicableViews = applicableViews
        self.requiresAddressReference = requiresAddressReference
        self.caveatZH = caveatZH
    }

    /// Stable fingerprint of the semantics. Changing formula, space, reference
    /// frame, projection, zero convention, range or unit changes the hash.
    public var definitionHash: String {
        let canonical = [
            id.rawValue,
            joints.map { String($0.rawValue) }.joined(separator: ","),
            formula,
            space.rawValue,
            referenceFrameZH,
            projectionZH,
            zeroAndSignZH,
            "\(range.lowerBound)...\(range.upperBound)",
            unit
        ].joined(separator: "|")
        return Self.fnv1a(canonical)
    }

    /// FNV-1a 64-bit, rendered as 16 hex characters. Chosen over CryptoKit so
    /// this module stays free of platform frameworks and is testable anywhere.
    static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in Array(string.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016lx", hash)
    }
}

