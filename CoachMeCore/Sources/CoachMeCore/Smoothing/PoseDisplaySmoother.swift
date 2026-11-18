import Foundation

/// Symmetric, motion-aware image smoothing for playback only. World coordinates,
/// confidence, timestamps and the measurement cache remain unchanged.
public struct PoseDisplaySmoother {
    public init() {}

    public func smooth(_ frames: [PoseFrame]) -> [PoseFrame] {
        guard frames.count > 2 else { return frames }
        var segments = [Int](repeating: 0, count: frames.count)
        for i in frames.indices.dropFirst() {
            let dt = frames[i].timestampSeconds - frames[i-1].timestampSeconds
            segments[i] = segments[i-1] + ((dt <= 0 || dt > 0.2 || frames[i].detectedPersonCount != 1 || frames[i-1].detectedPersonCount != 1) ? 1 : 0)
        }
        func usable(_ mark: Landmark) -> Bool {
            let p = mark.position
            return p.x.isFinite && p.y.isFinite && p.z.isFinite && (mark.presence ?? 1) >= 0.5
                && ((mark.visibility ?? 1) >= 0.5 || (mark.visibility == 0 && mark.presence == 1))
        }
        return frames.indices.map { i in
            let frame = frames[i]
            guard frame.detectedPersonCount == 1 else { return frame }
            var lower = i, upper = i
            while lower > 0 && segments[lower-1] == segments[i] && frame.timestampSeconds - frames[lower-1].timestampSeconds <= 0.10 { lower -= 1 }
            while upper+1 < frames.count && segments[upper+1] == segments[i] && frames[upper+1].timestampSeconds - frame.timestampSeconds <= 0.10 { upper += 1 }
            let marks = frame.imageLandmarks.enumerated().map { j, mark -> Landmark in
                guard usable(mark) else { return mark }
                var w0 = 0.0, w1 = 0.0, w2 = 0.0
                var p0 = Vector3.zero, p1 = Vector3.zero
                for k in lower...upper {
                    guard frames[k].imageLandmarks.indices.contains(j) else { continue }
                    let other = frames[k].imageLandmarks[j]
                    guard usable(other) else { continue }
                    let dt = frames[k].timestampSeconds - frame.timestampSeconds
                    let delta = other.position - mark.position
                    // Distant positions get little influence, keeping fast hands responsive.
                    let spatial = (delta.x*delta.x + delta.y*delta.y) / (0.045*0.045)
                    let w = exp(-0.5 * (dt*dt / (0.045*0.045) + spatial))
                    w0 += w; w1 += w*dt; w2 += w*dt*dt
                    p0 = p0 + other.position*w; p1 = p1 + other.position*(w*dt)
                }
                let determinant = w0*w2 - w1*w1
                guard determinant > 1e-10 else { return mark }
                // Local linear fit evaluated at the original timestamp. Unlike a causal
                // low-pass this preserves constant-speed motion, including clip boundaries.
                let p = (p0*w2 - p1*w1) / determinant
                return Landmark(position: p, visibility: mark.visibility, presence: mark.presence)
            }
            return PoseFrame(timestampSeconds: frame.timestampSeconds, imageLandmarks: marks,
                             worldLandmarks: frame.worldLandmarks, detectedPersonCount: frame.detectedPersonCount)
        }
    }
}
