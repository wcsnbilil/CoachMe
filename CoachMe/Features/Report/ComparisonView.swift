import SwiftUI
import CoachMeCore

/// Two swings side by side, aligned on the phases both have confirmed.
///
/// All numbers come from `SwingComparison`, which only subtracts values that
/// share a metric definition and unit. Caveats it raises are shown above the
/// table and travel with the data into the AI coach.
@MainActor
struct ComparisonView: View {
    @Environment(SwingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let swing: SwingRecord

    @State private var otherID: UUID?
    @State private var thisContext: SwingAnalysisContext?
    @State private var summary: SwingAnalysisContext.ComparisonSummary?
    @State private var showingChat = false

    private var candidates: [SwingRecord] {
        library.swings.filter { other in
            other.id != swing.id && library.hasAnalysis(for: other)
                && other.keyframes.contains { $0.markedByCoach }
        }
    }

    private var other: SwingRecord? { candidates.first { $0.id == otherID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    picker
                    if let summary, other != nil {
                        if !summary.warningsZH.isEmpty { warnings(summary.warningsZH) }
                        ForEach(summary.alignedPhases) { phase in
                            phaseSection(phase, deltas: summary.deltas.filter { $0.phase == phase })
                        }
                        Text("差值 = 本次 − 对比挥杆。只比较双方都已复核的阶段；缺失或无法可靠计算的读数显示为 —，不参与差值。差值只说明数值变化，不代表动作变好或变差。")
                            .font(.caption)
                            .foregroundStyle(CoachStyle.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(CoachStyle.background)
            .navigationTitle("挥杆对比")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CoachStyle.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let summary, !summary.alignedPhases.isEmpty {
                    Button { showingChat = true } label: {
                        Label("让 AI 教练解读这次对比", systemImage: "sparkles")
                    }
                    .buttonStyle(CoachPrimaryButton())
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .background(CoachStyle.background)
                }
            }
        }
        .onChange(of: otherID) { _, _ in rebuild() }
        .sheet(isPresented: $showingChat) {
            if let thisContext, let summary {
                ChatPanelView(swing: swing, phase: nil, timestamp: swing.clipStartSeconds,
                              context: thisContext.withComparison(summary),
                              initialQuestion: "请对比这两次挥杆在各阶段的变化，指出最值得注意的差异，以及下一次练习该关注什么。")
            }
        }
    }

    // MARK: - Picker

    @ViewBuilder
    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("选择要对比的挥杆")
            if candidates.isEmpty {
                Text("还没有其他已分析并复核过关键帧的挥杆。先导入另一段视频，在工作台复核关键帧后再来对比。")
                    .font(.footnote)
                    .foregroundStyle(CoachStyle.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .coachCard(padding: 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { GroupDivider() }
                        Button { otherID = candidate.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.title).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(CoachStyle.text)
                                    Text("\(candidate.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(candidate.cameraView.nameZH)")
                                        .font(.caption)
                                        .foregroundStyle(CoachStyle.textSecondary)
                                }
                                Spacer()
                                if candidate.id == otherID {
                                    Image(systemName: "checkmark").foregroundStyle(CoachStyle.accent)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .coachGroup()
            }
        }
    }

    // MARK: - Results

    private func warnings(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(CoachStyle.pending)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CoachStyle.pendingFill, in: RoundedRectangle(cornerRadius: 16))
    }

    private func phaseSection(_ phase: SwingPhase,
                              deltas: [SwingAnalysisContext.ComparisonSummary.PhaseDelta]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(phase.nameZH)
            VStack(spacing: 0) {
                HStack {
                    Text("指标").frame(maxWidth: .infinity, alignment: .leading)
                    Text("本次").frame(width: 58, alignment: .trailing)
                    Text("对比").frame(width: 58, alignment: .trailing)
                    Text("差值").frame(width: 62, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(CoachStyle.textTertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                ForEach(Array(deltas.enumerated()), id: \.offset) { _, delta in
                    GroupDivider()
                    row(delta)
                }
            }
            .coachGroup()
        }
    }

    private func row(_ delta: SwingAnalysisContext.ComparisonSummary.PhaseDelta) -> some View {
        let definition = MetricCatalog.definition(for: delta.metricID)
        func text(_ value: Double?, signed: Bool = false) -> String {
            guard let value else { return "—" }
            return String(format: signed ? "%+.1f%@" : "%.1f%@", value, definition.unit)
        }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(definition.nameZH).font(.subheadline)
                Text(ReportRow.sideName(delta.metricID, delta.side, swing.handedness))
                    .font(.caption2)
                    .foregroundStyle(CoachStyle.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(text(delta.thisValue)).frame(width: 58, alignment: .trailing)
            Text(text(delta.otherValue)).frame(width: 58, alignment: .trailing)
            Text(text(delta.delta, signed: true))
                .fontWeight(.semibold)
                .foregroundStyle(delta.delta == nil ? CoachStyle.textTertiary : CoachStyle.text)
                .frame(width: 62, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Data

    private func rebuild() {
        guard let other,
              let thisCache = library.analysis(for: swing),
              let otherCache = library.analysis(for: other) else {
            summary = nil
            return
        }
        // Same builder the report uses, so the numbers match the report exactly.
        let mine = ReportView.context(swing: swing,
                                      timeline: MetricTimeline(poseFrames: thisCache.smoothedFrames(), record: swing),
                                      rules: library.rules)
        let theirs = ReportView.context(swing: other,
                                        timeline: MetricTimeline(poseFrames: otherCache.smoothedFrames(), record: other),
                                        rules: library.rules)
        thisContext = mine
        summary = SwingComparison.summary(this: mine, other: theirs)
    }
}
