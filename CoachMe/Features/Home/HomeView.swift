import SwiftUI
import CoachMeCore

@MainActor
struct HomeView: View {
    @Environment(SwingLibrary.self) private var library
    @State private var showingImport = false
    @State private var showingRules = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingImport = true
                    } label: {
                        Label("开始新的分析", systemImage: "plus.circle.fill")
                            .font(.headline)
                    }
                    .accessibilityHint("从相册导入一段挥杆视频并开始分析")
                }

                Section("最近分析") {
                    if library.swings.isEmpty {
                        EmptyStateRow(
                            icon: "figure.golf",
                            title: "还没有分析记录",
                            message: "导入一段挥杆视频开始。建议固定机位、全身入镜。"
                        )
                    } else {
                        ForEach(library.swings.prefix(10)) { swing in
                            NavigationLink(value: swing) {
                                SwingRow(swing: swing, hasAnalysis: library.analysis(for: swing) != nil)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { library.delete(library.swings[index]) }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        HistoryListView()
                    } label: {
                        Label("查看历史报告", systemImage: "list.bullet.rectangle")
                    }
                    Button {
                        showingRules = true
                    } label: {
                        Label("教练规则管理", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .navigationTitle("CoachMe")
            .navigationDestination(for: SwingRecord.self) { swing in
                WorkbenchView(swing: swing)
            }
            .sheet(isPresented: $showingImport) {
                ImportView()
            }
            .sheet(isPresented: $showingRules) {
                NavigationStack { RuleListView() }
            }
        }
    }
}

@MainActor
struct SwingRow: View {
    let swing: SwingRecord
    let hasAnalysis: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(swing.title).font(.body)
            HStack(spacing: 6) {
                Text(swing.createdAt, format: .dateTime.month().day().hour().minute())
                Text("·")
                Text(swing.handedness == .rightHanded ? "右手" : "左手")
                Text("·")
                Text(swing.cameraView.nameZH)
                if !hasAnalysis {
                    Text("·")
                    // Status carries an icon and words, never colour alone.
                    Label("未分析", systemImage: "exclamationmark.triangle")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct HistoryListView: View {
    @Environment(SwingLibrary.self) private var library

    var body: some View {
        List {
            if library.swings.isEmpty {
                EmptyStateRow(icon: "doc.text.magnifyingglass",
                              title: "还没有报告",
                              message: "完成一次分析后，报告会出现在这里。")
            }
            ForEach(library.swings) { swing in
                NavigationLink {
                    ReportView(swing: swing)
                } label: {
                    SwingRow(swing: swing, hasAnalysis: library.analysis(for: swing) != nil)
                }
            }
        }
        .navigationTitle("历史报告")
    }
}

@MainActor
struct EmptyStateRow: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

extension CameraView {
    var nameZH: String {
        switch self {
        case .faceOn:      return "正面"
        case .downTheLine: return "沿目标线后方"
        case .unknown:     return "未知视角"
        }
    }
}

extension ClubType {
    var nameZH: String {
        switch self {
        case .driver: return "一号木"
        case .wood:   return "球道木"
        case .hybrid: return "铁木杆"
        case .iron:   return "铁杆"
        case .wedge:  return "挖起杆"
        case .putter: return "推杆"
        case .unknown: return "未指定"
        }
    }
}

extension SwingRecord: Hashable {
    static func == (lhs: SwingRecord, rhs: SwingRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
