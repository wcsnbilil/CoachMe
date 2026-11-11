import Foundation

/// What the beta report draws: the downswing hand path, the address line and
/// the pro range band around it, all in video pixels.
public struct PathEvidence: Sendable, Codable, Equatable {
    public struct Point: Sendable, Codable, Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public var verdict: SwingPathAnalyzer.Verdict
    public var refusal: SwingPathAnalyzer.Refusal?
    public var offset: Double?
    /// +1 right-handed, -1 left-handed.
    public var side: Int?
    public var imageWidth: Double
    public var imageHeight: Double
    /// Hands from top to impact (finite points only).
    public var downswing: [Point]
    /// Address hands -> shoulders.
    public var referenceLine: [Point]
    public var torsoPixels: Double?
    public var calibration: SwingPathAnalyzer.Calibration
    /// Seconds into the video of the frame to draw on (mid-downswing).
    public var evidenceSeconds: Double?
    /// How sure the report sounds; nil when refused or on records saved before it existed.
    public var confidence: SwingPathAnalyzer.Confidence?

    public init(verdict: SwingPathAnalyzer.Verdict, refusal: SwingPathAnalyzer.Refusal?, offset: Double?, side: Int?,
                imageWidth: Double, imageHeight: Double, downswing: [Point], referenceLine: [Point],
                torsoPixels: Double?, calibration: SwingPathAnalyzer.Calibration = .golfDB, evidenceSeconds: Double?,
                confidence: SwingPathAnalyzer.Confidence? = nil) {
        self.confidence = confidence
        self.verdict = verdict; self.refusal = refusal; self.offset = offset; self.side = side
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
        self.downswing = downswing; self.referenceLine = referenceLine
        self.torsoPixels = torsoPixels; self.calibration = calibration; self.evidenceSeconds = evidenceSeconds
    }

    /// No address/top/impact found.
    public static func swingNotFound(imageWidth: Double, imageHeight: Double) -> PathEvidence {
        PathEvidence(verdict: .cannotJudge, refusal: nil, offset: nil, side: nil, imageWidth: imageWidth,
                     imageHeight: imageHeight, downswing: [], referenceLine: [], torsoPixels: nil, evidenceSeconds: nil)
    }

    /// `frameSeconds[i]` is the timestamp of landmark frame i.
    public init(result r: SwingPathAnalyzer.Result, top: Int, impact: Int, frameSeconds: [Double],
                imageWidth: Double, imageHeight: Double, calibration: SwingPathAnalyzer.Calibration = .golfDB) {
        var down: [Point] = []
        if top >= 0, impact < r.hands.count, top <= impact {
            for p in r.hands[top...impact] where p.x.isFinite && p.y.isFinite { down.append(Point(x: p.x, y: p.y)) }
        }
        let mid = (top + impact) / 2
        self.init(verdict: r.verdict, refusal: r.refusal, offset: r.offset, side: r.side,
                  imageWidth: imageWidth, imageHeight: imageHeight, downswing: down,
                  referenceLine: r.referenceLine.map { Point(x: $0.x, y: $0.y) },
                  torsoPixels: r.torsoPixels, calibration: calibration,
                  evidenceSeconds: frameSeconds.indices.contains(mid) ? frameSeconds[mid] : nil,
                  confidence: r.confidence)
    }

    public var isJudged: Bool { verdict != .cannotJudge }

    /// A soft state: the report shows the note instead of a practice tip.
    public var isSoft: Bool { confidence?.isSoft ?? false }

    /// For near_boundary: true when the offset is nearer the over-the-top threshold than the inside one.
    public var nearOutside: Bool {
        guard let offset else { return true }
        return abs(offset - calibration.outside) <= abs(offset - calibration.inside)
    }

    /// x of the address line at image row y.
    public func referenceX(atY y: Double) -> Double? {
        guard referenceLine.count == 2 else { return nil }
        let a = referenceLine[0], b = referenceLine[1]
        guard abs(b.y - a.y) > 1e-9 else { return nil }
        return a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
    }

    /// The pro range band as two polylines (inside edge, outside edge), spanning
    /// from the address hands up to the highest downswing point.
    public func rangeBand(steps: Int = 12) -> (inside: [Point], outside: [Point])? {
        guard let torso = torsoPixels, torso > 0, let side, referenceLine.count == 2 else { return nil }
        let yBottom = referenceLine[0].y
        let yTop = min(downswing.map(\.y).min() ?? referenceLine[1].y, referenceLine[1].y)
        guard yBottom > yTop else { return nil }
        var inside: [Point] = [], outside: [Point] = []
        for i in 0...steps {
            let y = yBottom - (yBottom - yTop) * Double(i) / Double(steps)
            guard let x = referenceX(atY: y) else { return nil }
            inside.append(Point(x: x + calibration.inside * Double(side) * torso, y: y))
            outside.append(Point(x: x + calibration.outside * Double(side) * torso, y: y))
        }
        return (inside, outside)
    }
}
