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
    static let torso: [(PoseJoint, PoseJoint)] = [
        (.leftShoulder, .rightShoulder), (.leftHip, .rightHip),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip)
    ]
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

@MainActor
struct SkeletonOverlay: View {
    let frame: PoseFrame?
    let handedness: Handedness
    let videoSize: CGSize
    let minVisibility: Double

    var body: some View {
        GeometryReader { proxy in
            let geometry = VideoDisplayGeometry(videoSize: videoSize, viewSize: proxy.size)

            Canvas { context, _ in
                guard let frame else { return }

                func visiblePoint(_ joint: PoseJoint) -> CGPoint? {
                    guard let mark = frame.imageLandmark(joint),
                          (mark.visibility ?? 1.0) >= minVisibility else { return nil }
                    return geometry.point(normalisedX: mark.position.x, y: mark.position.y)
                }

                func stroke(_ bones: [(PoseJoint, PoseJoint)], _ colour: Color, width: CGFloat) {
                    var path = Path()
                    for (a, b) in bones {
                        guard let pa = visiblePoint(a), let pb = visiblePoint(b) else { continue }
                        path.move(to: pa)
                        path.addLine(to: pb)
                    }
                    context.stroke(path, with: .color(colour), style: .init(lineWidth: width, lineCap: .round))
                }

                stroke(SkeletonTopology.torso, .white.opacity(0.9), width: 3)
                stroke(SkeletonTopology.legs, .white.opacity(0.65), width: 3)
                // Lead and trail arms are coloured differently AND labelled, so the
                // distinction never depends on colour alone.
                stroke(SkeletonTopology.arm(handedness.leadSide), Palette.leadArm, width: 4)
                stroke(SkeletonTopology.arm(handedness.trailSide), Palette.trailArm, width: 4)

                for joint in SkeletonTopology.dots {
                    guard let p = visiblePoint(joint) else { continue }
                    let r: CGFloat = 3.5
                    context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(.white))
                }

                // Text labels next to each wrist, so the arms are identifiable
                // for colour-blind users and in bright outdoor light.
                if let lead = visiblePoint(.wrist(handedness.leadSide)) {
                    context.draw(Text("引导臂").font(.caption2.bold()).foregroundStyle(Palette.leadArm),
                                 at: CGPoint(x: lead.x, y: lead.y - 14))
                }
                if let trail = visiblePoint(.wrist(handedness.trailSide)) {
                    context.draw(Text("后侧臂").font(.caption2.bold()).foregroundStyle(Palette.trailArm),
                                 at: CGPoint(x: trail.x, y: trail.y - 14))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

enum Palette {
    static let leadArm = Color(red: 0.25, green: 0.72, blue: 1.0)
    static let trailArm = Color(red: 1.0, green: 0.62, blue: 0.24)
    static let unavailable = Color.secondary
}
