import SwiftUI
import PhotosUI
import CoachMeCore

/// Every screen the beta build can navigate to. Nothing here leads to the AI
/// coach, the joint-angle metrics, the workbench or the coach rules.
enum BetaRoute: Hashable {
    case guide
    case analysing(PhotosPickerItem)
    case result(UUID)
    /// Swing ID of the analysed video.
    case replay3D(UUID)

    var feature: AppFeature {
        switch self {
        case .guide: return .shootingGuide
        case .analysing: return .shootingGuide
        case .result: return .pathReport
        case .replay3D: return .avatarReplay
        }
    }

    /// The root screen and its sheets.
    static let rootFeatures: [AppFeature] = [.recordList, .exportRecords, .settingsVersion]
    /// A result screen shows either the report or the refusal help; a report links to the 3D replay.
    static let resultFeatures: [AppFeature] = [.pathReport, .refusalHelp, .avatarReplay]
}

@MainActor
struct BetaRootView: View {
    @Environment(SwingLibrary.self) private var library
    @Environment(\.betaStrings) private var s
    @State private var path: [BetaRoute] = []
    @State private var records: [BetaRecord] = []
    @State private var showingSettings = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack(path: $path) {
            BetaRecordsView(records: records, exportURL: exportURL,
                            onNew: { path.append(.guide) },
                            onOpen: { path.append(.result($0.id)) })
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel(s.settingsTitle)
                    }
                }
                .navigationDestination(for: BetaRoute.self) { route in
                    switch route {
                    case .guide:
                        ShootingGuideView(onPicked: { item in path.append(.analysing(item)) })
                    case .analysing(let item):
                        BetaAnalysingView(item: item) { record in
                            reload()
                            path = [.result(record.id)]
                        } onCancel: {
                            path.removeLast()
                        }
                    case .result(let id):
                        if let record = records.first(where: { $0.id == id }) {
                            BetaResultView(record: record, onAgain: { path = [.guide] },
                                           onReplay: record.swingID.map { id in { path.append(.replay3D(id)) } })
                        }
                    case .replay3D(let swingID):
                        BetaReplay3DView(swingID: swingID)
                    }
                }
        }
        .sheet(isPresented: $showingSettings) { BetaSettingsView() }
        .onAppear(perform: reload)
    }

    private func reload() {
        records = BetaAnalysisRunner.recordStore.load()
        exportURL = Self.writeExport(records)
    }

    static func writeExport(_ records: [BetaRecord]) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coachme-test-log.json")
        guard let data = try? BetaExport(records: records, appVersion: BetaMode.appVersion, build: BetaMode.build).jsonData(),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
}

/// Loads the evidence frame, then shows the report or the refusal help.
@MainActor
struct BetaResultView: View {
    @Environment(SwingLibrary.self) private var library
    let record: BetaRecord
    var onAgain: () -> Void
    var onReplay: (() -> Void)? = nil
    @State private var frame: UIImage?

    var body: some View {
        Group {
            if let evidence = record.evidence, evidence.isJudged {
                BetaReportView(record: record, evidence: evidence, frameImage: frame, onAgain: onAgain, onReplay: onReplay)
            } else {
                BetaRefusalView(refusal: record.refusal, onRefilm: onAgain)
            }
        }
        .task(id: record.id) {
            guard let evidence = record.evidence, evidence.isJudged, let t = evidence.evidenceSeconds,
                  let swingID = record.swingID,
                  let swing = library.swings.first(where: { $0.id == swingID }) else { return }
            frame = await VideoFrameCache.shared.image(url: library.videoURL(for: swing), time: t, maxPixel: 1000)
        }
    }
}

// MARK: - Records list

@MainActor
struct BetaRecordsView: View {
    @Environment(\.betaStrings) private var s
    let records: [BetaRecord]
    let exportURL: URL?
    var onNew: () -> Void
    var onOpen: (BetaRecord) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(s.recordsTitle).font(.title3.weight(.semibold))
                if records.isEmpty {
                    Text(s.recordsEmpty)
                        .font(.callout).foregroundStyle(CoachStyle.textSecondary)
                        .coachCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                            Button { onOpen(record) } label: { row(record) }
                                .buttonStyle(.plain)
                            if index < records.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .coachGroup()
                }

                if let exportURL, !records.isEmpty {
                    ShareLink(item: exportURL) {
                        Label(s.exportRecords, systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(CoachSecondaryButton())
                    Text(s.exportHint).font(.caption).foregroundStyle(CoachStyle.textTertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(CoachStyle.background)
        .navigationTitle(s.appTitle)
        .safeAreaInset(edge: .bottom) {
            Button(action: onNew) { Label(s.newAnalysis, systemImage: "plus") }
                .buttonStyle(CoachPrimaryButton())
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(CoachStyle.background)
        }
    }

    private func row(_ record: BetaRecord) -> some View {
        HStack(spacing: 12) {
            Circle().fill(record.verdict.betaColor).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.verdictTitle(record.verdict)).font(.body.weight(.semibold))
                    .foregroundStyle(CoachStyle.text)
                Text(s.dateText(record.createdAt)).font(.caption).foregroundStyle(CoachStyle.textSecondary)
            }
            Spacer()
            if !record.verdict.isJudgedVerdict {
                Text(RefusalGuidance(refusal: record.refusal, language: s.language).category.shortLabel(s.language))
                    .font(.caption).foregroundStyle(CoachStyle.textTertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(CoachStyle.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

extension SwingPathAnalyzer.Verdict {
    var isJudgedVerdict: Bool { self != .cannotJudge }
}

extension RefusalGuidance.Category {
    func shortLabel(_ language: BetaLanguage) -> String {
        let zh = language == .zh
        switch self {
        case .cameraOffLine:  return zh ? "机位偏离" : "Camera off line"
        case .trackingLost:   return zh ? "跟踪丢失" : "Tracking lost"
        case .wristsHidden:   return zh ? "手腕看不清" : "Wrists hidden"
        case .bodyNotInFrame: return zh ? "身体不完整" : "Body cut off"
        case .swingNotFound:  return zh ? "没找到挥杆" : "No swing found"
        }
    }
}

// MARK: - Analysing

@MainActor
struct BetaAnalysingView: View {
    @Environment(SwingLibrary.self) private var library
    @Environment(\.betaStrings) private var s
    let item: PhotosPickerItem
    var onDone: (BetaRecord) -> Void
    var onCancel: () -> Void
    @State private var progress: Double = 0
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            if let error {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(CoachStyle.alert)
                Text(s.analysisFailed).font(.headline)
                Text(error).font(.callout).foregroundStyle(CoachStyle.textSecondary).multilineTextAlignment(.center)
                Button(s.tryAgain, action: onCancel).buttonStyle(CoachSecondaryButton())
            } else {
                ProgressView(value: progress).tint(CoachStyle.accent)
                Text(s.analysing).font(.headline)
                Text(s.analysingNote).font(.caption).foregroundStyle(CoachStyle.textSecondary)
                Button(s.cancel) { task?.cancel(); onCancel() }.buttonStyle(CoachSecondaryButton())
            }
            Spacer()
        }
        .padding(24)
        .background(CoachStyle.background)
        .navigationBarBackButtonHidden(true)
        .onAppear { if task == nil { start() } }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        task = Task {
            do {
                guard let movie = try await item.loadTransferable(type: VideoFile.self) else {
                    throw AnalysisError.noFramesProduced
                }
                let record = try await BetaAnalysisRunner.analyse(videoURL: movie.url, library: library) { p in
                    progress = p
                }
                try? FileManager.default.removeItem(at: movie.url)
                onDone(record)
            } catch is CancellationError {
            } catch AnalysisError.cancelled {
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
