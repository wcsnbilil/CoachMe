import SwiftUI
import CoachMeCore

/// When the path check refuses: the concrete reason and how to film again.
@MainActor
struct BetaRefusalView: View {
    @Environment(\.betaStrings) private var s
    let refusal: SwingPathAnalyzer.Refusal?
    var onRefilm: () -> Void

    var body: some View {
        let g = RefusalGuidance(refusal: refusal, language: s.language)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34)).foregroundStyle(CoachStyle.pending)
                    Text(s.refusalTitle).font(.title2.weight(.bold))
                    Text(g.category.shortLabel(s.language))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CoachStyle.pending)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(CoachStyle.pendingFill, in: Capsule())
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CoachStyle.pendingFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 8) {
                    Text(s.refusalReasonTitle).font(.subheadline.weight(.semibold))
                    Text(g.reason).font(.body).fixedSize(horizontal: false, vertical: true)
                }
                .coachCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text(s.refusalRetakeTitle).font(.subheadline.weight(.semibold))
                    ForEach(Array(g.retakeSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.footnote.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(CoachStyle.forest, in: Circle())
                            Text(step).font(.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ShootingDiagram()
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .background(CoachStyle.confirmedFill, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.top, 4)
                }
                .coachCard()
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(CoachStyle.background)
        .navigationTitle(s.reportTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(action: onRefilm) { Label(s.refilm, systemImage: "camera") }
                .buttonStyle(CoachPrimaryButton())
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(CoachStyle.background)
        }
    }
}
