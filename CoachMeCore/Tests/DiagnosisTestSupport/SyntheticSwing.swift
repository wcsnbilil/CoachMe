import Foundation
import Diagnosis

public enum SyntheticSwing {
    public typealias P = SwingPathAnalyzer.PathPoint

    /// Right-handed DTL swing in pixels: torso 100 px, ball at larger x. `loop`
    /// bends the downswing toward the ball, `takeaway` bends the backswing.
    public static func make(loop: Double = 0, frames: Int = 60, lefty: Bool = false, wristGap: Double = 0.1,
                            shoulderWidth: Double = 0.15, takeaway: Double = 0,
                            noise: Double = 0, seed: UInt64 = 1) -> ([[P]], Int, Int, Int) {
        var rng = SplitMix(seed: seed)
        let address = Int(Double(frames) * 0.1), top = Int(Double(frames) * 0.6), impact = Int(Double(frames) * 0.85)
        let hip = (200.0, 300.0), torso = 100.0
        let sh = (hip.0 + 30, hip.1 - torso * 0.95)
        let off = shoulderWidth * torso / 2
        let addr = (260.0, 330.0), topH = (180.0, 130.0)
        var out: [[P]] = []
        for f in 0..<frames {
            var hx: Double, hy: Double
            if f <= address {
                (hx, hy) = addr
            } else if f <= top {
                let t = Double(f - address) / Double(top - address)
                hx = addr.0 + (topH.0 - addr.0) * t + takeaway * torso * sin(.pi * t)
                hy = addr.1 + (topH.1 - addr.1) * t
            } else {
                let t = min(1, Double(f - top) / Double(impact - top))
                hx = topH.0 + (addr.0 - topH.0) * t + loop * torso * sin(.pi * t)
                hy = topH.1 + (addr.1 - topH.1) * t
            }
            if noise > 0 { hx += rng.gaussian() * noise; hy += rng.gaussian() * noise }
            var pts = Array(repeating: P(x: 0, y: 0), count: 33)
            pts[23] = P(x: hip.0 - off * 0.8, y: hip.1); pts[24] = P(x: hip.0 + off * 0.8, y: hip.1)
            pts[11] = P(x: sh.0 - off, y: sh.1); pts[12] = P(x: sh.0 + off, y: sh.1)
            pts[0] = P(x: sh.0 + 40, y: sh.1 - 30)
            let half = wristGap * torso / 2
            pts[15] = P(x: hx - half, y: hy); pts[16] = P(x: hx + half, y: hy)
            if lefty { pts = pts.map { P(x: 400 - $0.x, y: $0.y, visibility: $0.visibility) } }
            out.append(pts)
        }
        return (out, address, top, impact)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    mutating func gaussian() -> Double {
        let u = max(next(), 1e-12), v = next()
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
}
