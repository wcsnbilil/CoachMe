import Foundation

/// Cuts a long clip into single swings from the hands' height alone, so SwingNet and the path
/// check can run on one swing at a time. Line-by-line port of tools/split/swing_split.py; CI
/// compares both on tools/split/make_split_parity.py cases (SwingSplitParityTests).
///
/// A clip with 0 or 1 swings found is analysed whole, exactly as before.
public struct SwingSplitter: Sendable {

    public struct Swing: Equatable, Sendable, Codable {
        public var address: Int
        public var top: Int
        public var impact: Int
        public init(address: Int, top: Int, impact: Int) {
            self.address = address; self.top = top; self.impact = impact
        }
    }

    /// [start, end) frame window around one swing.
    public struct Window: Equatable, Sendable, Codable {
        public var start: Int
        public var end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
    }

    // Same names and values as swing_split.py (lengths in torso units).
    public static let minVisibility = 0.5
    public static let topBelow = 0.1
    public static let addressStill = 0.05
    public static let addressMax = 0.1
    public static let impactTolerance = 0.45
    public static let impactX = 0.6
    public static let downRatio = 0.9
    public static let minBack = 4
    public static let restSeconds = 1.0
    public static let padBeforeSeconds = 1.0
    public static let padAfterSeconds = 1.5

    static let lw = 15, rw = 16, ls = 11, rs = 12, lh = 23, rh = 24

    public init() {}

    // MARK: - App entry

    /// From cached pose frames; landmarks are scaled to pixels like SwingPathAnalyzer.
    public func findSwings(frames: [PoseFrame], imageWidth: Double, imageHeight: Double) -> [Swing] {
        findSwings(landmarks: Self.points(frames: frames, imageWidth: imageWidth, imageHeight: imageHeight),
                   fps: Self.frameRate(frames))
    }

    static func points(frames: [PoseFrame], imageWidth: Double, imageHeight: Double) -> [[SwingPathAnalyzer.PathPoint]] {
        frames.map { frame in
            (0..<33).map { i in
                guard frame.imageLandmarks.indices.contains(i) else { return .missing }
                let l = frame.imageLandmarks[i]
                return SwingPathAnalyzer.PathPoint(x: l.position.x * imageWidth, y: l.position.y * imageHeight,
                                                   visibility: l.visibility ?? 1)
            }
        }
    }

    /// 1 / median frame step; 30 when the timestamps say nothing.
    public static func frameRate(_ frames: [PoseFrame]) -> Double {
        let steps = zip(frames.dropFirst(), frames).map { $0.timestampSeconds - $1.timestampSeconds }.filter { $0 > 0 }
        guard let step = median(steps), step > 0 else { return 30 }
        return 1 / step
    }

    // MARK: - Core (same input as swing_split.find_swings)

    /// landmarks: [frames][33] pixel points. Returns swings in time order.
    public func findSwings(landmarks lm: [[SwingPathAnalyzer.PathPoint]], fps: Double) -> [Swing] {
        let n = lm.count
        guard n >= 10 else { return [] }
        let hands = Self.mean2(lm, Self.lw, Self.rw, vis: 0)
        let sh = Self.mean2(lm, Self.ls, Self.rs, vis: Self.minVisibility)
        let hip = Self.mean2(lm, Self.lh, Self.rh, vis: Self.minVisibility)
        let d = zip(sh, hip).map { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) }.filter(\.isFinite)
        guard let torso = Self.median(d), torso >= 10,
              hands.contains(where: { $0.y.isFinite }), sh.contains(where: { $0.y.isFinite }),
              hip.contains(where: { $0.y.isFinite }) else { return [] }

        let r = max(1, Int(Self.pyRound(fps / 30)))
        let hy = Self.smooth(hands.map(\.y), 3 * r), hx = Self.smooth(hands.map(\.x), 3 * r)
        let shy = Self.smooth(sh.map(\.y), 9 * r), hipy = Self.smooth(hip.map(\.y), 9 * r)
        let win = 5 * r, minBack = Self.minBack * r
        func high(_ i: Int) -> Bool { hy[i] < shy[i] + Self.topBelow * torso }

        var out: [Swing] = []
        var i = 1
        while i < n - 1 {
            guard high(i), hy[i] <= Self.nanMin(hy[max(0, i - win)..<min(n, i + win + 1)]) else { i += 1; continue }
            var j = i
            while j < n && high(j) { j += 1 }
            let top = i + Self.argmin(hy[i..<j])
            let lo = out.last.map { $0.impact + Int(Self.pyRound(Self.restSeconds * fps)) } ?? 0
            if top - lo < minBack + 2 { i = top + 1; continue }
            let jlow = lo + Self.argmax(hy[lo..<top])
            let level = hy[jlow]
            let ad = (jlow..<top).last { hy[$0] >= level - Self.addressStill * torso } ?? jlow
            let back = top - ad
            if back < minBack || !(hy[ad] > hipy[ad] - Self.addressMax * torso) { i = top + 1; continue }
            var k = top + 1
            let limit = top + Int(Self.downRatio * Double(back)) + 1
            while k < n && k <= limit && hy[k] < hy[ad] - Self.impactTolerance * torso { k += 1 }
            if k >= n || k > limit || abs(hx[k] - hx[ad]) > Self.impactX * torso { i = top + 1; continue }
            // impact = hands' lowest point before they rise again for the finish
            var m = k
            let cap = max(3 * r, (k - top) / 2)
            while m + 1 < n && !high(m + 1) && m - k < cap { m += 1 }
            let impact = top + Self.argmax(hy[top...m])
            out.append(Swing(address: ad, top: top, impact: impact))
            i = max(impact, j) + 1
        }
        return out
    }

    /// Windows to analyse one by one; empty when the clip should be analysed whole (< 2 swings).
    public static func windows(_ swings: [Swing], frameCount n: Int, fps: Double) -> [Window] {
        guard swings.count >= 2 else { return [] }
        let pre = Int(pyRound(padBeforeSeconds * fps)), post = Int(pyRound(padAfterSeconds * fps))
        return swings.indices.map { idx in
            var start = max(0, swings[idx].address - pre)
            var end = min(n, swings[idx].impact + post + 1)
            if idx > 0 { start = max(start, swings[idx - 1].impact + 1) }
            if idx + 1 < swings.count { end = min(end, swings[idx + 1].address) }
            return Window(start: start, end: end)
        }
    }

    // MARK: - numpy equivalents

    static func pyRound(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }

    static func mean2(_ lm: [[SwingPathAnalyzer.PathPoint]], _ a: Int, _ b: Int, vis: Double) -> [(x: Double, y: Double)] {
        lm.map { frame in
            var sx = 0.0, sy = 0.0, c = 0.0
            for j in [a, b] where frame.indices.contains(j) {
                let p = frame[j]
                if p.visibility >= vis && p.x.isFinite { sx += p.x; sy += p.y; c += 1 }
            }
            return c > 0 ? (sx / c, sy / c) : (.nan, .nan)
        }
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Gaps filled linearly (edges held, like np.interp), then a centred box filter of odd width.
    static func smooth(_ input: [Double], _ k: Int) -> [Double] {
        var v = input
        let ok = v.indices.filter { v[$0].isFinite }
        if ok.count >= 2 {
            var p = 0
            for i in v.indices where !v[i].isFinite {
                if i < ok[0] { v[i] = v[ok[0]]; continue }
                if i > ok[ok.count - 1] { v[i] = v[ok[ok.count - 1]]; continue }
                while ok[p + 1] < i { p += 1 }
                let a = ok[p], b = ok[p + 1]
                v[i] = v[a] + (v[b] - v[a]) * Double(i - a) / Double(b - a)
            }
        }
        let k = max(1, k | 1), h = k / 2, n = v.count
        guard n > 0 else { return v }
        return (0..<n).map { i in
            var s = 0.0
            for t in (i - h)...(i + h) { s += v[min(max(t, 0), n - 1)] }
            return s / Double(k)
        }
    }

    static func nanMin(_ s: ArraySlice<Double>) -> Double {
        var m = Double.infinity
        for x in s { if x.isNaN { return .nan }; m = min(m, x) }
        return m
    }

    /// First index of the minimum (first NaN wins, like numpy).
    static func argmin(_ s: ArraySlice<Double>) -> Int {
        var best = s.startIndex
        for i in s.indices {
            if s[i].isNaN { return i - s.startIndex }
            if s[i] < s[best] { best = i }
        }
        return best - s.startIndex
    }

    static func argmax(_ s: ArraySlice<Double>) -> Int {
        var best = s.startIndex
        for i in s.indices {
            if s[i].isNaN { return i - s.startIndex }
            if s[i] > s[best] { best = i }
        }
        return best - s.startIndex
    }
}
