import Foundation

/// Retake checks before and during the analysis, with the full analysis's own refusal rules.
/// Line-by-line port of tools/preflight/preflight.py (see there for the reasoning and the GolfDB numbers).
///
/// 1. `quick`: right after import, on `quickSamples` poses sampled across the clip. Only what the full
///    analysis would certainly refuse: too short, nobody, no trunk, plainly not behind the golfer.
/// 2. `earlySetup`: once SwingNet's phases are known and the pose pass has `earlyFrames` frames, the full
///    analysis's set-up refusals (trunk, wrists, jumpy key points, camera off the target line).
public enum Preflight {
    public static let minSeconds = 1.0
    public static let quickSamples = 16
    public static let minPoseShare = 0.5
    public static let minBodyShare = 0.5
    /// Narrowest standing sample wider than this (torso lengths) = not down the line. The full analysis
    /// refuses above SwingPathAnalyzer.maxLineWidth (0.2) at address; this is far above it on purpose.
    public static let quickCameraWidth = 0.45
    static let minVisibility = 0.5
    static let ls = 11, rs = 12, lh = 23, rh = 24, lw = 15, rw = 16

    public enum QuickReason: String, Sendable, Codable {
        case duration, person, body, camera
    }

    public struct QuickResult: Equatable, Sendable {
        public var reason: QuickReason?
        /// Narrowest standing sample's shoulder / hip line width in torso lengths (nil = no standing sample).
        public var width: Double?
        /// Most poses seen in one sample. Reported, never refused (the full analysis does not refuse it).
        public var people: Int
        public var ok: Bool { reason == nil }
    }

    /// Frames the quick layer looks at: evenly spaced, first and last included.
    public static func sampleIndices(frameCount n: Int, count: Int = quickSamples) -> [Int] {
        guard n > count else { return Array(0..<max(0, n)) }
        return (0..<count).map { i in Int(SwingSplitter.pyRound(Double(i * (n - 1)) / Double(count - 1))) }
    }

    /// samples: poses at `sampleIndices`, in pixels (missing joints NaN).
    public static func quick(samples: [[SwingPathAnalyzer.PathPoint]], duration: Double, people: Int = 1) -> QuickResult {
        var out = QuickResult(reason: nil, width: nil, people: people)
        if duration < minSeconds { out.reason = .duration; return out }
        let k = samples.count
        guard k > 0 else { out.reason = .person; return out }
        func point(_ f: Int, _ j: Int) -> SwingPathAnalyzer.PathPoint {
            samples[f].indices.contains(j) ? samples[f][j] : .missing
        }
        func vis(_ f: Int, _ j: Int) -> Bool { point(f, j).visibility >= minVisibility }
        let posed = (0..<k).map { f in (0..<33).contains { point(f, $0).x.isFinite } && (0..<33).contains { vis(f, $0) } }
        let posedCount = posed.filter { $0 }.count
        if Double(posedCount) < minPoseShare * Double(k) { out.reason = .person; return out }
        let trunk = (0..<k).filter { f in posed[f] && (vis(f, ls) || vis(f, rs)) && (vis(f, lh) || vis(f, rh)) }.count
        if Double(trunk) < minBodyShare * Double(posedCount) { out.reason = .body; return out }
        var widths: [Double] = []
        for f in 0..<k where [ls, rs, lh, rh].allSatisfy({ vis(f, $0) }) {
            let p = { (j: Int) in point(f, j) }
            let sh = ((p(ls).x + p(rs).x) / 2, (p(ls).y + p(rs).y) / 2)
            let hip = ((p(lh).x + p(rh).x) / 2, (p(lh).y + p(rh).y) / 2)
            let torso = hypot(sh.0 - hip.0, sh.1 - hip.1)
            let hands = [lw, rw].filter { vis(f, $0) }.map { p($0).y }
            guard torso >= 1, !hands.isEmpty, hands.reduce(0, +) / Double(hands.count) >= hip.1 else { continue }
            widths.append(max(abs(p(ls).x - p(rs).x), abs(p(lh).x - p(rh).x)) / torso)
        }
        if let narrowest = widths.min() {
            out.width = narrowest
            if narrowest > quickCameraWidth { out.reason = .camera }
        }
        return out
    }

    /// App pose frames in pixels, as SwingPathAnalyzer.analyze(frames:) converts them.
    public static func points(_ frames: [PoseFrame], imageWidth: Double, imageHeight: Double) -> [[SwingPathAnalyzer.PathPoint]] {
        frames.map { frame in
            (0..<33).map { i in
                guard frame.imageLandmarks.indices.contains(i) else { return .missing }
                let l = frame.imageLandmarks[i]
                return .init(x: l.position.x * imageWidth, y: l.position.y * imageHeight, visibility: l.visibility ?? 1)
            }
        }
    }

    /// What the beta log and the retake screen show for a quick-layer refusal (nil refusal = no swing found).
    public static func refusal(for reason: QuickReason) -> SwingPathAnalyzer.Refusal? {
        switch reason {
        case .camera: return .cameraOffAxis
        case .body: return .torsoNotVisible
        case .person, .duration: return nil
        }
    }

    /// How many frames from the clip start `earlySetup` needs: the top plus the smoothing margin.
    public static func earlyFrames(address: Int, top: Int, impact: Int) -> Int {
        top + SwingPathAnalyzer.oddWindow(Double(impact - address) / 20) + 3
    }

    /// SwingPathAnalyzer.analyze's refusals up to and including the camera check, on frames
    /// [0, earlyFrames). Frames after the top count as good for the visibility / jump shares. nil = carry on.
    public static func earlySetup(landmarks input: [[SwingPathAnalyzer.PathPoint]], address: Int, top: Int, impact: Int,
                                  analyzer: SwingPathAnalyzer = SwingPathAnalyzer()) -> SwingPathAnalyzer.Refusal? {
        guard 0 <= address, address < top, top < impact else { return .phaseOrder }
        let k = SwingPathAnalyzer.oddWindow(Double(impact - address) / 20)
        let h = max(2, k / 2)
        let seen = min(input.count, earlyFrames(address: address, top: top, impact: impact))
        guard seen > top else { return nil }
        typealias A = SwingPathAnalyzer
        let lm: [[A.PathPoint]] = input[0..<seen].map { frame in
            frame.map { p in (p.visibility >= analyzer.minVisibility) ? p : .missing }
        }
        func anchors(_ f: Int) -> (body: [(Double, Double)], torso: Double) {
            let body = A.bodyAt(lm, frame: f, lo: 0, hi: top - 1, half: h)
            let sh = A.nanMean2(body[A.J.lSh], body[A.J.rSh])
            let hip = A.nanMean2(body[A.J.lHip], body[A.J.rHip])
            return (body, hypot(sh.0 - hip.0, sh.1 - hip.1))
        }
        var (body, torso) = anchors(address)
        guard torso.isFinite, torso >= 1 else { return .torsoNotVisible }
        func xy(_ f: Int, _ j: Int) -> (Double, Double) {
            lm[f].indices.contains(j) ? (lm[f][j].x, lm[f][j].y) : (.nan, .nan)
        }
        var raw: [(Double, Double)] = lm.indices.map { f in
            let l = xy(f, A.J.lWr), r = xy(f, A.J.rWr)
            let gap = hypot(l.0 - r.0, l.1 - r.1)
            return gap > analyzer.maxWristGap * torso ? (.nan, .nan) : A.nanMean2(l, r)
        }
        func known(_ p: (Double, Double)) -> Bool { p.0.isFinite && p.1.isFinite }
        let span = Double(impact - address + 1), rest = Double(impact - top)
        func share() -> Double { (Double((address...top).filter { known(raw[$0]) }.count) + rest) / span }
        if share() < 0.7 { return .wristsNotVisible }
        for f in A.poseGlitches(lm, hands: raw, address: address, impact: min(impact, seen - 1), torso: torso) {
            raw[f] = (.nan, .nan)
        }
        raw = A.despike(raw, torso: torso)
        if share() < 0.7 { return .trackingJumps }
        let xs = A.smooth(raw.map(\.0), k: k), ys = A.smooth(raw.map(\.1), k: k)
        let still = A.stillAddress(xs, ys, address: address, top: top)
        let a2 = anchors(still)
        if a2.torso.isFinite, a2.torso >= 1 { body = a2.body; torso = a2.torso }
        let widths = [abs(body[A.J.lSh].0 - body[A.J.rSh].0) / torso, abs(body[A.J.lHip].0 - body[A.J.rHip].0) / torso]
        let widest = widths.filter(\.isFinite).max() ?? .nan
        // Same cut as the full analysis: just past the limit is judged with "camera slightly off", not refused.
        return widest > analyzer.maxLineWidth * (1 + SwingPathAnalyzer.lowCameraMargin) ? .cameraOffAxis : nil
    }
}
