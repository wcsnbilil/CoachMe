import Foundation

/// The address pose, captured once and used as the zero reference for every
/// rotation metric. Built from the frame the coach marked as `.address`.
public struct AddressReference: Sendable, Equatable {
    public let timestampSeconds: Double
    /// Rotation axis: the trunk long axis at address.
    public let torsoAxis: Vector3
    public let shoulderLine: Vector3
    public let hipLine: Vector3

    public init?(frame: PoseFrame, space: MeasurementSpace) {
        guard let torso = frame.torsoFrame(in: space),
              let ls = frame.landmark(.leftShoulder, in: space)?.position,
              let rs = frame.landmark(.rightShoulder, in: space)?.position,
              let lh = frame.landmark(.leftHip, in: space)?.position,
              let rh = frame.landmark(.rightHip, in: space)?.position
        else { return nil }

        self.timestampSeconds = frame.timestampSeconds
        self.torsoAxis = torso.up
        self.shoulderLine = rs - ls
        self.hipLine = rh - lh
    }

    init(timestampSeconds: Double, torsoAxis: Vector3, shoulderLine: Vector3, hipLine: Vector3) {
        self.timestampSeconds = timestampSeconds
        self.torsoAxis = torsoAxis
        self.shoulderLine = shoulderLine
        self.hipLine = hipLine
    }
}

/// All measurements produced for one frame.
public struct FrameMetrics: Sendable {
    public let timestampSeconds: Double
    public let outcomes: [MetricKey: MetricOutcome]
    /// Wrist position in the torso frame, per side. Separate from `outcomes`
    /// because it is a 3-component position, not a scalar angle.
    public let wristBodyReferenced: [BodySide: Vector3]
    /// Raw normalised image position of each wrist, for the on-screen path.
    /// Includes whole-body translation — deliberately kept distinct.
    public let wristImagePath: [BodySide: Vector3]
    public let quality: FrameQuality

    public init(timestampSeconds: Double,
                outcomes: [MetricKey: MetricOutcome],
                wristBodyReferenced: [BodySide: Vector3],
                wristImagePath: [BodySide: Vector3],
                quality: FrameQuality) {
        self.timestampSeconds = timestampSeconds
        self.outcomes = outcomes
        self.wristBodyReferenced = wristBodyReferenced
        self.wristImagePath = wristImagePath
        self.quality = quality
    }

    public func outcome(_ id: MetricID, _ side: BodySide? = nil) -> MetricOutcome {
        outcomes[MetricKey(id, side)] ?? .unavailable(.missingLandmark)
    }

    /// Convenience for the UI, which speaks in lead/trail rather than left/right.
    public func outcome(_ id: MetricID, arm: ArmRole, handedness: Handedness) -> MetricOutcome {
        outcome(id, handedness.side(for: arm))
    }
}

public struct SwingMetricsCalculator: Sendable {
    public let handedness: Handedness
    public let cameraView: CameraView
    public let policy: QualityPolicy
    /// Group-1 angles are computed in the 3D estimate when available. If the
    /// model produced no world landmarks the calculator does **not** silently
    /// fall back to image coordinates, because that would change the meaning of
    /// the number without telling anyone.
    public let space: MeasurementSpace

    public init(handedness: Handedness,
                cameraView: CameraView,
                policy: QualityPolicy = .default,
                space: MeasurementSpace = .worldEstimate3D) {
        self.handedness = handedness
        self.cameraView = cameraView
        self.policy = policy
        self.space = space
    }

    // MARK: - Landmark access with the visibility gate applied

    private func position(_ joint: PoseJoint, _ frame: PoseFrame) -> Result<Vector3, MetricUnavailableReason> {
        if space == .worldEstimate3D && frame.worldLandmarks == nil {
            return .failure(.worldLandmarksMissing)
        }
        guard let mark = frame.landmark(joint, in: space) else {
            return .failure(.missingLandmark)
        }
        // Visibility is reported on the image landmarks; the world landmarks share
        // the same indices, so gate on whichever score is available.
        let visibility = frame.imageLandmark(joint)?.visibility ?? mark.visibility ?? 1.0
        guard visibility >= policy.minVisibility else { return .failure(.lowVisibility) }
        if let minPresence = policy.minPresence {
            let presence = frame.imageLandmark(joint)?.presence ?? mark.presence ?? 1.0
            guard presence >= minPresence else { return .failure(.lowVisibility) }
        }
        return .success(mark.position)
    }

    private func positions(_ joints: [PoseJoint], _ frame: PoseFrame) -> Result<[Vector3], MetricUnavailableReason> {
        var out: [Vector3] = []
        out.reserveCapacity(joints.count)
        for joint in joints {
            switch position(joint, frame) {
            case .success(let p): out.append(p)
            case .failure(let reason): return .failure(reason)
            }
        }
        return .success(out)
    }

    /// Wraps a computation that returns nil on degenerate geometry.
    private func outcome(_ joints: [PoseJoint], _ frame: PoseFrame,
                         _ compute: ([Vector3]) -> Double?) -> MetricOutcome {
        switch positions(joints, frame) {
        case .failure(let reason):
            return .unavailable(reason)
        case .success(let pts):
            guard let value = compute(pts) else { return .unavailable(.degenerateGeometry) }
            return .value(value)
        }
    }

    // MARK: - Entry point

    public func metrics(for frame: PoseFrame, address: AddressReference?) -> FrameMetrics {
        let quality = FrameQuality.evaluate(frame: frame, policy: policy)
        var outcomes: [MetricKey: MetricOutcome] = [:]

        // A frame-level problem blocks every metric with one honest reason.
        if let blocking = quality.blockingReason {
            for id in MetricID.allCases {
                let def = MetricCatalog.definition(for: id)
                if def.id == .wristPathBodyReferenced { continue }
                if MetricCatalog.isBilateral(id) {
                    outcomes[MetricKey(id, nil)] = .unavailable(blocking)
                } else {
                    for side in BodySide.allCases { outcomes[MetricKey(id, side)] = .unavailable(blocking) }
                }
            }
            return FrameMetrics(timestampSeconds: frame.timestampSeconds,
                                outcomes: outcomes,
                                wristBodyReferenced: [:],
                                wristImagePath: [:],
                                quality: quality)
        }

        // MARK: Group 1 — per-side joint angles
        for side in BodySide.allCases {
            outcomes[MetricKey(.elbowInteriorAngle, side)] = outcome(
                [.shoulder(side), .elbow(side), .wrist(side)], frame
            ) { AngleMath.interiorAngleDegrees(vertex: $0[1], $0[0], $0[2]) }

            outcomes[MetricKey(.kneeInteriorAngle, side)] = outcome(
                [.hip(side), .knee(side), .ankle(side)], frame
            ) { AngleMath.interiorAngleDegrees(vertex: $0[1], $0[0], $0[2]) }

            outcomes[MetricKey(.upperArmToTorsoAngle, side)] = outcome(
                [.shoulder(side), .elbow(side), .leftShoulder, .rightShoulder, .leftHip, .rightHip], frame
            ) { pts in
                let upperArm = pts[1] - pts[0]
                let shoulderCentre = Vector3.midpoint(pts[2], pts[3])
                let hipCentre = Vector3.midpoint(pts[4], pts[5])
                let torsoDown = hipCentre - shoulderCentre
                return AngleMath.unsignedAngleDegrees(upperArm, torsoDown)
            }
        }

        // MARK: Group 1 — bilateral
        outcomes[MetricKey(.betweenUpperArmsAngle, nil)] = outcome(
            [.leftShoulder, .leftElbow, .rightShoulder, .rightElbow], frame
        ) { AngleMath.unsignedAngleDegrees($0[1] - $0[0], $0[3] - $0[2]) }

        // MARK: Group 2 — rotations relative to address
        let rotations = rotationOutcomes(frame: frame, address: address)
        outcomes[MetricKey(.shoulderLineRotation, nil)] = rotations.shoulder
        outcomes[MetricKey(.hipLineRotation, nil)] = rotations.hip
        outcomes[MetricKey(.shoulderHipSeparation, nil)] = rotations.separation

        // MARK: Wrist paths
        var bodyReferenced: [BodySide: Vector3] = [:]
        var imagePath: [BodySide: Vector3] = [:]
        let torso = frame.torsoFrame(in: space)
        for side in BodySide.allCases {
            if let torso, case .success(let wrist) = position(.wrist(side), frame),
               let local = torso.localise(wrist) {
                bodyReferenced[side] = local
            }
            if let mark = frame.imageLandmark(.wrist(side)),
               (mark.visibility ?? 1.0) >= policy.minVisibility {
                imagePath[side] = mark.position
            }
        }

        return FrameMetrics(timestampSeconds: frame.timestampSeconds,
                            outcomes: outcomes,
                            wristBodyReferenced: bodyReferenced,
                            wristImagePath: imagePath,
                            quality: quality)
    }

    private func rotationOutcomes(frame: PoseFrame, address: AddressReference?)
    -> (shoulder: MetricOutcome, hip: MetricOutcome, separation: MetricOutcome) {

        guard let address else {
            let r = MetricOutcome.unavailable(.addressReferenceMissing)
            return (r, r, r)
        }
        if frame.worldLandmarks == nil {
            let r = MetricOutcome.unavailable(.worldLandmarksMissing)
            return (r, r, r)
        }

        func rotation(_ a: PoseJoint, _ b: PoseJoint, reference: Vector3) -> MetricOutcome {
            switch positions([a, b], frame) {
            case .failure(let reason):
                return .unavailable(reason)
            case .success(let pts):
                let current = pts[1] - pts[0]
                guard let angle = AngleMath.signedRotationDegrees(from: reference,
                                                                  to: current,
                                                                  about: address.torsoAxis)
                else { return .unavailable(.degenerateGeometry) }
                return .value(angle)
            }
        }

        let shoulder = rotation(.leftShoulder, .rightShoulder, reference: address.shoulderLine)
        let hip = rotation(.leftHip, .rightHip, reference: address.hipLine)

        let separation: MetricOutcome
        if let s = shoulder.value, let h = hip.value {
            separation = .value(AngleMath.wrappedDifferenceDegrees(s, h))
        } else if case .unavailable(let reason) = shoulder {
            separation = .unavailable(reason)
        } else if case .unavailable(let reason) = hip {
            separation = .unavailable(reason)
        } else {
            separation = .unavailable(.degenerateGeometry)
        }
        return (shoulder, hip, separation)
    }
}

public extension MetricCatalog {
    /// Metrics that describe the body as a whole rather than one side.
    static func isBilateral(_ id: MetricID) -> Bool {
        switch id {
        case .betweenUpperArmsAngle, .shoulderLineRotation, .hipLineRotation, .shoulderHipSeparation:
            return true
        case .elbowInteriorAngle, .upperArmToTorsoAngle, .kneeInteriorAngle, .wristPathBodyReferenced:
            return false
        }
    }
}
