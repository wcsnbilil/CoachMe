import SwiftUI
import PhotosUI
import CoachMeCore

/// Shown before every import: how to film so the path check can work.
@MainActor
struct ShootingGuideView: View {
    @Environment(\.betaStrings) private var s
    var onPicked: (PhotosPickerItem) -> Void
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ShootingDiagram()
                    .frame(height: 230)
                    .frame(maxWidth: .infinity)
                    .background(CoachStyle.confirmedFill, in: RoundedRectangle(cornerRadius: 20))

                Text(s.guideIntro).font(.callout).foregroundStyle(CoachStyle.textSecondary)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(s.guideItems.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(CoachStyle.forest, in: Circle())
                            Text(item).font(.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .coachCard()

                Text(s.noLiveCapture).font(.caption).foregroundStyle(CoachStyle.textTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(CoachStyle.background)
        .navigationTitle(s.guideTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            PhotosPicker(selection: $pickerItem, matching: .videos) {
                Label(s.pickVideo, systemImage: "photo.on.rectangle")
            }
            .buttonStyle(CoachPrimaryButton())
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(CoachStyle.background)
        }
        .onChange(of: pickerItem) { _, item in
            if let item { pickerItem = nil; onPicked(item) }
        }
    }
}

/// Top-down sketch: target at the top, ball and golfer, phone 3–4 m behind on the target line.
struct ShootingDiagram: View {
    @Environment(\.betaStrings) private var s

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let cx = w / 2
            let flagY = h * 0.12, golferY = h * 0.48, phoneY = h * 0.86
            ZStack {
                // Target line
                Path { p in p.move(to: CGPoint(x: cx, y: phoneY)); p.addLine(to: CGPoint(x: cx, y: flagY)) }
                    .stroke(CoachStyle.forest.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                // Flag
                Image(systemName: "flag.fill").font(.title2).foregroundStyle(CoachStyle.forest)
                    .position(x: cx + 6, y: flagY - 2)
                Text(s.guideTarget).font(.caption.weight(.semibold)).foregroundStyle(CoachStyle.forest)
                    .position(x: cx + 46, y: flagY)
                // Ball, on the line
                Circle().fill(.white).overlay(Circle().stroke(CoachStyle.forest, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                    .position(x: cx, y: golferY - 6)
                // Golfer stands beside the ball, facing it (right-handed: to the left of the line from behind)
                Image(systemName: "figure.golf").font(.system(size: 44)).foregroundStyle(CoachStyle.forest)
                    .position(x: cx - 34, y: golferY)
                // Distance bracket
                Path { p in
                    p.move(to: CGPoint(x: cx + 26, y: golferY + 20)); p.addLine(to: CGPoint(x: cx + 26, y: phoneY - 18))
                    p.move(to: CGPoint(x: cx + 20, y: golferY + 20)); p.addLine(to: CGPoint(x: cx + 32, y: golferY + 20))
                    p.move(to: CGPoint(x: cx + 20, y: phoneY - 18)); p.addLine(to: CGPoint(x: cx + 32, y: phoneY - 18))
                }
                .stroke(CoachStyle.accent, lineWidth: 1.5)
                Text(s.guideDistance).font(.caption.weight(.semibold)).foregroundStyle(CoachStyle.accent)
                    .position(x: cx + 64, y: (golferY + phoneY) / 2)
                // Phone
                Image(systemName: "iphone.rear.camera").font(.system(size: 30)).foregroundStyle(CoachStyle.text)
                    .position(x: cx, y: phoneY)
                Text(s.guideCamera).font(.caption).foregroundStyle(CoachStyle.textSecondary)
                    .position(x: cx - 44, y: phoneY)
            }
        }
        .accessibilityHidden(true)
    }
}
