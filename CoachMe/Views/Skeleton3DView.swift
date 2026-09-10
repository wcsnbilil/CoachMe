import SwiftUI
import CoachMeCore

/// Standalone view of the model's 3D estimate, rendered as an orthographic
/// projection the user can rotate.
///
/// The banner is not decoration: MediaPipe world landmarks are a GHUM model
/// estimate with an undocumented axis convention, hip-centred. Presenting them
/// without that statement would imply calibrated motion capture.
@MainActor
struct Skeleton3DView: View {
    let frame: PoseFrame?
    let handedness: Handedness
    @State private var yaw: Double = 0
    @State private var pitch: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            banner

            GeometryReader { proxy in
                Canvas { context, size in
                    guard let points = projectedPoints(in: size) else { return }

                    func stroke(_ bones: [(PoseJoint, PoseJoint)], _ colour: Color, _ width: CGFloat) {
                        var path = Path()
                        for (a, b) in bones {
                            guard let pa = points[a], let pb = points[b] else { continue }
                            path.move(to: pa); path.addLine(to: pb)
                        }
                        context.stroke(path, with: .color(colour),
                                       style: .init(lineWidth: width, lineCap: .round))
                    }

                    stroke(SkeletonTopology.torso, .primary.opacity(0.8), 3)
                    stroke(SkeletonTopology.legs, .primary.opacity(0.55), 3)
                    stroke(SkeletonTopology.arm(handedness.leadSide), Palette.leadArm, 4)
                    stroke(SkeletonTopology.arm(handedness.trailSide), Palette.trailArm, 4)

                    for joint in SkeletonTopology.dots {
                        guard let p = points[joint] else { continue }
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                                     with: .color(.primary))
                    }

                    // Hip-centre origin marker, to make the coordinate origin visible.
                    if let lh = points[.leftHip], let rh = points[.rightHip] {
                        let origin = CGPoint(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2)
                        context.stroke(Path(ellipseIn: CGRect(x: origin.x - 6, y: origin.y - 6,
                                                              width: 12, height: 12)),
                                       with: .color(.secondary), style: .init(lineWidth: 1, dash: [2, 2]))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { drag in
                            yaw = drag.translation.width / 100
                            pitch = -drag.translation.height / 100
                        }
                )
                .accessibilityLabel("三维骨架估计，可拖动旋转视角")
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Button("正视") { yaw = 0; pitch = 0 }
                Button("俯视") { yaw = 0; pitch = -1.4 }
                Button("侧视") { yaw = 1.57; pitch = 0 }
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
    }

    private var banner: some View {
        Label("模型估计的三维骨架，非动作捕捉。原点为模型的髋部中心，坐标轴与球场、地面、目标线无关。",
              systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Orthographic projection of the world landmarks, normalised so the figure
    /// fits the canvas regardless of the model's absolute scale.
    private func projectedPoints(in size: CGSize) -> [PoseJoint: CGPoint]? {
        guard let frame, let world = frame.worldLandmarks, !world.isEmpty else { return nil }

        let cosY = cos(yaw), sinY = sin(yaw)
        let cosP = cos(pitch), sinP = sin(pitch)

        var raw: [PoseJoint: (x: Double, y: Double)] = [:]
        for joint in PoseJoint.allCases {
            guard world.indices.contains(joint.rawValue) else { continue }
            let mark = world[joint.rawValue]
            if (mark.visibility ?? 1.0) < 0.3 { continue }
            let p = mark.position
            // Yaw about the vertical axis, then pitch about the horizontal one.
            let x1 = p.x * cosY + p.z * sinY
            let z1 = -p.x * sinY + p.z * cosY
            let y1 = p.y * cosP - z1 * sinP
            raw[joint] = (x1, y1)
        }
        guard !raw.isEmpty else { return nil }

        let xs = raw.values.map(\.x), ys = raw.values.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let spanX = max(maxX - minX, 1e-6), spanY = max(maxY - minY, 1e-6)
        let scale = min(size.width / spanX, size.height / spanY) * 0.8
        let offsetX = (size.width - spanX * scale) / 2
        let offsetY = (size.height - spanY * scale) / 2

        return raw.mapValues { point in
            CGPoint(x: offsetX + (point.x - minX) * scale,
                    // World-landmark Y grows downward in image-like fashion; the
                    // figure is drawn directly without flipping so it matches the
                    // 2D overlay's orientation.
                    y: offsetY + (point.y - minY) * scale)
        }
    }
}
