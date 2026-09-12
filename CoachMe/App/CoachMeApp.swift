import SwiftUI
import CoachMeCore

@main
@MainActor
struct CoachMeApp: App {
    @State private var library = SwingLibrary()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(library)
                .tint(Palette.leadArm)
        }
    }
}

/// App-wide list of swings and coach rules, backed by `LocalStore`.
@MainActor
@Observable
final class SwingLibrary {
    private(set) var swings: [SwingRecord] = []
    private(set) var rules: [CoachRule] = []
    private let store: LocalStore

    init(store: LocalStore = .shared) {
        self.store = store
        reload()
        store.pruneOrphans()
    }

    func reload() {
        swings = store.loadSwings().sorted { $0.createdAt > $1.createdAt }
        rules = store.loadRules()
    }

    func saveChecked(_ swing: SwingRecord) throws {
        try store.upsert(swing)
        reload()
    }

    func save(_ swing: SwingRecord) {
        try? store.upsert(swing)
        reload()
    }

    func delete(_ swing: SwingRecord) {
        try? store.delete(swing)
        reload()
    }

    func save(rule: CoachRule) {
        var all = rules
        if let index = all.firstIndex(where: { $0.id == rule.id }) {
            all[index] = rule
        } else {
            all.append(rule)
        }
        try? store.saveRules(all)
        reload()
    }

    func delete(rule: CoachRule) {
        var all = rules
        all.removeAll { $0.id == rule.id }
        try? store.saveRules(all)
        reload()
    }

    func rules(for metric: MetricID) -> [CoachRule] {
        rules.filter { $0.metricID == metric }
    }

    func videoURL(for swing: SwingRecord) -> URL { store.videoURL(for: swing) }
    func analysis(for swing: SwingRecord) -> AnalysisCache? { store.loadAnalysis(swingID: swing.id) }
}
