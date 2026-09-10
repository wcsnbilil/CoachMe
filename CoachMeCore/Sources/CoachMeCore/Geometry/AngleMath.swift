import Foundation

/// Angle primitives shared by every metric.
///
/// Every function returns `nil` instead of NaN when the input is degenerate
/// (coincident or zero-length vectors). Callers must translate `nil` into an
/// explicit "cannot be computed reliably" outcome — never into 0 or a default.
public enum AngleMath {

    public static func degrees(radians: Double) -> Double { radians * 180.0 / .pi }
    public static func radians(degrees: Double) -> Double { degrees * .pi / 180.0 }

    /// Unsigned angle between two direction vectors.
    /// - Returns: degrees in `0...180`, or nil if either vector is degenerate.
    /// - Note: Invariant under translation of the underlying points, under any
    ///   rigid rotation applied to both vectors, and under uniform scaling.
    public static func unsignedAngleDegrees(_ u: Vector3, _ v: Vector3) -> Double? {
        guard let un = u.normalized(), let vn = v.normalized() else { return nil }
        // Clamp guards against |dot| slightly exceeding 1 from floating-point error.
        let cosine = min(1.0, max(-1.0, un.dot(vn)))
        return degrees(radians: acos(cosine))
    }

    /// Interior angle at `vertex` in the chain a — vertex — b.
    ///
    /// A fully extended chain (a, vertex, b collinear with vertex between them)
    /// measures 180°. This is the convention used for elbow and knee angles.
    /// - Returns: degrees in `0...180`, or nil if either limb segment is degenerate.
    public static func interiorAngleDegrees(vertex: Vector3, _ a: Vector3, _ b: Vector3) -> Double? {
        unsignedAngleDegrees(a - vertex, b - vertex)
    }

    /// Flexion angle expressed from the interior angle.
    ///
    /// `flexion = 180 - interior`. Fully extended = 0° flexion = 180° interior.
    /// Exposed explicitly so the two conventions are never silently mixed.
    public static func flexionDegrees(fromInteriorAngle interior: Double) -> Double {
        180.0 - interior
    }

    /// Difference between two signed rotations, wrapped back into `-180...180`.
    ///
    /// Both inputs come from `signedRotationDegrees` and so live in `-180...180`.
    /// Their raw difference spans `-360...360`, and near the ±180 seam one input
    /// flips sign while the body has barely moved: subtracting then reports a
    /// 346° separation where the true figure is -14°. Observed on real footage
    /// during the follow-through, where shoulder and hip lines both pass ±180.
    public static func wrappedDifferenceDegrees(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Signed rotation from `reference` to `current`, measured in the plane
    /// perpendicular to `axis`.
    ///
    /// Positive follows the right-hand rule about `axis`. Both vectors are
    /// projected onto the plane first, so any component along the axis (e.g. a
    /// shoulder line that is tilted rather than rotated) is discarded rather
    /// than being counted as rotation.
    ///
    /// - Returns: degrees in `-180...180`, or nil if the axis is degenerate or
    ///   either vector projects to (near) zero — i.e. it points along the axis
    ///   and carries no rotational information.
    /// - Note: Invariant when the same rigid rotation is applied to `reference`,
    ///   `current` and `axis` together. That property is what makes this a valid
    ///   "rotation relative to the address pose" measure.
    public static func signedRotationDegrees(from reference: Vector3,
                                             to current: Vector3,
                                             about axis: Vector3) -> Double? {
        guard let n = axis.normalized(),
              let r = reference.projectedOntoPlane(normal: n)?.normalized(),
              let c = current.projectedOntoPlane(normal: n)?.normalized()
        else { return nil }

        let cosine = min(1.0, max(-1.0, r.dot(c)))
        let sine = r.cross(c).dot(n)
        return degrees(radians: atan2(sine, cosine))
    }
}
