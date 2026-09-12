import SwiftUI
import CoachMeCore

/// 当前值 → 动作阶段 → 教练参考范围 → 偏差 → 解释与建议。
///
/// Every line traces back to a metric definition and a video timestamp. Metrics
/// with no coach rule are counted and listed as 「未设置参考范围」 rather than
/// omitted, so the report never implies coverage it does not have.
@MainActor
struct ReportView: View {
    @Environment(SwingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let swing: SwingRecord
    /// Seeks the workbench to a frame. Nil when the report was opened on its own.
    var onJump: ((Double) -> Void)?
    var analysisContext: SwingAnalysisContext? = nil

    @State private var sections: [ReportSection] = []
    @State private var detail: ReportRow?
    @State private var expanded: Set<String> = []
    @State private var showingChat = false
    @State private var discussion: ReportRow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                summaryCard

                if !swing.keyframes.isEmpty {
                    overview.padding(.top, 24)
                }

                ForEach(sections) { section in
                    sectionView(section).padding(.top, 22)
                }

                limitations.padding(.top, 22)
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(CoachStyle.background)
        .navigationTitle("分析报告")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(CoachStyle.background, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            Button { discussion = nil; showingChat = true } label: {
                Label("与 AI 教练讨论这份报告", systemImage: "sparkles")
            }
            .buttonStyle(CoachPrimaryButton())
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(CoachStyle.background.overlay(alignment: .top) {
                Rectangle().fill(CoachStyle.line).frame(height: 1)
            })
        }
        .task { rebuild() }
        .sheet(item: $detail, onDismiss: { if discussion != nil { showingChat = true } }) { row in
            MetricDetailSheet(row: row, swing: swing,
                              onJump: onJump.map { jump in { detail = nil; jump(row.time) } },
                              onDiscuss: { discussion = row; detail = nil })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingChat) {
            if let cache = library.analysis(for: swing) {
                let timeline = MetricTimeline(poseFrames: cache.smoothedFrames(), record: swing)
                ChatPanelView(swing: swing, phase: discussion?.phase, timestamp: discussion?.time ?? swing.clipStartSeconds,
                              context: analysisContext ?? Self.context(swing: swing, timeline: timeline, rules: library.rules),
                              onJump: onJump.map { jump in { time in showingChat = false; jump(time) } },
                              initialQuestion: discussion?.coachingQuestion)
            }
        }
    }

    // MARK: - Summary

    private var pending: [Keyframe] {
        swing.keyframes.filter { !$0.markedByCoach }.sorted { $0.phase.order < $1.phase.order }
    }

    private var pendingText: String {
        if pending.count == swing.keyframes.count {
            return "\(pending.count) 个关键帧都还没复核，相关结果可能随复核改变。"
        }
        let names = pending.count <= 3 ? "（\(pending.map(\.phase.nameZH).joined(separator: "、"))）" : ""
        return "\(pending.count) 个关键帧待复核\(names)，相关结果可能随复核改变。"
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                VideoFrameImage(url: library.videoURL(for: swing),
                                time: swing.keyframes.keyframe(for: .top)?.timestampSeconds ?? swing.clipStartSeconds)
                    .frame(width: 64, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(swing.title).font(.headline)
                    Text("\(swing.handedness == .rightHanded ? "右手" : "左手") · \(swing.cameraView.nameZH) · \(String(format: "%.2f 秒", swing.durationSeconds))")
                        .font(.footnote)
                        .foregroundStyle(CoachStyle.textSecondary)
                    Text("本机分析 · 第 \(swing.analysisVersion) 次分析")
                        .font(.caption)
                        .foregroundStyle(CoachStyle.textTertiary)
                }
            }
            reviewBanner
        }
        .coachCard(padding: 14)
    }

    @ViewBuilder
    private var reviewBanner: some View {
        if swing.keyframes.isEmpty {
            banner(status: .unmarked, text: "尚未标记动作阶段。规则按动作阶段生效，请先在工作台标记关键帧。", action: nil)
        } else if !pending.isEmpty {
            banner(status: .pending,
                   text: pendingText,
                   action: ("去复核", {
                       if let onJump, let first = pending.first { onJump(first.timestampSeconds) } else { dismiss() }
                   }))
        } else {
            banner(status: .confirmed, text: "关键帧均已确认，以下结果基于已确认的画面。", action: nil)
        }
    }

    private func banner(status: CoachStatus, text: String, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbol).font(.footnote.weight(.bold))
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action.0, action: action.1)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
        .foregroundStyle(status.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, action == nil ? 10 : 0)
        .background(status.fill, in: RoundedRectangle(cornerRadius: 12))
    }

    private var overview: some View {
        let rows = sections.flatMap { $0.rows + $0.unavailable + $0.uncovered }
        func count(_ status: CoachStatus) -> Int { rows.filter { $0.status == status }.count }
        return VStack(alignment: .leading, spacing: 10) {
            Text("对照参考范围").font(.title3.weight(.semibold))
            FlowLayout(spacing: 6) {
                StatusTag(status: .outOfRange, text: "超出已设参考范围 \(count(.outOfRange))")
                StatusTag(status: .inRange, text: "在参考范围内 \(count(.inRange))")
                StatusTag(status: .noRange, text: "未设置参考范围 \(count(.noRange))")
                StatusTag(status: .unavailable, text: "无法可靠计算 \(count(.unavailable))")
            }
            Text("参考范围来自你设置的教练规则，App 不内置任何“正确”角度。超出范围只表示数值不在所设范围内，不等于动作错误。")
                .font(.caption)
                .foregroundStyle(CoachStyle.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sections

    private func sectionView(_ section: ReportSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(section.keyframe.phase.nameZH).font(.headline)
                Text(String(format: "%.2f 秒", section.keyframe.timestampSeconds - swing.clipStartSeconds))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(CoachStyle.textTertiary)
                StatusTag(status: section.keyframe.markedByCoach ? .confirmed : .pending)
                Spacer(minLength: 0)
                if let onJump {
                    Button { onJump(section.keyframe.timestampSeconds) } label: {
                        Label("回到对应帧", systemImage: "play.rectangle")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { GroupDivider(inset: 16) }
                    rowButton(row)
                }
                collapsed(section.unavailable, status: .unavailable,
                          title: "\(section.unavailable.count) 项无法可靠计算",
                          key: "\(section.id.rawValue)-na", divider: !section.rows.isEmpty)
                collapsed(section.uncovered, status: .noRange,
                          title: "\(section.uncovered.count) 项未设置参考范围",
                          key: "\(section.id.rawValue)-none",
                          divider: !section.rows.isEmpty || !section.unavailable.isEmpty)
            }
            .coachGroup()
        }
    }

    /// Metrics without a usable rule, folded so rule results stay at the top.
    @ViewBuilder
    private func collapsed(_ rows: [ReportRow], status: CoachStatus, title: String, key: String, divider: Bool) -> some View {
        if !rows.isEmpty {
            if divider { GroupDivider(inset: 16) }
            let open = expanded.contains(key)
            Button {
                withAnimation(.snappy) { if open { expanded.remove(key) } else { expanded.insert(key) } }
            } label: {
                HStack {
                    StatusTag(status: status, text: title)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CoachStyle.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(rows) { row in
                    GroupDivider(inset: 16)
                    rowButton(row)
                }
            }
        }
    }

    private func rowButton(_ row: ReportRow) -> some View {
        Button { discussion = nil; detail = row } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        (Text(row.name) + Text(" · \(row.sideName)").foregroundStyle(CoachStyle.textTertiary))
                            .font(.subheadline)
                        Spacer(minLength: 10)
                        Text(row.valueText)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(row.status == .outOfRange ? CoachStyle.alert
                                             : (row.status == .unavailable ? CoachStyle.textTertiary : CoachStyle.text))
                    }
                    HStack {
                        StatusTag(status: row.status, text: row.statusText)
                        Spacer(minLength: 8)
                        if let aside = row.aside {
                            Text(aside).font(.caption.monospacedDigit()).foregroundStyle(CoachStyle.textSecondary)
                        }
                    }
                    Text(row.note)
                        .font(.caption)
                        .foregroundStyle(CoachStyle.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(CoachStyle.textTertiary)
            }
            .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var limitations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("测量限制").font(.subheadline.weight(.semibold))
            ForEach(SwingAnalysisContext.standingLimitationsZH, id: \.self) { line in
                Text("· " + line)
                    .font(.caption)
                    .foregroundStyle(CoachStyle.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("算法 \(swing.algorithmVersion) · 姿态模型 \(swing.poseModelIdentifier) · 第 \(swing.analysisVersion) 次分析")
                .font(.caption2)
                .foregroundStyle(CoachStyle.textTertiary)
                .padding(.top, 2)
        }
        .coachCard()
    }

    // MARK: - Data

    private func rebuild() {
        guard let cache = library.analysis(for: swing) else { return }
        // Same smoothed landmarks as the workbench, so both show the same numbers.
        let timeline = MetricTimeline(poseFrames: cache.smoothedFrames(), record: swing)
        let byPhase = timeline.metricsByPhase(swing.keyframes)
        let findings = RuleEngine().findings(rules: library.rules, metricsByPhase: byPhase,
                                             handedness: swing.handedness, club: swing.club, view: swing.cameraView)

        sections = swing.keyframes.sorted { $0.phase.order < $1.phase.order }.compactMap { keyframe in
            guard let metrics = byPhase[keyframe.phase] else { return nil }
            var rows: [ReportRow] = [], unavailable: [ReportRow] = [], uncovered: [ReportRow] = []
            for id in MetricID.allCases where id != .wristPathBodyReferenced {
                let sides: [BodySide?] = MetricCatalog.isBilateral(id)
                    ? [nil] : [swing.handedness.leadSide, swing.handedness.trailSide]
                for side in sides {
                    let row = ReportRow.make(metric: id, side: side, phase: keyframe.phase,
                                             time: keyframe.timestampSeconds, outcome: metrics.outcome(id, side),
                                             finding: findings.first { $0.definition.id == id && $0.phase == keyframe.phase && $0.side == side },
                                             handedness: swing.handedness)
                    switch row.status {
                    case .noRange: uncovered.append(row)
                    case .unavailable: unavailable.append(row)
                    default: rows.append(row)
                    }
                }
            }
            return ReportSection(keyframe: keyframe, rows: rows, unavailable: unavailable, uncovered: uncovered)
        }
    }

    static func context(swing: SwingRecord, timeline: MetricTimeline, rules: [CoachRule]) -> SwingAnalysisContext {
        // Reuses the workbench builder shape; report entry has no selected frame.
        WorkbenchModelContextShim(swing: swing, timeline: timeline).build(rules: rules)
    }
}

struct ReportSection: Identifiable {
    var id: SwingPhase { keyframe.phase }
    let keyframe: Keyframe
    let rows: [ReportRow]
    let unavailable: [ReportRow]
    let uncovered: [ReportRow]
}

/// One metric at one phase, with the rule (if any) it was compared against.
struct ReportRow: Identifiable {
    let id = UUID()
    let metric: MetricID
    let phase: SwingPhase
    let time: Double
    let name: String
    let sideName: String
    let status: CoachStatus
    let statusText: String
    let value: Double?
    let valueText: String
    let aside: String?
    let note: String
    let rule: CoachRule?

    var coachingQuestion: String {
        "请结合挥杆画面，解释\(phase.nameZH)时的\(sideName)\(name)（读数\(valueText)，\(statusText)），以及下一次练习该关注什么。"
    }

    static func sideName(_ metric: MetricID, _ side: BodySide?, _ handedness: Handedness) -> String {
        guard let side else { return "双侧" }
        let lead = side == handedness.leadSide
        if metric == .kneeInteriorAngle { return lead ? "引导侧" : "后侧" }
        return lead ? "引导臂" : "后侧臂"
    }

    static func make(metric: MetricID, side: BodySide?, phase: SwingPhase, time: Double,
                     outcome: MetricOutcome, finding: RuleFinding?, handedness: Handedness) -> ReportRow {
        let definition = MetricCatalog.definition(for: metric)
        let value = outcome.value
        let valueText = value.map { String(format: "%.1f%@", $0, definition.unit) } ?? "—"
        func row(_ status: CoachStatus, _ text: String? = nil, aside: String? = nil, note: String, rule: CoachRule? = nil) -> ReportRow {
            ReportRow(metric: metric, phase: phase, time: time, name: definition.nameZH,
                      sideName: sideName(metric, side, handedness), status: status,
                      statusText: text ?? status.label, value: value, valueText: valueText,
                      aside: aside, note: note, rule: rule)
        }
        guard let finding else {
            if case .unavailable(let reason) = outcome { return row(.unavailable, note: reason.localizedZH) }
            return row(.noRange, note: "可在教练规则中添加参考范围")
        }
        let rule = finding.rule
        let rangeNote = "参考 \(rangeText(rule))" + (rule.sourceNote.isEmpty ? "" : " · 来源：\(rule.sourceNote)")
        switch finding.evaluation {
        case .inRange:
            return row(.inRange, note: rangeNote, rule: rule)
        case .outOfRange(_, let deviation, let direction):
            let bound = direction == .below ? "下限" : "上限"
            return row(.outOfRange, aside: String(format: "%@%@ %.1f%@", direction.nameZH, bound, deviation, definition.unit),
                       note: rangeNote, rule: rule)
        case .noReferenceRange:
            return row(.noRange, note: "规则没有设置上下限", rule: rule)
        case .notApplicable(let reason):
            return row(.noRange, note: reason.nameZH, rule: rule)
        case .dataQualityInsufficient(let reason):
            return row(.unavailable, note: reason.localizedZH, rule: rule)
        case .definitionMismatch:
            return row(.incomplete, "指标定义已更新", note: "旧参考范围不再适用，请在教练规则中重新确认。", rule: rule)
        }
    }

    static func rangeText(_ rule: CoachRule) -> String {
        switch (rule.lowerBound, rule.upperBound) {
        case let (lower?, upper?): return "\(lower.formatted())–\(upper.formatted())\(rule.unit)"
        case let (lower?, nil): return "≥ \(lower.formatted())\(rule.unit)"
        case let (nil, upper?): return "≤ \(upper.formatted())\(rule.unit)"
        default: return "未设置"
        }
    }
}

/// Definition, source and conditions behind one report line.
@MainActor
struct MetricDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let row: ReportRow
    let swing: SwingRecord
    let onJump: (() -> Void)?
    let onDiscuss: () -> Void

    private var definition: MetricDefinition { MetricCatalog.definition(for: row.metric) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(row.name) · \(row.sideName)").font(.title3.weight(.semibold))
                        Text("\(row.phase.nameZH) · " + String(format: "%.2f 秒", row.time - swing.clipStartSeconds))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(CoachStyle.textSecondary)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(CoachStyle.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(CoachStyle.fill, in: Circle())
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("关闭")
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.valueText).font(.system(size: 34, weight: .semibold).monospacedDigit())
                        StatusTag(status: row.status, text: row.statusText)
                        if let aside = row.aside {
                            Text(aside).font(.footnote.monospacedDigit()).foregroundStyle(CoachStyle.textSecondary)
                        }
                    }
                    if let rule = row.rule, rule.hasUsableRange, let value = row.value {
                        RangeScale(value: value,
                                   lower: rule.lowerBound ?? definition.range.lowerBound,
                                   upper: rule.upperBound ?? definition.range.upperBound,
                                   outside: row.status == .outOfRange, unit: definition.unit)
                    }
                }
                .coachCard()

                VStack(spacing: 0) {
                    item("定义", "\(definition.zeroAndSignZH)。参考系：\(definition.referenceFrameZH)。")
                    GroupDivider()
                    item("注意", definition.caveatZH)
                    GroupDivider()
                    item("参考来源", row.rule.map { $0.sourceNote.isEmpty ? "教练规则未填写来源" : $0.sourceNote }
                         ?? "未设置参考范围。可在“教练规则”中为这个指标添加范围、来源和适用条件。")
                    if let rule = row.rule {
                        GroupDivider()
                        item("适用条件", conditions(rule))
                        if row.status == .outOfRange, !(rule.outOfRangeExplanation + rule.drillSuggestion).isEmpty {
                            GroupDivider()
                            item("教练说明", [rule.outOfRangeExplanation, rule.drillSuggestion].filter { !$0.isEmpty }.joined(separator: "\n"))
                        }
                    }
                }
                .coachGroup()

                Text("超出范围只表示数值不在你设置的范围内，并不等于动作错误。")
                    .font(.caption)
                    .foregroundStyle(CoachStyle.textTertiary)

                HStack(spacing: 10) {
                    if let onJump {
                        Button("回到对应帧", action: onJump).buttonStyle(CoachSecondaryButton(height: 50))
                    }
                    Button("与 AI 教练讨论", action: onDiscuss).buttonStyle(CoachPrimaryButton(height: 50))
                }
            }
            .padding(18)
        }
        .background(CoachStyle.background)
    }

    private func item(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(CoachStyle.textTertiary)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func conditions(_ rule: CoachRule) -> String {
        let clubs = rule.clubs.count == ClubType.allCases.count ? "所有球杆"
            : ClubType.allCases.filter(rule.clubs.contains).map(\.nameZH).joined(separator: "、")
        let views = rule.views.count == CameraView.allCases.count ? "所有视角"
            : CameraView.allCases.filter(rule.views.contains).map(\.nameZH).joined(separator: "、")
        let phases = SwingPhase.allCases.filter(rule.phases.contains).map(\.nameZH).joined(separator: "、")
        var parts = [rule.side.nameZH, clubs, views, phases]
        if !rule.studentConditionNote.isEmpty { parts.append(rule.studentConditionNote) }
        return parts.joined(separator: " · ")
    }
}

/// Horizontal scale: the coach range as a band, the measured value as a dot.
struct RangeScale: View {
    let value: Double
    let lower: Double
    let upper: Double
    let outside: Bool
    let unit: String

    var body: some View {
        GeometryReader { geometry in
            let low = min(lower, value) - 12, high = max(upper, value) + 12
            let x: (Double) -> CGFloat = { CGFloat(($0 - low) / max(high - low, 1)) * geometry.size.width }
            ZStack(alignment: .topLeading) {
                Capsule().fill(CoachStyle.fill).frame(height: 6).offset(y: 14)
                Capsule().fill(CoachStyle.accent.opacity(0.18))
                    .overlay(Capsule().strokeBorder(CoachStyle.accent, lineWidth: 1.5))
                    .frame(width: max(8, x(upper) - x(lower)), height: 12)
                    .offset(x: x(lower), y: 11)
                Circle().fill(outside ? CoachStyle.alert : CoachStyle.accent)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(CoachStyle.surface, lineWidth: 3))
                    .offset(x: x(value) - 8, y: 9)
                Text("\(lower.formatted())\(unit)").font(.caption2.monospacedDigit())
                    .foregroundStyle(CoachStyle.textSecondary)
                    .fixedSize()
                    .offset(x: x(lower) - 12, y: 28)
                Text("\(upper.formatted())\(unit)").font(.caption2.monospacedDigit())
                    .foregroundStyle(CoachStyle.textSecondary)
                    .fixedSize()
                    .offset(x: x(upper) - 12, y: 28)
            }
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("参考范围 \(lower.formatted()) 到 \(upper.formatted())\(unit)，测量值 \(value.formatted())\(unit)")
    }
}

/// Small adapter so the report can build the same context object the workbench
/// does without owning a playback controller.
@MainActor
struct WorkbenchModelContextShim {
    let swing: SwingRecord
    let timeline: MetricTimeline

    func build(rules: [CoachRule]) -> SwingAnalysisContext {
        let confirmed = swing.keyframes.filter { $0.markedByCoach }
        let byPhase = timeline.metricsByPhase(confirmed)
        var readings: [SwingAnalysisContext.MetricReading] = []
        for (phase, metrics) in byPhase.sorted(by: { $0.key.order < $1.key.order }) {
            for id in MetricID.allCases where id != .wristPathBodyReferenced {
                let definition = MetricCatalog.definition(for: id)
                let sides: [BodySide?] = MetricCatalog.isBilateral(id) ? [nil] : [.left, .right]
                for side in sides {
                    let outcome = metrics.outcome(id, side)
                    let rule = rules.first {
                        $0.isEnabled && $0.metricID == id && $0.phases.contains(phase)
                            && $0.views.contains(swing.cameraView)
                            && $0.clubs.contains(swing.club)
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
            markedPhases: confirmed.orderedPhases, selectedPhase: nil,
            selectedTimestampSeconds: nil, readings: readings, quality: quality, comparison: nil)
    }
}
