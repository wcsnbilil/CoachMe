import Foundation

/// One landmark as reported by the model.
///
/// `visibility` and `presence` are the model's own scores. They gate whether a
/// metric is computed at all; they are **not** a statement about the accuracy of
/// the resulting angle. See `docs/LIMITATIONS.md`.
public struct Landmark: Equatable, Sendable, Codable {
    public var position: Vector3
    public var visibility: Double?
    public var presence: Double?

    public init(position: Vector3, visibility: Double? = nil, presence: Double? = nil) {
        self.position = position
        self.visibility = visibility
        self.presence = presence
    }

    public init(_ x: Double, _ y: Double, _ z: Double, visibility: Double? = nil, presence: Double? = nil) {
        self.init(position: Vector3(x, y, z), visibility: visibility, presence: presence)
    }
}

/// Which coordinate space a measurement was taken in.
public enum MeasurementSpace: String, Sendable, Codable {
    /// Normalised image coordinates (x, y in 0...1 of the *upright* frame).
    /// Angles here are projections onto the image plane and depend on camera view.
    case imagePlane2D

    /// MediaPipe "world landmarks": a metric-scale 3D estimate produced by the
    /// GHUM model, with the origin at the hip centre. It is a model estimate of
    /// body shape, not calibrated motion capture, and its axes are not tied to
    /// the ground, the target line, or any world frame.
    case worldEstimate3D
}

/// Camera setup declared by the user. Never inferred from the video.
public enum CameraView: String, Sendable, Codable, CaseIterable {
    case faceOn          // 正面
    case downTheLine     // 沿目标线后方
    case unknown         // 未知
}

public enum ClubType: String, Sendable, Codable, CaseIterable {
    case driver, wood, hybrid, iron, wedge, putter, unknown
}

/// Landmarks for a single decoded video frame, keyed to the original
/// presentation timestamp so variable-frame-rate video stays correct.
public struct PoseFrame: Sendable, Codable {
    /// Presentation timestamp from the source video, in seconds.
    public let timestampSeconds: Double

    /// Normalised image-space landmarks, expressed in the **upright, display-
    /// oriented** frame after the video's rotation/mirroring transform has been
    /// applied. x and y are 0...1 across the visible picture; z is the model's
    /// relative depth and is not metric.
    public let imageLandmarks: [Landmark]

    /// World landmarks, if the model returned them. Metric-scale estimate,
    /// hip-centred. Optional because a frame may fail to produce them.
    public let worldLandmarks: [Landmark]?

    /// How many people the model detected in this frame. A value other than 1
    /// makes every metric unreliable — see `FrameQuality`.
    public let detectedPersonCount: Int

    public init(timestampSeconds: Double,
                imageLandmarks: [Landmark],
                worldLandmarks: [Landmark]?,
                detectedPersonCount: Int) {
        self.timestampSeconds = timestampSeconds
        self.imageLandmarks = imageLandmarks
        self.worldLandmarks = worldLandmarks
        self.detectedPersonCount = detectedPersonCount
    }

    public func imageLandmark(_ joint: PoseJoint) -> Landmark? {
        guard imageLandmarks.indices.contains(joint.rawValue) else { return nil }
        return imageLandmarks[joint.rawValue]
    }

    public func worldLandmark(_ joint: PoseJoint) -> Landmark? {
        guard let world = worldLandmarks, world.indices.contains(joint.rawValue) else { return nil }
        return world[joint.rawValue]
    }

    /// Landmarks in the requested space, or nil if that space is unavailable.
    public func landmark(_ joint: PoseJoint, in space: MeasurementSpace) -> Landmark? {
        switch space {
        case .imagePlane2D: return imageLandmark(joint)
        case .worldEstimate3D: return worldLandmark(joint)
        }
    }
}
