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
        case trackingJumps           // 关键点跳动太多
        case downswingGap            // 下杆有一段双手追踪丢失或乱跳

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
            case .trackingJumps:          return "关键点跳动太多，无法可靠判断，请换一段光线好、人物完整的视频"
            case .downswingGap:           return "下杆有一段双手追踪丢失或乱跳，无法可靠判断"
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
        /// Frames between address and impact whose hands were seen but dropped
        /// as a tracking jump (whole pose moved, beyond arm's reach, or a
        /// jump-and-return in the hand path).
        public var jumpFrames: Int = 0

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
    /// Which address the camera check and the reference line use (path_fault address_mode).
    public enum AddressMode: String, Sendable, Codable {
        /// SwingNet's address walked back to a still frame (stillAddress), for both.
        case still
        /// Camera check at stillBodyAddress, reference line as `still`.
        case camera
        /// Camera check and reference line at stillBodyAddress.
        case both
    }
    public var addressMode: AddressMode
    /// stillBodyAddress: every tracked joint within this (torso lengths) over the window.
    static let addressStill = 0.03

    /// Off by default: on GolfDB near-vertical lines are normal address postures.
    public var minReferenceAngleDegrees: Double
    /// Wrists further apart than this (torso lengths) are not both on the grip.
    public var maxWristGap: Double

    // Tracking-jump guards, same values as path_fault.py (see there for why).
    static let maxHipShift = 0.5
    static let maxReach = 1.8
    static let despikeFloor = 0.25
    static let maxJumpFrames = 4
    static let maxDownswingGap = 0.25
    /// A gap this short is always filled, however short the downswing (path_fault.MIN_FILLED_GAP).
    static let minFilledGap = 3.0

    public init(calibration: Calibration = .golfDB,
                minVisibility: Double = 0.5,
                maxLineWidth: Double = 0.2,
                minReferenceAngleDegrees: Double = 0,
                maxWristGap: Double = 0.6,
                refineAddress: Bool = true,
                addressMode: AddressMode = .still) {
        self.refineAddress = refineAddress
        self.addressMode = addressMode
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
        let k = Self.oddWindow(Double(impact - address) / 20)
        let h = max(2, k / 2)

        // Address pose = per-joint median of a few frames, so one jumped frame
        // cannot move the reference line, the torso length or the camera check.
        func anchors(_ f: Int) -> (body: [(Double, Double)], sh: (Double, Double), hip: (Double, Double), torso: Double) {
            let body = Self.bodyAt(lm, frame: f, lo: 0, hi: top - 1, half: h)
            let sh = Self.nanMean2(body[J.lSh], body[J.rSh])
            let hip = Self.nanMean2(body[J.lHip], body[J.rHip])
            return (body, sh, hip, hypot(sh.0 - hip.0, sh.1 - hip.1))
        }
        var (body, shMid, hipMid, torso) = anchors(address)
        guard torso.isFinite, torso >= 1 else { return .refused(.torsoNotVisible) }

        // Wrist midpoint per frame. A clean left/right label swap does not move it;
        // a wrist landing elsewhere (often the elbow) shows up as a wide gap.
        var raw: [(Double, Double)] = lm.indices.map { f in
            let l = xy(f, J.lWr), r = xy(f, J.rWr)
            let mid = Self.nanMean2(l, r)
            let gap = hypot(l.0 - r.0, l.1 - r.1)
            return gap > maxWristGap * torso ? (.nan, .nan) : mid
        }
        func known(_ p: (Double, Double)) -> Bool { p.0.isFinite && p.1.isFinite }
        let span = address...impact
        let visible = Double(raw[span].filter(known).count) / Double(span.count)
        guard visible >= 0.7 else { return .refused(.wristsNotVisible) }

        let seen = raw.map(known)
        for f in Self.poseGlitches(lm, hands: raw, address: address, impact: impact, torso: torso) { raw[f] = (.nan, .nan) }
        raw = Self.despike(raw, torso: torso)
        let ok = raw.map(known)
        let jumped = span.filter { seen[$0] && !ok[$0] }.count
        if Double(span.filter { ok[$0] }.count) / Double(span.count) < 0.7 {
            var r = Result.refused(.trackingJumps); r.jumpFrames = jumped; return r
        }
        if Double(Self.longestGap(Array(ok[top...impact]))) > max(Self.minFilledGap, Self.maxDownswingGap * Double(impact - top)) {
            var r = Result.refused(.downswingGap); r.jumpFrames = jumped; return r
        }

        let xs = Self.smooth(raw.map(\.0), k: k)
        let ys = Self.smooth(raw.map(\.1), k: k)

        if refineAddress {
            let still = Self.stillAddress(xs, ys, address: address, top: top)
            let a2 = anchors(still)
            if a2.torso.isFinite, a2.torso >= 1 {
                address = still; body = a2.body; shMid = a2.sh; hipMid = a2.hip; torso = a2.torso
            }
        }

        var camBody = body, camTorso = torso
        if addressMode != .still {
            let tracks = [(xs, ys)] + [J.lSh, J.rSh].map { j in
                (Self.smooth(lm.map { $0.indices.contains(j) ? $0[j].x : .nan }, k: k),
                 Self.smooth(lm.map { $0.indices.contains(j) ? $0[j].y : .nan }, k: k))
            }
            if let ha = Self.stillBodyAddress(tracks, address: givenAddress, top: top, torso: torso), ha < top {
                let a3 = anchors(ha)
                if a3.torso.isFinite, a3.torso >= 1 {
                    camBody = a3.body; camTorso = a3.torso
                    if addressMode == .both {
                        address = ha; body = a3.body; shMid = a3.sh; hipMid = a3.hip; torso = a3.torso
                    }
                }
            }
        }

        let shoulderWidth = abs(camBody[J.lSh].0 - camBody[J.rSh].0) / camTorso
        let hipWidth = abs(camBody[J.lHip].0 - camBody[J.rHip].0) / camTorso
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
            Self.sign(body[J.nose].0 - hipMid.0),
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
                      addressFrame: address, jumpFrames: jumped)
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

    /// hands_still_address: walking back from where the hands are last below half of the backswing
    /// height, the first frame f (after at least one frame that was not still) where the hands and
    /// both shoulders all stay within addressStill torso lengths of where they are at f over
    /// f-s...f, s = max(3, (top - f) / 3) clipped at the search start. The search goes back at most
    /// as far before the given address as it is before the top. tracks[0] = hands.
    static func stillBodyAddress(_ tracks: [([Double], [Double])], address: Int, top: Int, torso: Double) -> Int? {
        let lo = max(0, address - (top - address))
        let hy = tracks[0].1
        guard hy[address].isFinite, hy[top].isFinite else { return nil }
        let half = hy[top] + 0.5 * (hy[address] - hy[top])
        guard let start = (lo..<top).last(where: { hy[$0].isFinite && hy[$0] >= half }) else { return nil }
        var moved = false
        for f in stride(from: start, through: lo, by: -1) {
            let s = min(max(3, (top - f) / 3), f - lo)
            if s < 2 { break }
            var still = true, seen = false
            for (tx, ty) in tracks {
                guard tx[f].isFinite, ty[f].isFinite else { continue }
                seen = true
                let d = (f - s...f).map { hypot(tx[$0] - tx[f], ty[$0] - ty[f]) }.filter(\.isFinite)
                if let m = d.max(), m > addressStill * torso { still = false; break }
            }
            if !still { moved = true } else if seen && moved { return f }
        }
        return nil
    }

    /// body_at: per-joint nanmedian of frames f-half...f+half, kept inside lo...hi.
    static func bodyAt(_ lm: [[PathPoint]], frame f: Int, lo: Int, hi: Int, half: Int) -> [(Double, Double)] {
        let frames = max(lo, f - half)...max(max(lo, f - half), min(hi, f + half))
        return (0..<33).map { j in
            let pts = frames.compactMap { lm[$0].indices.contains(j) ? lm[$0][j] : nil }
            return (median(pts.map(\.x).filter(\.isFinite)), median(pts.map(\.y).filter(\.isFinite)))
        }
    }

    /// pose_glitches: frames whose hips are far from their usual place, or whose
    /// hands are beyond arm's reach of the shoulders.
    static func poseGlitches(_ lm: [[PathPoint]], hands: [(Double, Double)], address: Int, impact: Int,
                             torso: Double) -> [Int] {
        func mid(_ f: Int, _ a: Int, _ b: Int) -> (Double, Double) {
            func p(_ j: Int) -> (Double, Double) { lm[f].indices.contains(j) ? (lm[f][j].x, lm[f][j].y) : (.nan, .nan) }
            return nanMean2(p(a), p(b))
        }
        let hips = lm.indices.map { mid($0, J.lHip, J.rHip) }
        let span = hips[address...impact]
        let home = (median(span.map(\.0).filter(\.isFinite)), median(span.map(\.1).filter(\.isFinite)))
        return lm.indices.filter { f in
            let sh = mid(f, J.lSh, J.rSh)
            let shift = hypot(hips[f].0 - home.0, hips[f].1 - home.1) / torso
            let reach = hypot(hands[f].0 - sh.0, hands[f].1 - sh.1) / torso
            return shift > maxHipShift || reach > maxReach
        }
    }

    /// despike: drop the frames of a jump-and-return in the hand path. A step far
    /// from the median of the five steps around it starts a jump; a roughly
    /// opposite one within maxJumpFrames ends it.
    static func despike(_ track: [(Double, Double)], torso: Double) -> [(Double, Double)] {
        var out = track
        let n = track.count
        guard n > 1 else { return out }
        var steps = [(Double, Double)](repeating: (.nan, .nan), count: n)
        for i in 1..<n { steps[i] = (track[i].0 - track[i - 1].0, track[i].1 - track[i - 1].1) }
        var dev = [(Double, Double)](repeating: (.nan, .nan), count: n)
        for i in 1..<n where steps[i].0.isFinite && steps[i].1.isFinite {
            let win = steps[max(1, i - 2)...min(n - 1, i + 2)].filter { $0.0.isFinite && $0.1.isFinite }
            if win.count >= 3 {
                dev[i] = (steps[i].0 - median(win.map(\.0)), steps[i].1 - median(win.map(\.1)))
            }
        }
        let size = dev.map { hypot($0.0, $0.1) }
        let finite = size.filter(\.isFinite)
        guard finite.count >= 3 else { return out }
        let limit = max(3 * 1.4826 * median(finite), despikeFloor * torso)
        var i = 1
        while i < n {
            guard size[i] > limit else { i += 1; continue }
            let back = (i + 1..<min(n, i + maxJumpFrames + 1)).first { j in
                size[j] > 0.5 * limit && hypot(dev[i].0 + dev[j].0, dev[i].1 + dev[j].1) < 0.5 * size[i]
            }
            guard let back else { i += 1; continue }
            for f in i..<back { out[f] = (.nan, .nan) }
            i = back + 1
        }
        return out
    }

    static func longestGap(_ ok: [Bool]) -> Int {
        var run = 0, best = 0
        for v in ok { run = v ? 0 : run + 1; best = max(best, run) }
        return best
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
