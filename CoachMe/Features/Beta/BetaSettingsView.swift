import SwiftUI
import CoachMeCore

@MainActor
struct BetaSettingsView: View {
    @Environment(\.betaStrings) private var s
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 0) {
                        row(s.versionLabel, BetaMode.appVersion)
                        Divider().padding(.leading, 16)
                        row(s.buildLabel, BetaMode.build)
                        Divider().padding(.leading, 16)
                        row(s.betaModeLabel, s.on)
                    }
                    .coachGroup()

                    VStack(alignment: .leading, spacing: 8) {
                        Label(s.privacyTitle, systemImage: "lock.shield").font(.subheadline.weight(.semibold))
                        Text(s.privacyNote).font(.callout).foregroundStyle(CoachStyle.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .coachCard()
                }
                .padding(18)
            }
            .background(CoachStyle.background)
            .navigationTitle(s.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(s.close) { dismiss() } }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(CoachStyle.textSecondary).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
