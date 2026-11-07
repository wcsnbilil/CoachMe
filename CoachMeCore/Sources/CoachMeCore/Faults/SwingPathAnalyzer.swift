import Foundation

/// Over-the-top (外下) / too-inside (内下) check from a down-the-line video.
///
/// Swift port of `tools/faults/path_fault.py` (v3). Keep the two in step: the
/// Python version is where the algorithm is tuned on GolfDB, and
/// `SwingPathParityTests` compares this port against it.
///
/// At address a line is drawn from the hands up through the shoulders. At
/// several hand heights the downswing hands are measured against that line,
/// in torso lengths: `offset > 0` = the hands come down outside it (toward the
/// ball, over the top), `offset < 0` = inside it.
///
/// Pros do not share one path (some come slightly over the top on purpose to
/// fade it), so anything within the range GolfDB tour pros cover is accepted.
/// Only beyond it is reported as a fault.
///
/// This tracks the hands, not the club. It measures the hand path only.
public struct SwingPathAnalyzer: Sendable {

    public struct Calibration: Sendable, Codable, Equatable {
        public var outside: Double
        public var inside: Double
        public var source: String

        public init(outside: Double, inside: Double, source: String) {
            self.outside = outside
            self.inside = inside
            self.source = source
        }

        /// calibrate.py on the first 200 GolfDB down-the-line swings (78 golfers,
        /// coverage 0.98). All 400 give 0.148 / -0.505. Centre is -0.154: pros come
        /// down on the body side of the address line.
        public static let golfDB = Calibration(outside: 0.142, inside: -0.516, source: "golfdb_dtl_first200_v3d")
    }

    public enum Verdict: String, Sendable, Codable {
        case withinProRange      // 路径在职业范围内
        case overTheTop          // 外下过度
        case tooInside           // 内下过度
        case cannotJudge         // 无法判断

        public var nameZH: String {
            switch self {
            case .withinProRange: return "路径在职业范围内"
            case .overTheTop:     return "外下过度"
            case .tooInside:      return "内下过度"
            case .cannotJudge:    return "无法判断"
            }
        }

        /// The usual ball-flight consequence, phrased as a risk, not a fact:
        /// the face decides the start line, so a path alone never proves a slice.
        /// `side` is Result.side: +1 right-handed, -1 left-handed (mirror image).
        public func riskZH(side: Int?) -> String? {
            let lefty = side == -1
            switch self {
            case .overTheTop:
                return lefty ? "下杆从外侧下来，容易出现左曲（slice）或拉右"
                             : "下杆从外侧下来，容易出现右曲（slice）或拉左"
            case .tooInside:
                return lefty ? "下杆过于从内侧下来，容易出现大右曲或推左"
                             : "下杆过于从内侧下来，容易出现大左曲或推右"
            default:
                return nil
            }
        }
    }

    public enum Refusal: String, Sendable, Codable {
        case phaseOrder              // 阶段顺序不对
        case torsoNotVisible         // 准备姿势躯干不可见
        case cameraOffAxis           // 机位偏离目标线（肩/髋线太宽）
        case wristsNotVisible        // 手腕可见帧太少
        case sideUnclear             // 分不清左右手
        case backswingTooSmall       // 上杆幅度太小
        case shouldersNotAboveHands  // 准备姿势肩膀不在双手上方
        case referenceNearVertical   // 参考线接近竖直
        case tooFewDownswingSamples  // 下杆轨迹取不到足够的点

        public var messageZH: String {
            switch self {
            case .phaseOrder:             return "阶段顺序不对"
            case .torsoNotVisible:        return "准备姿势躯干不可见"
            case .cameraOffAxis:          return "机位偏离目标线（肩/髋线太宽），请从球手正后方沿目标线拍摄"
            case .wristsNotVisible:       return "手腕可见帧太少"
            case .sideUnclear:            return "分不清左右手"
            case .backswingTooSmall:      return "上杆幅度太小，可能不是沿目标线机位或阶段不准"
            case .shouldersNotAboveHands: return "准备姿势肩膀不在双手上方"
            case .referenceNearVertical:  return "参考线接近竖直，机位可能偏或俯拍"
            case .tooFewDownswingSamples: return "下杆轨迹在参考高度上取不到足够的点"
            }
        }
    }

    public struct Result: Sendable, Codable, Equatable {
        public var verdict: Verdict
        public var refusal: Refusal?
        /// Downswing hands vs the address line, torso lengths. + = outside.
        public var offset: Double?
        /// Takeaway vs the same line. Very negative = flat, inside takeaway.
        public var backswingOffset: Double?
        /// Downswing minus backswing at the same height (the v2 measure).
        public var loop: Double?
        /// +1 if the ball is at larger image x than the hips.
        public var side: Int?
        public var shoulderWidth: Double?
        public var hipWidth: Double?
        public var referenceAngleDegrees: Double?
        public var cautionZH: [String]
        /// Smoothed hand track in pixels, one point per input frame (NaN where unknown).
        public var hands: [PathPoint]
        /// Address line, hands -> shoulders, in pixels.
        public var referenceLine: [PathPoint]
        /// Frame index actually used as address (after refineAddress).
        public var addressFrame: Int?

        static func refused(_ r: Refusal) -> Result {
            Result(verdict: .cannotJudge, refusal: r, offset: nil, backswingOffset: nil, loop: nil, side: nil,
                   shoulderWidth: nil, hipWidth: nil, referenceAngleDegrees: nil, cautionZH: [], hands: [],
                   referenceLine: [], addressFrame: nil)
        }
    }

    /// A 2D point with the model's visibility score.
    public struct PathPoint: Sendable, Codable, Equatable {
        public var x: Double
        public var y: Double
        public var visibility: Double

        public init(x: Double, y: Double, visibility: Double = 1) {
            self.x = x
            self.y = y
            self.visibility = visibility
        }

        static let missing = PathPoint(x: .nan, y: .nan, visibility: .nan)
    }

    public var calibration: Calibration
    public var minVisibility: Double
    /// Shoulder or hip line wider than this at address (torso lengths) = off-axis camera.
    public var maxLineWidth: Double
    /// Move a late address back to the stillest frame before it (see stillAddress).
    public var refineAddress: Bool
    /// Off by default: on GolfDB near-vertical lines are normal address postures.
    public var minReferenceAngleDegrees: Double
    /// Wrists further apart than this (torso lengths) are not both on the grip.
    public var maxWristGap: Double

    public init(calibration: Calibration = .golfDB,
                minVisibility: Double = 0.5,
                maxLineWidth: Double = 0.2,
                minReferenceAngleDegrees: Double = 0,
                maxWristGap: Double = 0.6,
                refineAddress: Bool = true) {
        self.refineAddress = refineAddress
        self.calibration = calibration
        self.minVisibility = minVisibility
        self.maxLineWidth = maxLineWidth
        self.minReferenceAngleDegrees = minReferenceAngleDegrees
        self.maxWristGap = maxWristGap
    }

    // MARK: - Entry points

    /// From the app's cached pose frames. `imageSize` is the upright video size in
    /// pixels: landmarks are normalised per axis, and the path must be measured in
    /// square pixels or a portrait video would stretch it.
    public func analyze(frames: [PoseFrame], address: Double, top: Double, impact: Double,
                        imageWidth: Double, imageHeight: Double) -> Result {
        guard !frames.isEmpty else { return .refused(.phaseOrder) }
        let points: [[PathPoint]] = frames.map { frame in
            (0..<33).map { i in
                guard frame.imageLandmarks.indices.contains(i) else { return .missing }
                let l = frame.imageLandmarks[i]
                return PathPoint(x: l.position.x * imageWidth, y: l.position.y * imageHeight,
                                 visibility: l.visibility ?? 1)
            }
        }
        func index(_ t: Double) -> Int {
            frames.indices.min { abs(frames[$0].timestampSeconds - t) < abs(frames[$1].timestampSeconds - t) } ?? 0
        }
        return analyze(landmarks: points, address: index(address), top: index(top), impact: index(impact))
    }

    /// landmarks: [frames][33] in pixels, the same input as path_fault.analyze.
    public func analyze(landmarks input: [[PathPoint]], address givenAddress: Int, top: Int, impact: Int) -> Result {
        var address = givenAddress
        guard 0 <= address, address < top, top < impact, impact < input.count else { return .refused(.phaseOrder) }
        let lm: [[PathPoint]] = input.map { frame in
            frame.map { p in (p.visibility >= minVisibility) ? p : .missing }
        }
        func xy(_ f: Int, _ j: Int) -> (Double, Double) {
            guard lm[f].indices.contains(j) else { return (.nan, .nan) }
            return (lm[f][j].x, lm[f][j].y)
        }

        var shMid = Self.nanMean2(xy(address, J.lSh), xy(address, J.rSh))
        var hipMid = Self.nanMean2(xy(address, J.lHip), xy(address, J.rHip))
        var torso = hypot(shMid.0 - hipMid.0, shMid.1 - hipMid.1)
        guard torso.isFinite, torso >= 1 else { return .refused(.torsoNotVisible) }

        // Wrist midpoint per frame. A clean left/right label swap does not move it;
        // a wrist landing elsewhere (often the elbow) shows up as a wide gap.
        let raw: [(Double, Double)] = lm.indices.map { f in
            let l = xy(f, J.lWr), r = xy(f, J.rWr)
            let mid = Self.nanMean2(l, r)
            let gap = hypot(l.0 - r.0, l.1 - r.1)
            return gap > maxWristGap * torso ? (.nan, .nan) : mid
        }
        let span = Array(raw[address...impact])
        let visible = Double(span.filter { $0.0.isFinite && $0.1.isFinite }.count) / Double(span.count)
        guard visible >= 0.7 else { return .refused(.wristsNotVisible) }

        let k = Self.oddWindow(Double(impact - address) / 20)
        let xs = Self.smooth(raw.map(\.0), k: k)
        let ys = Self.smooth(raw.map(\.1), k: k)

        if refineAddress {
            let still = Self.stillAddress(xs, ys, address: address, top: top)
            let sh2 = Self.nanMean2(xy(still, J.lSh), xy(still, J.rSh))
            let hip2 = Self.nanMean2(xy(still, J.lHip), xy(still, J.rHip))
            let t2 = hypot(sh2.0 - hip2.0, sh2.1 - hip2.1)
            if t2.isFinite, t2 >= 1 { address = still; shMid = sh2; hipMid = hip2; torso = t2 }
        }

        let shoulderWidth = abs(xy(address, J.lSh).0 - xy(address, J.rSh).0) / torso
        let hipWidth = abs(xy(address, J.lHip).0 - xy(address, J.rHip).0) / torso
        let widest = [shoulderWidth, hipWidth].filter(\.isFinite).max() ?? .nan
        if widest > maxLineWidth {
            var r = Result.refused(.cameraOffAxis)
            r.shoulderWidth = shoulderWidth; r.hipWidth = hipWidth; r.addressFrame = address
            return r
        }

        // Side: majority of four cues (hands, nose, shoulders vs hips at address;
        // hands move back toward the body at the top).
        let votes = [
            Self.sign(xs[address] - hipMid.0),
            Self.sign(xy(address, J.nose).0 - hipMid.0),
            Self.sign(shMid.0 - hipMid.0),
            Self.sign(xs[address] - xs[top]),
        ]
        let total = votes.reduce(0, +)
        guard total != 0 else { return .refused(.sideUnclear) }
        let side = Double(total > 0 ? 1 : -1)

        let yAddr = ys[address], yTop = ys[top]
        let rise = yAddr - yTop
        guard rise >= 0.5 * torso else { return .refused(.backswingTooSmall) }

        let h0 = (xs[address], ys[address])
        guard shMid.0.isFinite, shMid.1.isFinite, shMid.1 < h0.1 else { return .refused(.shouldersNotAboveHands) }
        let slope = (shMid.0 - h0.0) / (shMid.1 - h0.1)
        let refAngle = atan(abs(slope)) * 180 / .pi
        if refAngle < minReferenceAngleDegrees { return .refused(.referenceNearVertical) }
        func refX(_ level: Double) -> Double { h0.0 + (level - h0.1) * slope }

        let upX = Array(xs[address...top]), upY = Array(ys[address...top])
        let dnX = Array(xs[top...impact]), dnY = Array(ys[top...impact])
        var down: [Double] = [], up: [Double] = [], loop: [Double] = []
        for i in 0..<13 {
            let frac = 0.2 + 0.6 * Double(i) / 12
            let level = yAddr - frac * rise
            let xu = Self.crossings(upX, upY, level: level, rising: true)
            let xd = Self.crossings(dnX, dnY, level: level, rising: false)
            if !xd.isEmpty { down.append((Self.median(xd) - refX(level)) * side / torso) }
            if !xu.isEmpty { up.append((Self.median(xu) - refX(level)) * side / torso) }
            if !xu.isEmpty, !xd.isEmpty { loop.append((Self.median(xd) - Self.median(xu)) * side / torso) }
        }
        guard down.count >= 5 else { return .refused(.tooFewDownswingSamples) }

        let offset = Self.median(down)
        let back: Double? = up.isEmpty ? nil : Self.median(up)
        let verdict: Verdict = offset > calibration.outside ? .overTheTop
            : offset < calibration.inside ? .tooInside : .withinProRange
        var caution: [String] = []
        if verdict != .withinProRange, let back, abs(back) > 0.4, (back > 0) == (offset > 0) {
            caution.append("上下杆整条轨迹都在参考线同一侧，可能是机位或俯拍让参考线偏了")
        }
        return Result(verdict: verdict, refusal: nil, offset: offset, backswingOffset: back,
                      loop: loop.isEmpty ? nil : Self.median(loop), side: Int(side),
                      shoulderWidth: shoulderWidth, hipWidth: hipWidth, referenceAngleDegrees: refAngle,
                      cautionZH: caution,
                      hands: zip(xs, ys).map { PathPoint(x: $0, y: $1) },
                      referenceLine: [PathPoint(x: h0.0, y: h0.1), PathPoint(x: shMid.0, y: shMid.1)],
                      addressFrame: address)
    }

    // MARK: - Helpers (each mirrors a function in path_fault.py)

    enum J {
        static let nose = 0, lSh = 11, rSh = 12, lWr = 15, rWr = 16, lHip = 23, rHip = 24
    }

    static func nanMean2(_ a: (Double, Double), _ b: (Double, Double)) -> (Double, Double) {
        func m(_ u: Double, _ v: Double) -> Double {
            switch (u.isFinite, v.isFinite) {
            case (true, true): return (u + v) / 2
            case (true, false): return u
            case (false, true): return v
            default: return .nan
            }
        }
        return (m(a.0, b.0), m(a.1, b.1))
    }

    /// still_address: walk a late address back to the most recent still frame
    /// (hands slower than 10% of their mean takeaway speed), at most as far back
    /// as the takeaway is long. An address that is already still is kept.
    static func stillAddress(_ xs: [Double], _ ys: [Double], address: Int, top: Int) -> Int {
        func speed(_ f: Int) -> Double { hypot(xs[f + 1] - xs[f], ys[f + 1] - ys[f]) }
        let takeaway = (address..<top).map(speed)
        let still = 0.1 * takeaway.reduce(0, +) / Double(takeaway.count)
        for f in stride(from: address, through: max(0, address - (top - address)), by: -1) where speed(f) <= still {
            return f
        }
        return address
    }

    static func sign(_ v: Double) -> Int { !v.isFinite || v == 0 ? 0 : (v > 0 ? 1 : -1) }

    /// numpy.median: mean of the two middle values for an even count.
    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return .nan }
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// _odd: Python's round() is round-half-to-even.
    static func oddWindow(_ n: Double, lo: Int = 3) -> Int {
        let k = max(lo, Int(n.rounded(.toNearestOrEven)))
        return k % 2 == 1 ? k : k + 1
    }

    /// _hampel: replace points more than 3 scaled MADs from the running median.
    static func hampel(_ col: [Double], k: Int, nSigma: Double = 3) -> [Double] {
        var out = col
        let h = k / 2
        for i in col.indices {
            let win = col[max(0, i - h)...min(col.count - 1, i + h)].filter(\.isFinite)
            guard win.count >= 3, col[i].isFinite else { continue }
            let med = median(win)
            let mad = 1.4826 * median(win.map { abs($0 - med) })
            if mad > 0, abs(col[i] - med) > nSigma * mad { out[i] = med }
        }
        return out
    }

    /// np.interp over NaN gaps: linear inside, flat beyond the ends.
    static func interpolateNaN(_ col: [Double]) -> [Double] {
        let known = col.indices.filter { col[$0].isFinite }
        guard known.count >= 2 else { return col }
        var out = col
        for i in col.indices where !col[i].isFinite {
            if i <= known.first! { out[i] = col[known.first!]; continue }
            if i >= known.last! { out[i] = col[known.last!]; continue }
            let hi = known.first { $0 > i }!
            let lo = known.last { $0 < i }!
            let t = Double(i - lo) / Double(hi - lo)
            out[i] = col[lo] + t * (col[hi] - col[lo])
        }
        return out
    }

    /// _smooth for one coordinate: Hampel, NaN interpolation, k-frame moving average.
    static func smooth(_ col: [Double], k: Int) -> [Double] {
        var c = interpolateNaN(hampel(col, k: k))
        if k > 1, c.count >= k, c.allSatisfy(\.isFinite) {
            let h = k / 2
            let padded = Array(repeating: c.first!, count: h) + c + Array(repeating: c.last!, count: h)
            c = c.indices.map { i in padded[i..<(i + k)].reduce(0, +) / Double(k) }
        }
        return c
    }

    /// _crossings_x: x at every crossing of `level` (image y, smaller = higher).
    static func crossings(_ xs: [Double], _ ys: [Double], level: Double, rising: Bool) -> [Double] {
        var out: [Double] = []
        for i in 1..<max(1, ys.count) {
            let a = ys[i - 1], b = ys[i]
            let hit = rising ? (a > level && level >= b) : (a < level && level <= b)
            if hit {
                let t = b != a ? (level - a) / (b - a) : 0
                out.append(xs[i - 1] + t * (xs[i] - xs[i - 1]))
            }
        }
        return out
    }
}
