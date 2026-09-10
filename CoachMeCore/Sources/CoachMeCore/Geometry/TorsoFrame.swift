import Foundation

/// An orthonormal body frame derived from the trunk landmarks.
///
/// The basis is built **only** from the subject's own landmarks, so it does not
/// depend on the raw axis convention of the coordinate space, on the camera, or
/// on any assumption about the ground plane or the target line.
///
/// - `up`      hip centre → shoulder centre (the trunk's long axis)
/// - `lateral` left hip → right hip, orthogonalised against `up`
/// - `forward` `up × lateral`, completing a right-handed basis
///
/// This frame is what makes "arm position relative to the torso" and "rotation
/// relative to the address pose" meaningful. It is *not* a world frame: `up` is
/// the trunk axis, which tilts with the spine, not gravity.
public struct TorsoFrame: Sendable, Equatable {
    public let origin: Vector3
    public let up: Vector3
    public let lateral: Vector3
    public let forward: Vector3
    /// Distance from hip centre to shoulder centre. Used to normalise
    /// body-referenced positions so camera distance does not change the result.
    public let torsoLength: Double

    public init(origin: Vector3, up: Vector3, lateral: Vector3, forward: Vector3, torsoLength: Double) {
        self.origin = origin
        self.up = up
        self.lateral = lateral
        self.forward = forward
        self.torsoLength = torsoLength
    }

    /// Builds the frame, or returns nil when the trunk landmarks are missing or
    /// degenerate (e.g. hips and shoulders coincide, or the hip line is parallel
    /// to the trunk axis).
    public static func make(leftHip: Vector3,
                            rightHip: Vector3,
                            leftShoulder: Vector3,
                            rightShoulder: Vector3) -> TorsoFrame? {
        let hipCentre = Vector3.midpoint(leftHip, rightHip)
        let shoulderCentre = Vector3.midpoint(leftShoulder, rightShoulder)

        let upRaw = shoulderCentre - hipCentre
        guard let up = upRaw.normalized() else { return nil }

        let hipLine = rightHip - leftHip
        guard let lateral = hipLine.projectedOntoPlane(normal: up)?.normalized() else { return nil }

        let forward = up.cross(lateral)
        guard let forwardN = forward.normalized() else { return nil }

        return TorsoFrame(origin: hipCentre,
                          up: up,
                          lateral: lateral,
                          forward: forwardN,
                          torsoLength: upRaw.length)
    }

    /// Expresses a world point in this frame: components along
    /// (lateral, forward, up), with the hip centre as origin, divided by torso
    /// length so the result is scale-free.
    ///
    /// Because the origin travels with the hips and the axes rotate with the
    /// trunk, whole-body translation and body rotation are removed. What remains
    /// is motion *relative to the torso*.
    public func localise(_ point: Vector3) -> Vector3? {
        guard torsoLength > Vector3.degenerateLengthThreshold else { return nil }
        let d = point - origin
        return Vector3(d.dot(lateral) / torsoLength,
                       d.dot(forward) / torsoLength,
                       d.dot(up) / torsoLength)
    }
}

public extension PoseFrame {
    /// Builds the torso frame in the requested space, if all four trunk
    /// landmarks are present.
    func torsoFrame(in space: MeasurementSpace) -> TorsoFrame? {
        guard let lh = landmark(.leftHip, in: space)?.position,
              let rh = landmark(.rightHip, in: space)?.position,
              let ls = landmark(.leftShoulder, in: space)?.position,
              let rs = landmark(.rightShoulder, in: space)?.position
        else { return nil }
        return TorsoFrame.make(leftHip: lh, rightHip: rh, leftShoulder: ls, rightShoulder: rs)
    }
}
