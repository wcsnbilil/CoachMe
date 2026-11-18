import Foundation

/// Zero-phase smoothing of the 3D (world) landmarks, for the 3D replay only.
///
/// Same local-linear kernel as `PoseDisplaySmoother`, in metres. Metrics never see
/// it: they keep reading `AnalysisCache.smoothedFrames()`.
///
/// Measured on 160 GolfDB / HD pro swings with MediaPipe world landmarks (2026-11-08,
/// coachme-bench winrun/w3d_ll.py): hand jitter fell by about half (DTL 35 to 17 mm,
/// face-on 65 to 25 mm per frame), and the shoulder-turn difference between the
/// real-time and slow-motion copy of the same swing fell from p90 39 deg to 20 deg.
/// The hands at impact moved 2 cm (median). It does not fix depth: the same pros
/// still show 40 deg of shoulder turn filmed face-on against 90 deg filmed down the
/// line, which is why the 3D replay stays at the original camera angle.
public struct WorldDisplaySmoother {
    /// Kernel width in time (seconds) and in space (metres). A neighbour farther away
    /// than about `spatialSigma` gets little weight, so a fast downswing is not dragged.
    public var timeSigma = 0.045
    public var spatialSigma = 0.15
    public var window = 0.10

    public init() {}

    public func smooth(_ frames: [PoseFrame]) -> [PoseFrame] {
        guard frames.count > 2 else { return frames }
        var segments = [Int](repeating: 0, count: frames.count)
        for i in frames.indices.dropFirst() {
            let dt = frames[i].timestampSeconds - frames[i-1].timestampSeconds
            let broken = dt <= 0 || dt > 0.2 || frames[i].detectedPersonCount != 1 || frames[i-1].detectedPersonCount != 1
                || frames[i].worldLandmarks == nil || frames[i-1].worldLandmarks == nil
            segments[i] = segments[i-1] + (broken ? 1 : 0)
        }
        func usable(_ mark: Landmark) -> Bool {
            let p = mark.position
            return p.x.isFinite && p.y.isFinite && p.z.isFinite && (mark.presence ?? 1) >= 0.5
                && ((mark.visibility ?? 1) >= 0.5 || (mark.visibility == 0 && mark.presence == 1))
        }
        return frames.indices.map { i in
            let frame = frames[i]
            guard frame.detectedPersonCount == 1, let world = frame.worldLandmarks else { return frame }
            var lower = i, upper = i
            while lower > 0 && segments[lower-1] == segments[i] && frame.timestampSeconds - frames[lower-1].timestampSeconds <= window { lower -= 1 }
            while upper+1 < frames.count && segments[upper+1] == segments[i] && frames[upper+1].timestampSeconds - frame.timestampSeconds <= window { upper += 1 }
            let marks = world.enumerated().map { j, mark -> Landmark in
                guard usable(mark) else { return mark }
                var w0 = 0.0, w1 = 0.0, w2 = 0.0
                var p0 = Vector3.zero, p1 = Vector3.zero
                for k in lower...upper {
                    guard let other = frames[k].worldLandmarks, other.indices.contains(j), usable(other[j]) else { continue }
                    let dt = frames[k].timestampSeconds - frame.timestampSeconds
                    let delta = other[j].position - mark.position
                    let spatial = (delta.x*delta.x + delta.y*delta.y + delta.z*delta.z) / (spatialSigma*spatialSigma)
                    let w = exp(-0.5 * (dt*dt / (timeSigma*timeSigma) + spatial))
                    w0 += w; w1 += w*dt; w2 += w*dt*dt
                    p0 = p0 + other[j].position*w; p1 = p1 + other[j].position*(w*dt)
                }
                let determinant = w0*w2 - w1*w1
                guard determinant > 1e-10 else { return mark }
                let p = (p0*w2 - p1*w1) / determinant
                return Landmark(position: p, visibility: mark.visibility, presence: mark.presence)
            }
            return PoseFrame(timestampSeconds: frame.timestampSeconds, imageLandmarks: frame.imageLandmarks,
                             worldLandmarks: marks, detectedPersonCount: frame.detectedPersonCount)
        }
    }
}
