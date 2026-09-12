import Foundation

/// Display-only retargeting to a fixed-proportion human. Never used by metrics.
public struct GolfAvatarPose: Sendable {
    public let joints: [PoseJoint: Vector3]
    public let estimated: Set<PoseJoint>
    public let hasObservation: Bool
    public let constrained: Bool
    public static let segments: [(PoseJoint, PoseJoint, Double)] = [
        (.leftShoulder,.leftElbow,0.30),(.leftElbow,.leftWrist,0.26),
        (.rightShoulder,.rightElbow,0.30),(.rightElbow,.rightWrist,0.26),
        (.leftHip,.leftKnee,0.43),(.leftKnee,.leftAnkle,0.43),
        (.rightHip,.rightKnee,0.43),(.rightKnee,.rightAnkle,0.43)]

    public static let rest: [PoseJoint: Vector3] = [
        .leftHip:Vector3(-0.15,0.96,0),.rightHip:Vector3(0.15,0.96,0),
        .leftShoulder:Vector3(-0.22,1.43,0.16),.rightShoulder:Vector3(0.22,1.43,0.16),
        .leftElbow:Vector3(-0.15,1.15,0.25),.rightElbow:Vector3(0.16,1.15,0.26),
        .leftWrist:Vector3(-0.025,0.93,0.34),.rightWrist:Vector3(0.025,0.93,0.36),
        .leftKnee:Vector3(-0.20,0.54,0.09),.rightKnee:Vector3(0.20,0.54,0.09),
        .leftAnkle:Vector3(-0.23,0.11,0),.rightAnkle:Vector3(0.23,0.11,0),
        .nose:Vector3(0,1.66,0.22)]

    private init(joints:[PoseJoint:Vector3]) {
        self.joints=joints; estimated=Set(joints.keys); hasObservation=false; constrained=false
    }
    /// Separated hands for skin binding: the standard golf pose is an animation of this mesh.
    public static var bindPose: GolfAvatarPose {
        var p=GolfAvatarPose(frame:nil).joints
        for side in [BodySide.left,.right] {
            let sign:Double=side == .left ? -1 : 1
            p[.elbow(side)]=p[.shoulder(side)]!+Vector3(sign*0.24,-0.18,0)
            p[.wrist(side)]=p[.elbow(side)]!+Vector3(sign*0.208,-0.156,0)
        }
        return GolfAvatarPose(joints:p)
    }

    public init(frame: PoseFrame?) {
        var inferred = Set<PoseJoint>()
        var limited = false
        func sample(_ j: PoseJoint) -> Vector3? {
            guard let frame, frame.detectedPersonCount == 1, let m = frame.worldLandmark(j),
                  m.position.x.isFinite, m.position.y.isFinite, m.position.z.isFinite,
                  abs(m.position.x) < 3, abs(m.position.y) < 3, abs(m.position.z) < 3,
                  (m.presence ?? 1) >= 0.5 else { inferred.insert(j); return nil }
            // The display completer marks its reconstructed coordinates as visibility=0, presence=1.
            let visibility = m.visibility ?? 1
            guard visibility >= 0.5 || (visibility == 0 && m.presence == 1) else { inferred.insert(j); return nil }
            if visibility < 0.5 { inferred.insert(j) }
            return Vector3(m.position.x,-m.position.y,-m.position.z)
        }
        let raw = Dictionary(uniqueKeysWithValues: Self.rest.keys.compactMap { j in sample(j).map { (j,$0) } })
        let observed = raw.count >= 4
        let upWorld = Vector3(0,1,0)
        func direction(_ a: PoseJoint,_ b: PoseJoint) -> Vector3? {
            guard let av = raw[a], let bv = raw[b] else { return nil }
            let d = bv-av
            guard d.length > 0.025 else { return nil }
            return d.normalized()
        }
        func cone(_ v: Vector3, around axis: Vector3, limit: Double) -> Vector3 {
            let dot = max(-1,min(1,v.dot(axis)))
            guard dot < cos(limit) else { return v }
            limited = true
            let orthogonal = (v-axis*dot).normalized() ?? axis.cross(Vector3(1,0,0)).normalized() ?? Vector3(0,0,1)
            return axis*cos(limit)+orthogonal*sin(limit)
        }
        var hipAxis = direction(.leftHip,.rightHip) ?? Vector3(1,0,0)
        hipAxis = Vector3(hipAxis.x,0,hipAxis.z).normalized() ?? Vector3(1,0,0)
        var torsoUp = (Vector3(0,0.47,0.16)).normalized()!
        if let ls=raw[.leftShoulder],let rs=raw[.rightShoulder],let lh=raw[.leftHip],let rh=raw[.rightHip] {
            torsoUp = ((ls+rs-lh-rh)/2).normalized() ?? torsoUp
            torsoUp = cone(torsoUp,around:upWorld,limit:70 * .pi/180)
        }
        var shoulderAxis = direction(.leftShoulder,.rightShoulder) ?? hipAxis
        shoulderAxis = (shoulderAxis-torsoUp*shoulderAxis.dot(torsoUp)).normalized() ?? hipAxis
        let projectedHip = (hipAxis-torsoUp*hipAxis.dot(torsoUp)).normalized() ?? hipAxis
        shoulderAxis = cone(shoulderAxis,around:projectedHip,limit:100 * .pi/180)
        let center = Vector3(0,0.96,0)
        let shoulderCenter = center+torsoUp*0.50
        var points: [PoseJoint:Vector3] = [
            .leftHip:center-hipAxis*0.15,.rightHip:center+hipAxis*0.15,
            .leftShoulder:shoulderCenter-shoulderAxis*0.22,.rightShoulder:shoulderCenter+shoulderAxis*0.22]
        // Sequential directions keep lengths fixed; low visibility uses the template in the current torso orientation.
        func fallback(_ a: PoseJoint,_ b: PoseJoint, axis: Vector3, up: Vector3) -> Vector3 {
            let rest = (Self.rest[b]!-Self.rest[a]!).normalized()!
            let forward = axis.cross(up).normalized() ?? Vector3(0,0,1)
            return (axis*rest.x+up*rest.y+forward*rest.z).normalized()!
        }
        for (a,b,length) in Self.segments {
            let arm = [PoseJoint.leftShoulder,.leftElbow,.rightShoulder,.rightElbow].contains(a)
            var d = direction(a,b) ?? fallback(a,b,axis:arm ? shoulderAxis : hipAxis,up:arm ? torsoUp : upWorld)
            if a == .leftElbow || a == .rightElbow || a == .leftKnee || a == .rightKnee {
                let parent: PoseJoint = a == .leftElbow ? .leftShoulder : a == .rightElbow ? .rightShoulder : a == .leftKnee ? .leftHip : .rightHip
                let upper = (points[a]!-points[parent]!).normalized()!
                d = cone(d,around:upper,limit:(arm ? 155 : 145) * .pi/180)
            }
            points[b] = points[a]!+d*length
        }
        // A stable template head follows the chest; a face landmark does not scale the skull.
        let forward = shoulderAxis.cross(torsoUp).normalized() ?? Vector3(0,0,1)
        points[.nose] = shoulderCenter+torsoUp*0.22+forward*0.04
        let floor = min(points[.leftAnkle]!.y,points[.rightAnkle]!.y)-0.10
        for key in Array(points.keys) { points[key]!.y -= floor }
        joints = points
        estimated = inferred
        hasObservation = observed
        constrained = limited
    }
}

public struct GolfAvatarBone: Sendable {
    public let name: String
    public let start: Vector3
    public let end: Vector3
    public let across: Vector3?
    public init(_ name: String,_ start: Vector3,_ end: Vector3, across: Vector3? = nil) { self.name=name; self.start=start; self.end=end; self.across=across }
}
public extension GolfAvatarPose {
    var bones: [GolfAvatarBone] {
        let p = joints
        let hips = (p[.leftHip]!+p[.rightHip]!)/2
        let shoulders = (p[.leftShoulder]!+p[.rightShoulder]!)/2
        let up = (shoulders-hips).normalized()!
        let across = (p[.rightShoulder]!-p[.leftShoulder]!).normalized()!
        let forward = across.cross(up).normalized()!
        var result = [GolfAvatarBone("pelvis",hips-up*0.08,hips+up*0.15,across:(p[.rightHip]!-p[.leftHip]!).normalized()),
                      GolfAvatarBone("spine",hips,shoulders,across:across),
                      GolfAvatarBone("head",shoulders+up*0.07,p[.nose]!+up*0.11,across:across)]
        for side in [BodySide.left,.right] {
            let name = side.rawValue
            let shoulder=p[.shoulder(side)]!,elbow=p[.elbow(side)]!,wrist=p[.wrist(side)]!
            let hip=p[.hip(side)]!,knee=p[.knee(side)]!,ankle=p[.ankle(side)]!
            result += [GolfAvatarBone(name+"UpperArm",shoulder,elbow,across:across),GolfAvatarBone(name+"Forearm",elbow,wrist,across:across),
                       GolfAvatarBone(name+"Hand",wrist,wrist+(wrist-elbow).normalized()!*0.085,across:across),
                       GolfAvatarBone(name+"Thigh",hip,knee,across:(p[.rightHip]!-p[.leftHip]!).normalized()),GolfAvatarBone(name+"Shin",knee,ankle,across:(p[.rightHip]!-p[.leftHip]!).normalized()),
                       GolfAvatarBone(name+"Foot",ankle,ankle+forward*0.18-Vector3(0,0.025,0),across:(p[.rightHip]!-p[.leftHip]!).normalized())]
        }
        return result
    }
}
