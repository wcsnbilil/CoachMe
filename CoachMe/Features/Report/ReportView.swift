import SwiftUI
import CoachMeCore

/// 当前值 → 动作阶段 → 教练参考范围 → 偏差 → 解释与建议。
///
/// Every line traces back to a metric definition and a video timestamp. Metrics
/// with no coach rule are listed explicitly as 「暂无参考范围」 rather than being
/// omitted, so the report never implies coverage it does not have.
@MainActor
struct ReportView: View {
    @Environment(SwingLibrary.self) private var library
    let swing: SwingRecord

    @State private var findings: [RuleFinding] = []
    @State private var uncovered: [MetricID] = []
    @State private var unavailable: [(MetricID, BodySide?, SwingPhase, MetricUnavailableReason)] = []
    @State private var showingChat = false

    var body: some View {
        List {
            headerSection

            if swing.keyframes.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("尚未标记动作阶段", systemImage: "mappin.slash")
                    } description: {
                        Text("规则按动作阶段生效。请先在分析工作台标记准备姿势等关键帧。")
                    }
                }
            }

            if !findings.isEmpty {
                Section("对照教练参考范围") {
                    ForEach(findings) { finding in FindingRow(finding: finding) }
                }
            }

            if !unavailable.isEmpty {
                Section("数据质量：无法评价的项目") {
                    ForEach(unavailable.indices, id: \.self) { index in
                        let (metric, side, phase, reason) = unavailable[index]
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(MetricCatalog.definition(for: metric).nameZH)"
                                 + (side.map { " · \($0 == .left ? "左" : "右")" } ?? "")
                                 + " · \(phase.nameZH)")
                                .font(.subheadline)
                            Label(reason.localizedZH, systemImage: "minus.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if !uncovered.isEmpty {
                Section("暂无参考范围") {
                    ForEach(uncovered, id: \.self) { metric in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MetricCatalog.definition(for: metric).nameZH).font(.subheadline)
                            Text("你还没有为这个指标设置参考范围。App 不会代为填入任何标准值。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("测量限制") {
                ForEach(SwingAnalysisContext.standingLimitationsZH, id: \.self) { line in
                    Label(line, systemImage: "info.circle")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
            }

            Section {
                Button {
                    showingChat = true
                } label: {
                    Label("与 AI 教练讨论", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
        }
        .navigationTitle("分析报告")
        .navigationBarTitleDisplayMode(.inline)
        .task { rebuild() }
        .sheet(isPresented: $showingChat) {
            if let cache = library.analysis(for: swing) {
                let timeline = MetricTimeline(poseFrames: cache.frames, record: swing)
                ChatPanelView(swing: swing,
                              phase: nil,
                              timestamp: 0,
                              context: Self.context(swing: swing, timeline: timeline, rules: library.rules))
            }
        }
    }

    private var headerSection: some View {
        Section {
            LabeledContent("持杆手", value: swing.handedness == .rightHanded ? "右手" : "左手")
            LabeledContent("球杆", value: swing.club.nameZH)
            LabeledContent("拍摄视角", value: swing.cameraView.nameZH)
            LabeledContent("已标记阶段",
                           value: swing.keyframes.orderedPhases.map(\.nameZH).joined(separator: "、"))
            LabeledContent("算法版本", value: swing.algorithmVersion)
            LabeledContent("姿态模型", value: swing.poseModelIdentifier)
            LabeledContent("分析版本", value: "第 \(swing.analysisVersion) 次")
        } header: {
            Text(swing.title)
        } footer: {
            Text("以上版本信息用于追溯：更换模型或修改算法后，旧报告的数字仍可被正确解释。")
        }
    }

    private func rebuild() {
        guard let cache = library.analysis(for: swing) else { return }
        let timeline = MetricTimeline(poseFrames: cache.frames, record: swing)
        let byPhase = timeline.metricsByPhase(swing.keyframes)
        let engine = RuleEngine()

        findings = engine.findings(rules: library.rules,
                                   metricsByPhase: byPhase,
                                   handedness: swing.handedness,
                                   club: swing.club,
                                   view: swing.cameraView)
        uncovered = engine.metricsWithoutRules(rules: library.rules, metricsByPhase: byPhase)
            .filter { $0 != .wristPathBodyReferenced }

        var missing: [(MetricID, BodySide?, SwingPhase, MetricUnavailableReason)] = []
        for (phase, metrics) in byPhase {
            for id in MetricID.allCases where id != .wristPathBodyReferenced {
                let sides: [BodySide?] = MetricCatalog.isBilateral(id) ? [nil] : [.left, .right]
                for side in sides {
                    if case .unavailable(let reason) = metrics.outcome(id, side) {
                        missing.append((id, side, phase, reason))
                    }
                }
            }
        }
        unavailable = missing.sorted { $0.2.order < $1.2.order }
    }

    static func context(swing: SwingRecord, timeline: MetricTimeline, rules: [CoachRule]) -> SwingAnalysisContext {
        // Reuses the workbench builder shape; report entry has no selected frame.
        let model = WorkbenchModelContextShim(swing: swing, timeline: timeline)
        return model.build(rules: rules)
    }
}

@MainActor
struct FindingRow: View {
    let finding: RuleFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(finding.definition.nameZH).font(.subheadline.bold())
                Spacer()
                Text(finding.phase.nameZH).font(.caption).foregroundStyle(.secondary)
            }

            switch finding.evaluation {
            case .inRange(let value):
                Label("\(value, specifier: "%.1f")\(finding.definition.unit) · 在你设置的范围内",
                      systemImage: "checkmark.circle")
                    .font(.subheadline)

            case .outOfRange(let value, let deviation, let direction):
                Label("\(value, specifier: "%.1f")\(finding.definition.unit) · \(direction.nameZH)参考范围 \(deviation, specifier: "%.1f")\(finding.definition.unit)",
                      systemImage: "arrow.up.arrow.down.circle")
                    .font(.subheadline)
                Text("这表示数值超出了你为此情境设置的范围，并不等于动作一定错误。")
                    .font(.caption2).foregroundStyle(.secondary)
                if !finding.rule.outOfRangeExplanation.isEmpty {
                    Text(finding.rule.outOfRangeExplanation).font(.caption)
                }
                if !finding.rule.drillSuggestion.isEmpty {
                    Label(finding.rule.drillSuggestion, systemImage: "figure.golf")
                        .font(.caption)
                }

            case .noReferenceRange:
                Label("暂无参考范围", systemImage: "questionmark.circle").font(.subheadline)

            case .notApplicable(let reason):
                Label(reason.nameZH, systemImage: "slash.circle").font(.subheadline)

            case .dataQualityInsufficient(let reason):
                Label("无法可靠计算", systemImage: "minus.circle").font(.subheadline)
                Text(reason.localizedZH).font(.caption2).foregroundStyle(.secondary)

            case .definitionMismatch:
                Label("指标定义已更新，旧参考范围不再适用", systemImage: "exclamationmark.arrow.circlepath")
                    .font(.subheadline)
                Text("请重新确认这条规则的范围是否仍然成立，然后重新保存。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(String(format: "第 %.3f 秒", finding.timestampSeconds))
                if !finding.rule.sourceNote.isEmpty {
                    Text("· 来源：\(finding.rule.sourceNote)")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Small adapter so the report can build the same context object the workbench
/// does without owning a playback controller.
@MainActor
struct WorkbenchModelContextShim {
    let swing: SwingRecord
    let timeline: MetricTimeline

    func build(rules: [CoachRule]) -> SwingAnalysisContext {
        let byPhase = timeline.metricsByPhase(swing.keyframes)
        var readings: [SwingAnalysisContext.MetricReading] = []
        for (phase, metrics) in byPhase.sorted(by: { $0.key.order < $1.key.order }) {
            for id in MetricID.allCases where id != .wristPathBodyReferenced {
                let definition = MetricCatalog.definition(for: id)
                let sides: [BodySide?] = MetricCatalog.isBilateral(id) ? [nil] : [.left, .right]
                for side in sides {
                    let outcome = metrics.outcome(id, side)
                    let rule = rules.first {
                        $0.metricID == id && $0.phases.contains(phase)
                            && $0.views.contains(swing.cameraView)
                            && $0.side.resolve(handedness: swing.handedness) == side
                    }
                    readings.append(.init(
                        metricID: id, nameZH: definition.nameZH, side: side, phase: phase,
                        timestampSeconds: metrics.timestampSeconds, value: outcome.value,
                        unit: definition.unit,
                        unavailableReason: { if case .unavailable(let r) = outcome { return r }; return nil }(),
                        space: definition.space, definitionFormula: definition.formula,
                        definitionHash: definition.definitionHash, caveatZH: definition.caveatZH,
                        coachRange: rule.map { r in
                            .init(lowerBound: r.lowerBound, upperBound: r.upperBound, unit: r.unit,
                                  sourceNote: r.sourceNote, coachNote: r.coachNote,
                                  outOfRangeExplanation: r.outOfRangeExplanation,
                                  drillSuggestion: r.drillSuggestion,
                                  appliesToPhases: r.phases.sorted { $0.order < $1.order },
                                  appliesToViews: Array(r.views))
                        }))
                }
            }
        }
        let quality = SwingAnalysisContext.QualitySummary(
            framesAnalysed: timeline.frames.count,
            framesWithNoPerson: timeline.frames.filter { $0.quality.blockingReason == .noPersonDetected }.count,
            framesWithMultiplePeople: timeline.frames.filter { $0.quality.blockingReason == .multiplePeople }.count,
            metricsUnavailable: readings.filter { $0.value == nil }.map { "\($0.nameZH)@\($0.phase.nameZH)" },
            statedLimitationsZH: SwingAnalysisContext.standingLimitationsZH)

        return SwingAnalysisContext(
            swingID: swing.id, analysisVersion: swing.analysisVersion,
            handedness: swing.handedness, club: swing.club, cameraView: swing.cameraView,
            markedPhases: swing.keyframes.orderedPhases, selectedPhase: nil,
            selectedTimestampSeconds: nil, readings: readings, quality: quality, comparison: nil)
    }
}
