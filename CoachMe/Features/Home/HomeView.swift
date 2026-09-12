import SwiftUI
import CoachMeCore

@MainActor
struct HomeView: View {
    @Environment(SwingLibrary.self) private var library
    @State private var showingImport = false
    @State private var path: [SwingRecord] = []
    @State private var showingRules = false
    @State private var showingAISettings = false
    @State private var aiStatus = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    VStack(alignment: .leading, spacing: 8) {
                        Text("看清每一次挥杆")
                            .font(CoachStyle.display)
                            .foregroundStyle(CoachStyle.text)
                        Text("导入挥杆视频，本机分析，逐帧复核关键动作。")
                            .font(.subheadline)
                            .foregroundStyle(CoachStyle.textSecondary)
                    }
                    .padding(.top, 10)

                    importCard.padding(.top, 20)

                    HStack {
                        Text("最近分析").font(.title3.weight(.semibold))
                        Spacer()
                        if !library.swings.isEmpty {
                            NavigationLink { HistoryListView() } label: {
                                HStack(spacing: 2) {
                                    Text("全部")
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                }
                                .font(.subheadline)
                                .frame(minHeight: 44)
                            }
                        }
                    }
                    .padding(.top, 22)

                    if library.swings.isEmpty {
                        emptyState.padding(.top, 8)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(library.swings.prefix(10)) { swing in
                                NavigationLink(value: swing) { RecordRow(swing: swing) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("删除分析", role: .destructive) { library.delete(swing) }
                                    }
                            }
                        }
                        .padding(.top, 8)
                    }

                    tools.padding(.top, 16)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(CoachStyle.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SwingRecord.self) { WorkbenchView(swing: $0) }
            .sheet(isPresented: $showingImport) { ImportView(onImported: { path.append($0) }) }
            .sheet(isPresented: $showingAISettings, onDismiss: refreshAIStatus) { AISettingsView() }
            .sheet(isPresented: $showingRules) { NavigationStack { RuleListView() } }
            .onAppear(perform: refreshAIStatus)
        }
    }

    private var header: some View {
        HStack {
            Text("COACHME")
                .font(.system(.caption, design: .rounded, weight: .bold))
                .tracking(3)
                .foregroundStyle(CoachStyle.text)
            Spacer()
            Button { showingAISettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(CoachCircleButton())
                .accessibilityLabel("AI 教练服务设置")
        }
        .frame(height: 44)
    }

    private var importCard: some View {
        Button { showingImport = true } label: {
            HStack(spacing: 16) {
                Image(systemName: "video.badge.plus")
                    .font(.title2.weight(.light))
                    .foregroundStyle(CoachStyle.lime)
                    .frame(width: 52, height: 52)
                    .background(CoachStyle.lime.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("导入挥杆视频").font(.title3.weight(.semibold)).foregroundStyle(.white)
                    Text("从相册选择 · 全程本机分析")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.66))
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .padding(20)
            .background(CoachStyle.forest, in: RoundedRectangle(cornerRadius: 24))
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityHint("从相册导入一段挥杆视频并开始分析")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.golf")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(CoachStyle.accent)
            Text("还没有分析记录").font(.headline)
            Text("导入一段从准备姿势到收杆的完整挥杆，分析结果会保存在这里。")
                .font(.subheadline)
                .foregroundStyle(CoachStyle.textSecondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                Label("固定机位，全身入镜", systemImage: "camera")
                Label("正面或沿目标线后方拍摄", systemImage: "scope")
                Label("光线充足，避免遮挡", systemImage: "sun.max")
            }
            .font(.footnote)
            .foregroundStyle(CoachStyle.text)
            .tint(CoachStyle.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(CoachStyle.background, in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 8)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(CoachStyle.surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var tools: some View {
        VStack(spacing: 0) {
            toolRow(symbol: "slider.horizontal.3", title: "教练规则", value: "\(library.rules.count) 条规则") {
                showingRules = true
            }
            GroupDivider(inset: 62)
            toolRow(symbol: "sparkles", title: "AI 教练服务", value: aiStatus) {
                showingAISettings = true
            }
        }
        .coachGroup()
    }

    private func toolRow(symbol: String, title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CoachStyle.forest)
                    .frame(width: 32, height: 32)
                    .background(CoachStyle.confirmedFill, in: RoundedRectangle(cornerRadius: 9))
                Text(title).font(.body).foregroundStyle(CoachStyle.text)
                Spacer()
                Text(value).font(.subheadline).foregroundStyle(CoachStyle.textTertiary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(CoachStyle.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refreshAIStatus() {
        aiStatus = AISettingsStore.service().isConfigured
            ? "\(AISettingsStore.configuration.provider.name) · 已配置"
            : "未配置"
    }
}

/// One saved swing: a frame from the video, its setup, and where review stands.
@MainActor
struct RecordRow: View {
    @Environment(SwingLibrary.self) private var library
    let swing: SwingRecord

    var body: some View {
        HStack(spacing: 14) {
            VideoFrameImage(url: library.videoURL(for: swing),
                            time: swing.keyframes.keyframe(for: .top)?.timestampSeconds ?? swing.clipStartSeconds,
                            maxPixel: 200)
                .frame(width: 60, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    Text(String(format: "%.1f秒", swing.durationSeconds))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .background(CoachStyle.stage.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
                        .padding(5)
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(swing.title).font(.body.weight(.semibold)).foregroundStyle(CoachStyle.text).lineLimit(1)
                Text("\(swing.handedness == .rightHanded ? "右手" : "左手") · \(swing.cameraView.nameZH)")
                    .font(.footnote)
                    .foregroundStyle(CoachStyle.textSecondary)
                status
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(CoachStyle.textTertiary)
        }
        .padding(12)
        .background(CoachStyle.surface, in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        let pending = swing.keyframes.filter { !$0.markedByCoach }.count
        if !library.hasAnalysis(for: swing) {
            StatusTag(status: .incomplete, text: "分析未完成 · 可重新分析")
        } else if swing.keyframes.isEmpty {
            StatusTag(status: .unmarked, text: "尚未标记关键帧")
        } else if pending > 0 {
            StatusTag(status: .pending, text: "\(pending) 个关键帧待复核")
        } else {
            StatusTag(status: .confirmed, text: "关键帧已确认")
        }
    }
}

@MainActor
struct HistoryListView: View {
    @Environment(SwingLibrary.self) private var library

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if library.swings.isEmpty {
                    EmptyStateRow(icon: "doc.text.magnifyingglass",
                                  title: "还没有分析记录",
                                  message: "完成一次分析后，记录会出现在这里。")
                        .coachCard()
                }
                ForEach(library.swings) { swing in
                    NavigationLink(value: swing) { RecordRow(swing: swing) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("删除分析", role: .destructive) { library.delete(swing) }
                        }
                }
            }
            .padding(18)
        }
        .background(CoachStyle.background)
        .navigationTitle("全部分析")
        .toolbar(.visible, for: .navigationBar)
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
            Text(message).font(.subheadline).foregroundStyle(CoachStyle.textSecondary)
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
