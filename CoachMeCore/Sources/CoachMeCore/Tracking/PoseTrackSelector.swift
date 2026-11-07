import Foundation

/// Picks which detected person to keep on each frame.
///
/// The detector runs with two poses so a second person can be reported, but
/// MediaPipe does not keep the order of the poses stable: on some frames the
/// first pose is the bystander. Taking `landmarks.first` then made the whole
/// skeleton jump to the other person for those frames, which the swing-path
/// check read as a wild hand path.
///
/// Rule: on the first frame with anyone, keep the largest body (shoulders to
/// hips, the golfer is normally the one nearest the camera); after that keep
/// the pose whose torso is closest to the one kept last.
public struct PoseTrackSelector: Sendable {
    private var last: (x: Double, y: Double)?

    public init() {}

    public mutating func reset() { last = nil }

    /// Index into `poses` (each a 33-landmark image-space pose), or nil if empty.
    public mutating func select(_ poses: [[Landmark]]) -> Int? {
        guard !poses.isEmpty else { return nil }
        let centres = poses.map(Self.torsoCentre)
        var pick = 0
        if poses.count > 1 {
            if let last {
                pick = centres.indices.min { a, b in
                    Self.distance(centres[a], last) < Self.distance(centres[b], last)
                } ?? 0
            } else {
                pick = poses.indices.max { Self.torsoSize(poses[$0]) < Self.torsoSize(poses[$1]) } ?? 0
            }
        }
        if let c = centres[pick] { last = c }
        return pick
    }

    static func distance(_ c: (x: Double, y: Double)?, _ d: (x: Double, y: Double)) -> Double {
        guard let c else { return .infinity }
        return hypot(c.x - d.x, c.y - d.y)
    }

    /// Mean of shoulders and hips (indices 11, 12, 23, 24).
    static func torsoCentre(_ pose: [Landmark]) -> (x: Double, y: Double)? {
        let pts = [11, 12, 23, 24].compactMap { pose.indices.contains($0) ? pose[$0].position : nil }
        guard !pts.isEmpty else { return nil }
        return (pts.map(\.x).reduce(0, +) / Double(pts.count), pts.map(\.y).reduce(0, +) / Double(pts.count))
    }

    static func torsoSize(_ pose: [Landmark]) -> Double {
        guard pose.count > 24 else { return 0 }
        let sh = (pose[11].position + pose[12].position) * 0.5
        let hip = (pose[23].position + pose[24].position) * 0.5
        return hypot(sh.x - hip.x, sh.y - hip.y)
    }
}
