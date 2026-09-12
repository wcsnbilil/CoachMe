import SwiftUI
import CoachMeCore

/// Maps normalised landmark coordinates onto the rectangle the video actually
/// occupies inside its view.
///
/// This is the single place where overlay alignment can go wrong, so it is kept
/// tiny and pure. `AVPlayerLayer` with `.resizeAspect` letterboxes the picture:
/// the video does **not** fill the view, and drawing landmarks against the view
/// bounds puts the skeleton off the body by exactly the letterbox margin.
///
/// Rotation and mirroring are already resolved upstream — `VideoAssetReader`
/// bakes the asset's preferred transform into the frames it hands the detector,
/// so `videoSize` here is the upright presentation size and normalised
/// coordinates are in the same orientation the viewer sees.
struct VideoDisplayGeometry {
    /// Upright presentation size of the video.
    let videoSize: CGSize
    /// Size of the view the video is displayed in.
    let viewSize: CGSize

    /// The letterboxed rectangle the picture occupies, in view coordinates.
    var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }

        let scale = min(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (viewSize.width - size.width) / 2,
                      y: (viewSize.height - size.height) / 2,
                      width: size.width,
                      height: size.height)
    }

    /// Normalised (0...1, origin top-left) → view point.
    func point(normalisedX x: Double, y: Double) -> CGPoint {
        let rect = videoRect
        return CGPoint(x: rect.minX + CGFloat(x) * rect.width,
                       y: rect.minY + CGFloat(y) * rect.height)
    }
}

/// Bones drawn between landmark pairs. Head detail is omitted on purpose — it
/// adds clutter and none of the metrics use it.
enum SkeletonTopology {
    static let legs: [(PoseJoint, PoseJoint)] = [
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle), (.leftAnkle, .leftFootIndex),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle), (.rightAnkle, .rightFootIndex)
    ]
    static func arm(_ side: BodySide) -> [(PoseJoint, PoseJoint)] {
        [(.shoulder(side), .elbow(side)), (.elbow(side), .wrist(side))]
    }
    /// Joints worth drawing as dots.
    static let dots: [PoseJoint] = [
        .leftShoulder, .rightShoulder, .leftElbow, .rightElbow, .leftWrist, .rightWrist,
        .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle
    ]
}

/// The angle shown on the video: three joints with the vertex in the middle.
struct SkeletonAngleMark: Equatable {
    let joints: [PoseJoint]
    let label: String
    /// Formatted value, or nil when the metric could not be computed reliably.
    let value: String?
}

/// Measured bones are solid; bones touching a joint below the visibility gate are
/// dashed, because those positions are estimates and never enter a metric.
@MainActor
struct SkeletonOverlay: View {
    let frame: PoseFrame?
    let handedness: Handedness
    let videoSize: CGSize
    let minVisibility: Double
    var angle: SkeletonAngleMark?

    var body: some View {
        GeometryReader { proxy in
            let geometry = VideoDisplayGeometry(videoSize: videoSize, viewSize: proxy.size)

            Canvas { context, size in
                guard let frame else { return }

                func isReliable(_ joint: PoseJoint) -> Bool {
                    (frame.imageLandmark(joint)?.visibility ?? 1) >= minVisibility
                }

                func point(_ joint: PoseJoint) -> CGPoint? {
                    guard let mark = frame.imageLandmark(joint),
                          mark.position.x.isFinite, mark.position.y.isFinite,
                          (0...1).contains(mark.position.x), (0...1).contains(mark.position.y),
                          (mark.presence ?? 1) >= 0.5 else { return nil }
                    return geometry.point(normalisedX: mark.position.x, y: mark.position.y)
                }

                let highlighted: Set<String> = {
                    guard let joints = angle?.joints, joints.count == 3 else { return [] }
                    return ["\(joints[0])-\(joints[1])", "\(joints[1])-\(joints[0])",
                            "\(joints[1])-\(joints[2])", "\(joints[2])-\(joints[1])"]
                }()

                func line(_ a: CGPoint, _ b: CGPoint, reliable: Bool, lit: Bool) {
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    let colour = lit ? CoachStyle.limeOnDark : CoachStyle.onStage
                    context.stroke(path, with: .color(colour.opacity(reliable ? 0.95 : 0.75)),
                                   style: .init(lineWidth: lit ? 3 : 2.2, lineCap: .round,
                                                dash: reliable ? [] : [5, 4]))
                }

                func stroke(_ bones: [(PoseJoint, PoseJoint)]) {
                    for (a, b) in bones {
                        guard let pa = point(a), let pb = point(b) else { continue }
                        let reliable = isReliable(a) && isReliable(b)
                        line(pa, pb, reliable: reliable, lit: reliable && highlighted.contains("\(a)-\(b)"))
                    }
                }

                // In a 2D projection, anatomical left/right shoulder-to-hip
                // diagonals can cross during a valid finish. Use a spine with
                // shoulder/hip axes so this does not look like a twisted cage.
                stroke([(.leftShoulder, .rightShoulder), (.leftHip, .rightHip)])
                if let ls = point(.leftShoulder), let rs = point(.rightShoulder),
                   let lh = point(.leftHip), let rh = point(.rightHip) {
                    let reliable = [PoseJoint.leftShoulder, .rightShoulder, .leftHip, .rightHip].allSatisfy(isReliable)
                    line(CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2),
                         CGPoint(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2), reliable: reliable, lit: false)
                }
                stroke(SkeletonTopology.legs)
                stroke(SkeletonTopology.arm(handedness.leadSide))
                stroke(SkeletonTopology.arm(handedness.trailSide))

                for joint in SkeletonTopology.dots {
                    guard let p = point(joint) else { continue }
                    let dot = Path(ellipseIn: CGRect(x: p.x - 3.2, y: p.y - 3.2, width: 6.4, height: 6.4))
                    if isReliable(joint) {
                        context.fill(dot, with: .color(CoachStyle.onStage))
                        context.stroke(dot, with: .color(CoachStyle.stage.opacity(0.5)), lineWidth: 1)
                    } else {
                        context.fill(dot, with: .color(CoachStyle.stage.opacity(0.6)))
                        context.stroke(dot, with: .color(CoachStyle.onStage),
                                       style: .init(lineWidth: 1.4, dash: [2, 2]))
                    }
                }

                // Angle arc and value tag for the metric chosen in the readouts.
                guard let angle, angle.joints.count == 3,
                      let a = point(angle.joints[0]), let b = point(angle.joints[1]),
                      let c = point(angle.joints[2]) else { return }
                let reliable = angle.joints.allSatisfy(isReliable)
                if reliable, angle.value != nil {
                    let start = atan2(a.y - b.y, a.x - b.x), end = atan2(c.y - b.y, c.x - b.x)
                    var delta = end - start
                    while delta > .pi { delta -= 2 * .pi }
                    while delta < -.pi { delta += 2 * .pi }
                    var arc = Path()
                    arc.addArc(center: b, radius: 15, startAngle: .radians(start),
                               endAngle: .radians(start + delta), clockwise: delta < 0)
                    context.stroke(arc, with: .color(CoachStyle.limeOnDark), lineWidth: 2)
                }

                let label = context.resolve(Text(angle.label).font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x10170F)))
                let value = context.resolve(Text(angle.value ?? "无法可靠计算")
                    .font(.system(size: angle.value == nil ? 12 : 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color(hex: 0x10170F)))
                let labelSize = label.measure(in: size), valueSize = value.measure(in: size)
                let tag = CGSize(width: labelSize.width + valueSize.width + 21, height: 26)
                // Prefer the side away from the body; fall back to the other side.
                let onLeft = b.x - tag.width - 40 >= 8
                let x = onLeft ? b.x - tag.width - 40 : min(size.width - tag.width - 8, b.x + 40)
                let y = min(max(8, b.y - tag.height / 2), size.height - tag.height - 8)
                var leader = Path()
                leader.move(to: CGPoint(x: b.x + (onLeft ? -18 : 18), y: b.y))
                leader.addLine(to: CGPoint(x: onLeft ? x + tag.width : x, y: y + tag.height / 2))
                context.stroke(leader, with: .color(CoachStyle.limeOnDark.opacity(0.8)), lineWidth: 1)
                let rect = CGRect(origin: CGPoint(x: x, y: y), size: tag)
                context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(CoachStyle.limeOnDark))
                context.draw(label, at: CGPoint(x: x + 8, y: rect.midY), anchor: .leading)
                context.draw(value, at: CGPoint(x: x + 13 + labelSize.width, y: rect.midY), anchor: .leading)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
