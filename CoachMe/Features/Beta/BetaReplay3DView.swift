import SwiftUI
import CoachMeCore

/// The beta's 3D replay: the 3D figure seen only from the camera that filmed the swing.
///
/// Single-camera MediaPipe depth is not reliable enough to turn the body (the same tour
/// players measure ~40° of shoulder turn filmed face-on against ~90° filmed down the line),
/// so there is no rotation, no view buttons and no angle numbers here.
@MainActor
struct BetaReplay3DView: View {
    @Environment(SwingLibrary.self) private var library
    @Environment(\.betaStrings) private var s
    let swingID: UUID
    @State private var frames: [PoseFrame] = []
    @State private var index = 0
    @State private var playing = true
    @State private var loaded = false

    /// The scene the replay uses; the tests check it cannot be rotated.
    static func scene(frame: PoseFrame?) -> AvatarSceneView {
        AvatarSceneView(frame: frame, angle: 0, reset: 0, showBones: true, darkStage: true, orbit: false)
    }

    var body: some View {
        VStack(spacing: 14) {
            if frames.isEmpty {
                if loaded {
                    Text(s.replay3DUnavailable).foregroundStyle(CoachStyle.textSecondary)
                } else {
                    ProgressView()
                }
                Spacer()
            } else {
                Self.scene(frame: frames[min(index, frames.count - 1)])
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel(s.replay3D)
                HStack(spacing: 12) {
                    Button { playing.toggle() } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(playing ? s.pause : s.play)
                    Slider(value: Binding(get: { Double(index) },
                                          set: { index = Int($0.rounded()); playing = false }),
                           in: 0...Double(max(frames.count - 1, 1)))
                }
            }
            Label(s.replay3DNote, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(CoachStyle.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(CoachStyle.background)
        .navigationTitle(s.replay3D)
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .task(id: playing) { await play() }
    }

    private func load() {
        defer { loaded = true }
        guard frames.isEmpty, let swing = library.swings.first(where: { $0.id == swingID }),
              let cache = library.analysis(for: swing) else { return }
        let display = PoseDisplayCompleter(minVisibility: swing.qualityPolicy.minVisibility)
            .complete(cache.smoothedFrames(), keyframes: swing.keyframes)
        frames = WorldDisplaySmoother().smooth(PoseDisplaySmoother().smooth(display))
            .filter { $0.worldLandmarks != nil && $0.detectedPersonCount == 1 }
    }

    /// Half speed, so the downswing can be followed by eye.
    private func play() async {
        while playing && !Task.isCancelled {
            guard frames.count > 1 else {
                try? await Task.sleep(for: .milliseconds(100)); continue
            }
            let next = (index + 1) % frames.count
            let dt = next == 0 ? 0.6 : max(0.01, frames[next].timestampSeconds - frames[index].timestampSeconds) * 2
            try? await Task.sleep(for: .seconds(min(dt, 0.6)))
            guard playing, !Task.isCancelled else { return }
            index = next
        }
    }
}
