import SwiftUI
import CoachMeCore
import AVFoundation

@MainActor
struct HomeView: View {
    @Environment(SwingLibrary.self) private var library
    @State private var showingImport = false
    @State private var path: [SwingRecord] = []
    @State private var showingRules = false
    @State private var showingAISettings = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(alignment:.center) {
                        VStack(alignment:.leading,spacing:5) {
                            Text("COACHME").font(.system(.caption,design:.rounded,weight:.bold)).tracking(3)
                            Text("每一杆，更进一步。")
                                .font(.system(.title,design:.serif,weight:.medium))
                        }
                        Spacer()
                        Menu {
                            Button("AI 教练设置",systemImage:"sparkles") { showingAISettings = true }
                            Button("教练规则",systemImage:"slider.horizontal.3") { showingRules = true }
                        } label: {
                            Image(systemName:"slider.horizontal.3").font(.body)
                                .frame(width:44,height:44)
                                .background(CoachStyle.surface,in:Circle())
                        }.accessibilityLabel("设置")
                    }
                    hero
                    HStack {
                        VStack(alignment:.leading,spacing:5) {
                            Text("最近挥杆").font(.title3.weight(.semibold))
                            Text(library.swings.isEmpty ? "你的练习，从这里开始" : "已记录 \(library.swings.count) 次挥杆")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        NavigationLink { HistoryListView() } label: {
                            HStack(spacing:4) { Text("全部"); Image(systemName:"arrow.up.right") }
                                .font(.subheadline)
                        }
                    }
                    if library.swings.isEmpty {
                        VStack(spacing:16) {
                            Image(systemName:"figure.golf").font(.system(size:36,weight:.light)).foregroundStyle(CoachStyle.accent)
                            Text("留住一次挥杆，找到一个进步。")
                                .font(.subheadline).multilineTextAlignment(.center)
                            Text("选择一段完整挥杆，交给教练一起看。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity).padding(.vertical,30).coachCard()
                    } else {
                        LazyVStack(spacing:12) {
                            ForEach(library.swings.prefix(10)) { swing in
                                NavigationLink(value:swing) {
                                    HStack(spacing:14) {
                                        SwingThumbnail(url:library.videoURL(for:swing),timestamp:swing.clipStartSeconds)
                                        SwingRow(swing:swing,hasAnalysis:library.analysis(for:swing) != nil)
                                        Spacer(minLength:0)
                                        Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    }.padding(12).background(CoachStyle.surface,in:RoundedRectangle(cornerRadius:20))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("删除分析",role:.destructive) { library.delete(swing) }
                                }
                            }
                        }
                    }
                    HStack(spacing:6) {
                        Image(systemName:"figure.golf")
                        Text("专注动作，享受进步。")
                    }.font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth:.infinity).padding(.top,8)
                }.padding(.horizontal,22).padding(.top,12).padding(.bottom,32)
            }
            .background(CoachStyle.background)
            .toolbar(.hidden,for:.navigationBar)
            .navigationDestination(for:SwingRecord.self) { WorkbenchView(swing:$0) }
            .sheet(isPresented:$showingImport) { ImportView(onImported:{ path.append($0) }) }
            .sheet(isPresented:$showingAISettings) { AISettingsView() }
            .sheet(isPresented:$showingRules) { NavigationStack { RuleListView() } }
        }
    }

    private var hero: some View {
        Button { showingImport = true } label: {
            VStack(alignment:.leading,spacing:24) {
                HStack {
                    Text("YOUR NEXT SWING").font(.caption2.weight(.medium)).tracking(2)
                    Spacer()
                    Image(systemName:"figure.golf").font(.title2.weight(.light))
                }.foregroundStyle(CoachStyle.lime)
                VStack(alignment:.leading,spacing:8) {
                    Text("看清动作\n找到下一步")
                        .font(.system(.largeTitle,design:.serif,weight:.medium)).lineSpacing(4)
                    Text("一次挥杆，一份专属指导。")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                HStack {
                    Label("开始分析",systemImage:"plus").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName:"arrow.up.right").font(.body.weight(.medium))
                        .frame(width:38,height:38).background(.white.opacity(0.12),in:Circle())
                }
            }
            .foregroundStyle(.white).padding(24)
            .background(CoachStyle.forest,in:RoundedRectangle(cornerRadius:28))
        }.buttonStyle(.plain).accessibilityHint("从相册导入一段挥杆视频并开始分析")
    }
}

@MainActor
struct SwingThumbnail: View {
    let url: URL
    let timestamp: Double
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            CoachStyle.forest.opacity(0.1)
            if let image { Image(uiImage:image).resizable().scaledToFill() }
            else { Image(systemName:"figure.golf").foregroundStyle(CoachStyle.accent) }
        }.frame(width:66,height:82).clipShape(RoundedRectangle(cornerRadius:12))
            .accessibilityHidden(true)
            .task(id:url) {
                let generator = AVAssetImageGenerator(asset:AVURLAsset(url:url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width:200,height:200)
                defer { generator.cancelAllCGImageGeneration() }
                if let result = try? await generator.image(at:CMTime(seconds:timestamp,preferredTimescale:600)), !Task.isCancelled {
                    image = UIImage(cgImage:result.image)
                }
            }
    }
}

@MainActor
struct SwingRow: View {
    let swing: SwingRecord
    let hasAnalysis: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(swing.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
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
        .scrollContentBackground(.hidden)
        .background(CoachStyle.background)
        .toolbar(.visible,for:.navigationBar)
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
