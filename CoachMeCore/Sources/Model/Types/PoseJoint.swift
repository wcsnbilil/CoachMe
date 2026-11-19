import Foundation

/// The 33 landmarks produced by MediaPipe Pose Landmarker, in the model's index order.
///
/// Index order is fixed by the model; do not reorder. Verified against the
/// MediaPipe Pose Landmarker model card (33 landmarks, indices 0...32).
public enum PoseJoint: Int, CaseIterable, Sendable, Codable {
    case nose = 0
    case leftEyeInner, leftEye, leftEyeOuter
    case rightEyeInner, rightEye, rightEyeOuter
    case leftEar, rightEar
    case mouthLeft, mouthRight
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftPinky, rightPinky
    case leftIndex, rightIndex
    case leftThumb, rightThumb
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
    case leftHeel, rightHeel
    case leftFootIndex, rightFootIndex
}

/// Anatomical left/right, as reported by the model (model-frame left/right, not screen side).
public enum BodySide: String, Sendable, Codable, CaseIterable {
    case left, right

    public var opposite: BodySide { self == .left ? .right : .left }
}

/// Which hand is lower on the grip — set by the user, never inferred.
public enum Handedness: String, Sendable, Codable, CaseIterable {
    case rightHanded
    case leftHanded

    /// The arm closer to the target. For a right-handed golfer this is the LEFT arm.
    public var leadSide: BodySide { self == .rightHanded ? .left : .right }

    /// The arm further from the target. For a right-handed golfer this is the RIGHT arm.
    public var trailSide: BodySide { self == .rightHanded ? .right : .left }

    public func side(for role: ArmRole) -> BodySide {
        switch role {
        case .lead: return leadSide
        case .trail: return trailSide
        }
    }
}

/// Arm identified by its role in the swing rather than by anatomical side.
public enum ArmRole: String, Sendable, Codable, CaseIterable {
    case lead
    case trail
}

public extension PoseJoint {
    static func shoulder(_ side: BodySide) -> PoseJoint { side == .left ? .leftShoulder : .rightShoulder }
    static func elbow(_ side: BodySide) -> PoseJoint { side == .left ? .leftElbow : .rightElbow }
    static func wrist(_ side: BodySide) -> PoseJoint { side == .left ? .leftWrist : .rightWrist }
    static func hip(_ side: BodySide) -> PoseJoint { side == .left ? .leftHip : .rightHip }
    static func knee(_ side: BodySide) -> PoseJoint { side == .left ? .leftKnee : .rightKnee }
    static func ankle(_ side: BodySide) -> PoseJoint { side == .left ? .leftAnkle : .rightAnkle }
}
