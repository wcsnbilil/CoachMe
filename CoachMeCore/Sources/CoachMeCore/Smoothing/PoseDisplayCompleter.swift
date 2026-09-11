import Foundation

/// Display-only reconstruction. Never use these frames for measurements or save
/// them as detector output. Synthetic points carry visibility=0, presence=1.
public struct PoseDisplayCompleter {
    public var minVisibility: Double
    public init(minVisibility: Double = 0.5) { self.minVisibility = minVisibility }

    private static let bones: [(PoseJoint, PoseJoint)] = [
        (.leftHip, .leftShoulder), (.rightHip, .rightShoulder),
        (.leftShoulder, .leftElbow), (.rightShoulder, .rightElbow),
        (.leftElbow, .leftWrist), (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee), (.rightHip, .rightKnee),
        (.leftKnee, .leftAnkle), (.rightKnee, .rightAnkle),
        (.leftAnkle, .leftHeel), (.rightAnkle, .rightHeel),
        (.leftAnkle, .leftFootIndex), (.rightAnkle, .rightFootIndex)
    ]

    public func complete(_ frames: [PoseFrame], keyframes: [Keyframe] = []) -> [PoseFrame] {
        guard !frames.isEmpty else { return [] }
        // Never borrow across a multi-person frame or a long decoder gap.
        var segments = Array(repeating: 0, count: frames.count)
        for i in frames.indices.dropFirst() {
            let broken = frames[i].detectedPersonCount > 1 || frames[i-1].detectedPersonCount > 1
                || frames[i].timestampSeconds - frames[i-1].timestampSeconds > 0.3
            segments[i] = segments[i-1] + (broken ? 1 : 0)
        }
        let address = keyframes.first { $0.phase == .address }?.timestampSeconds
        let top = keyframes.first { $0.phase == .top }?.timestampSeconds
        let anchorIndex = address.flatMap { t in frames.indices.min {
            abs(frames[$0].timestampSeconds-t) < abs(frames[$1].timestampSeconds-t)
        }}
        let images = reconstruct(frames, world: false, segments: segments,
                                 anchorIndex: anchorIndex, top: top)
        let worlds = reconstruct(frames, world: true, segments: segments,
                                 anchorIndex: nil, top: nil)
        return frames.indices.map { i in
            PoseFrame(timestampSeconds: frames[i].timestampSeconds, imageLandmarks: images[i],
                      worldLandmarks: worlds[i].isEmpty ? nil : worlds[i],
                      detectedPersonCount: frames[i].detectedPersonCount)
        }
    }

    private func reconstruct(_ frames: [PoseFrame], world: Bool, segments: [Int],
                             anchorIndex: Int?, top: Double?) -> [[Landmark]] {
        let source = frames.map { world ? ($0.worldLandmarks ?? []) : $0.imageLandmarks }
        let count = PoseJoint.allCases.count
        func finite(_ p: Vector3) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
        func usable(_ mark: Landmark) -> Bool {
            finite(mark.position) && (world || ((0...1).contains(mark.position.x) && (0...1).contains(mark.position.y)))
        }
        func reliable(_ i: Int, _ j: Int) -> Bool {
            guard frames[i].detectedPersonCount == 1, source[i].indices.contains(j), usable(source[i][j]),
                  frames[i].imageLandmarks.indices.contains(j) else { return false }
            let score = frames[i].imageLandmarks[j]
            return (score.visibility ?? 1) >= minVisibility && (score.presence ?? 1) >= 0.5
        }
        var before = Array(repeating: Array<Int?>(repeating: nil, count: count), count: frames.count)
        var after = before
        for j in 0..<count {
            var last: Int?
            for i in frames.indices {
                if i > 0 && segments[i] != segments[i-1] { last = nil }
                if reliable(i,j) { last = i }
                before[i][j] = last
            }
            last = nil
            for i in frames.indices.reversed() {
                if i+1 < frames.count && segments[i] != segments[i+1] { last = nil }
                if reliable(i,j) { last = i }
                after[i][j] = last
            }
        }
        // Per-person bone lengths from reliable world observations only. Image
        // projected lengths must remain free to change with the golfer's turn.
        var lengths: [Int: Double] = [:]
        if world {
            for (parent,joint) in Self.bones {
                var values: [Double] = []
                for i in frames.indices where reliable(i,parent.rawValue) && reliable(i,joint.rawValue) {
                    let d = (source[i][joint.rawValue].position-source[i][parent.rawValue].position).length
                    if d > 0.01 && d < 1.5 { values.append(d) }
                }
                values.sort()
                if values.count >= 3 { lengths[joint.rawValue] = values[values.count/2] }
            }
        }
        return frames.indices.map { i in
            guard frames[i].detectedPersonCount <= 1 else { return source[i] }
            var result = source[i]
            let missing = Landmark(.nan, .nan, .nan, visibility: 0, presence: 0)
            if result.count < count { result += Array(repeating: missing, count: count-result.count) }
            let t = frames[i].timestampSeconds
            var filled = Set<Int>()
            for j in 0..<count where !reliable(i,j) {
                var estimate: Vector3?
                // Short gaps interpolate observations; never bridge a full swing
                // with one straight-line interpolation, especially at impact.
                if let a = before[i][j], let b = after[i][j], a != b,
                   frames[b].timestampSeconds-frames[a].timestampSeconds <= 0.3 {
                    let weight = (t-frames[a].timestampSeconds)/(frames[b].timestampSeconds-frames[a].timestampSeconds)
                    estimate = source[a][j].position*(1-weight)+source[b][j].position*weight
                }
                // Golf stance prior: low-confidence ankles/heels can remain at
                // their own address position through backswing only. Never pin
                // the trail heel through downswing, impact or follow-through.
                if estimate == nil, !world, j >= PoseJoint.leftAnkle.rawValue,
                   let a = anchorIndex, let top, frames[a].timestampSeconds <= t, t <= top,
                   t-frames[a].timestampSeconds <= 3, segments[a] == segments[i], reliable(a,j),
                   let hip = frames[i].imageLandmark(.leftHip), let oldHip = frames[a].imageLandmark(.leftHip),
                   (hip.position-oldHip.position).length < 0.15 {
                    estimate = source[a][j].position
                }
                if let estimate {
                    result[j] = Landmark(position: estimate, visibility: 0, presence: 1)
                    filled.insert(j)
                } else if usable(result[j]), (result[j].presence ?? 1) >= 0.5 {
                    // GHUM's occluded-point estimate is still a useful prior,
                    // but never upgrade its confidence to an observation.
                    result[j].visibility = 0
                    filled.insert(j)
                }
            }
            // Recover absent limb points relative to a currently available
            // parent, using this person's nearest reliable bone direction.
            for (parent,joint) in Self.bones {
                let p = parent.rawValue, j = joint.rawValue
                guard !reliable(i,j), usable(result[p]), (result[p].presence ?? 1) >= 0.5 else { continue }
                if !filled.contains(j) {
                    let candidates = [before[i][j], after[i][j]].compactMap { $0 }.filter {
                        abs(frames[$0].timestampSeconds-t) <= 0.75 && reliable($0,p)
                    }
                    if let a = candidates.min(by: { abs(frames[$0].timestampSeconds-t) < abs(frames[$1].timestampSeconds-t) }) {
                        let offset = source[a][j].position-source[a][p].position
                        result[j] = Landmark(position: result[p].position+offset, visibility: 0, presence: 1)
                        filled.insert(j)
                    }
                }
                // Last resort for a fully missing leg joint: translate the other
                // leg's segment to this hip/knee. This is an anatomical display
                // prior, not evidence that both legs perform the same motion.
                if !filled.contains(j), j >= PoseJoint.leftKnee.rawValue {
                    let oppositeJ = j % 2 == 1 ? j+1 : j-1
                    let oppositeP = p % 2 == 1 ? p+1 : p-1
                    if reliable(i,oppositeJ), reliable(i,oppositeP) {
                        let offset = source[i][oppositeJ].position-source[i][oppositeP].position
                        result[j] = Landmark(position: result[p].position+offset, visibility: 0, presence: 1)
                        filled.insert(j)
                    }
                }
                if world, filled.contains(j), let length = lengths[j],
                   let direction = (result[j].position-result[p].position).normalized() {
                    result[j].position = result[p].position+direction*length
                }
            }
            // Keep completely absent, unrecoverable frames empty.
            if source[i].isEmpty && filled.isEmpty { return [] }
            return result
        }
    }
}
