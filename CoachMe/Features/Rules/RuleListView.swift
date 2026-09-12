import SwiftUI
import CoachMeCore

@MainActor
struct RuleListView: View {
    @Environment(SwingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var editing: CoachRule?
    @State private var creating = false

    private var activeCount: Int { library.rules.filter { $0.isEnabled && !RuleCard.isStale($0) }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("App 不内置任何参考范围。每条规则由你或教练填写，会连同来源和适用条件一起出现在报告里。")
                        .font(.subheadline)
                        .foregroundStyle(CoachStyle.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !library.rules.isEmpty {
                        Text("\(library.rules.count) 条规则 · \(activeCount) 条正在应用")
                            .font(.footnote.weight(.semibold))
                    }
                }
                .padding(.horizontal, 4)

                if library.rules.isEmpty {
                    EmptyStateRow(icon: "slider.horizontal.3",
                                  title: "还没有规则",
                                  message: "新建一条，为某个指标在某个动作阶段设定你自己的参考范围。")
                        .coachCard()
                }

                ForEach(library.rules) { rule in
                    RuleCard(rule: rule, onEdit: { editing = rule }, onToggle: {
                        var updated = rule
                        updated.isEnabled.toggle()
                        updated.updatedAt = Date()
                        library.save(rule: updated)
                    })
                }

                Button { creating = true } label: { Label("新建规则", systemImage: "plus") }
                    .buttonStyle(CoachSecondaryButton())
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(CoachStyle.background)
        .navigationTitle("教练规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(CoachStyle.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建规则")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .sheet(item: $editing) { rule in
            NavigationStack { RuleEditorView(rule: rule) }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { RuleEditorView(rule: nil) }
        }
    }
}

@MainActor
struct RuleCard: View {
    let rule: CoachRule
    let onEdit: () -> Void
    let onToggle: () -> Void

    static func isStale(_ rule: CoachRule) -> Bool {
        rule.metricDefinitionHash != MetricCatalog.definition(for: rule.metricID).definitionHash
    }

    private var definition: MetricDefinition { MetricCatalog.definition(for: rule.metricID) }

    private var conditions: [String] {
        let phases = SwingPhase.allCases.filter(rule.phases.contains).map(\.nameZH)
        let clubs = rule.clubs.count == ClubType.allCases.count ? "所有球杆"
            : ClubType.allCases.filter(rule.clubs.contains).map(\.nameZH).joined(separator: "、")
        let views = rule.views.count == CameraView.allCases.count ? "所有视角"
            : CameraView.allCases.filter(rule.views.contains).map(\.nameZH).joined(separator: "、")
        return phases + [clubs, views]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onEdit) {
                    VStack(alignment: .leading, spacing: 4) {
                        (Text(definition.nameZH).fontWeight(.semibold)
                         + Text(" · \(rule.side.nameZH)").foregroundStyle(CoachStyle.textTertiary))
                            .font(.subheadline)
                        Text(rule.hasUsableRange ? ReportRow.rangeText(rule) : "未设置参考范围")
                            .font(.title2.weight(.semibold).monospacedDigit())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Toggle("启用规则", isOn: Binding(get: { rule.isEnabled }, set: { _ in onToggle() }))
                    .labelsHidden()
                    .tint(CoachStyle.accent)
            }

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 8) {
                    FlowLayout(spacing: 6) {
                        ForEach(conditions, id: \.self) { condition in
                            Text(condition)
                                .font(.caption)
                                .foregroundStyle(CoachStyle.text)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(CoachStyle.fill, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    Text("来源：" + (rule.sourceNote.isEmpty ? "未填写" : rule.sourceNote))
                        .font(.caption)
                        .foregroundStyle(CoachStyle.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if Self.isStale(rule) && rule.isEnabled {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("指标定义已更新，这条范围暂不应用。请确认后重新保存。")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("重新确认", action: onEdit)
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 36)
                }
                .foregroundStyle(CoachStyle.pending)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(CoachStyle.pendingFill, in: RoundedRectangle(cornerRadius: 12))
            }
            if !rule.isEnabled {
                Text("已停用 · 报告中不使用这条范围")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CoachStyle.textSecondary)
            }
        }
        .coachCard()
        .opacity(rule.isEnabled ? 1 : 0.62)
        .accessibilityElement(children: .contain)
    }
}

@MainActor
struct RuleEditorView: View {
    @Environment(SwingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    let rule: CoachRule?

    @State private var metricID: MetricID = .elbowInteriorAngle
    @State private var phases: Set<SwingPhase> = [.top]
    @State private var side: RuleSide = .leadArm
    @State private var clubs: Set<ClubType> = Set(ClubType.allCases)
    @State private var views: Set<CoachMeCore.CameraView> = Set(CoachMeCore.CameraView.allCases)
    @State private var hasLower = true
    @State private var hasUpper = true
    @State private var lower: Double = 150
    @State private var upper: Double = 175
    @State private var studentNote = ""
    @State private var sourceNote = ""
    @State private var coachNote = ""
    @State private var outOfRangeExplanation = ""
    @State private var drill = ""
    @State private var isEnabled = true
    @State private var showingDefinition = false
    @State private var confirmingDelete = false

    private var definition: MetricDefinition { MetricCatalog.definition(for: metricID) }

    private var sideOptions: [RuleSide] {
        MetricCatalog.isBilateral(metricID) ? [.bilateral] : [.leadArm, .trailArm, .left, .right]
    }

    /// A range without a source would look like a standard; the README forbids that.
    private var needsSource: Bool {
        (hasLower || hasUpper) && sourceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("指标")
                metricGroup

                SectionLabel("动作阶段").padding(.top, 14)
                VStack(alignment: .leading, spacing: 10) {
                    FlowLayout(spacing: 8) {
                        ForEach(SwingPhase.allCases) { phase in
                            ChoiceChip(title: phase.nameZH, selected: phases.contains(phase)) {
                                if phases.contains(phase) { phases.remove(phase) } else { phases.insert(phase) }
                            }
                        }
                    }
                    Text(phases.isEmpty ? "至少选择一个阶段，规则才会生效。" : "已选 \(phases.count) 个阶段，报告会在这些关键帧上对照这条范围。")
                        .font(.caption)
                        .foregroundStyle(phases.isEmpty ? CoachStyle.alert : CoachStyle.textTertiary)
                }
                .coachCard(padding: 14)

                SectionLabel("参考范围").padding(.top, 14)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        boundField("下限", enabled: $hasLower, value: $lower)
                        boundField("上限", enabled: $hasUpper, value: $upper)
                    }
                    if hasLower || hasUpper { rangePreview }
                    Text(hasLower || hasUpper ? "只设一侧边界也可以。" : "没有任何边界时，报告会显示“未设置参考范围”。")
                        .font(.caption)
                        .foregroundStyle(CoachStyle.textTertiary)
                }
                .coachCard()

                SectionLabel("来源（必填）").padding(.top, 14)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("例如：我自己对 30 名学员的观察", text: $sourceNote, axis: .vertical)
                    Text(needsSource ? "设置了参考范围时，请写明来源。" : "报告和 AI 教练引用这条范围时，会同时显示这里的来源。")
                        .font(.caption)
                        .foregroundStyle(needsSource ? CoachStyle.alert : CoachStyle.textTertiary)
                }
                .coachCard()

                SectionLabel("适用条件").padding(.top, 14)
                VStack(alignment: .leading, spacing: 12) {
                    Text("球杆").font(.footnote).foregroundStyle(CoachStyle.textTertiary)
                    FlowLayout(spacing: 8) {
                        ForEach(ClubType.allCases, id: \.self) { club in
                            ChoiceChip(title: club.nameZH, selected: clubs.contains(club)) {
                                if clubs.contains(club) { clubs.remove(club) } else { clubs.insert(club) }
                            }
                        }
                    }
                    Text("拍摄视角").font(.footnote).foregroundStyle(CoachStyle.textTertiary)
                    FlowLayout(spacing: 8) {
                        ForEach(CoachMeCore.CameraView.allCases, id: \.self) { view in
                            ChoiceChip(title: view.nameZH, selected: views.contains(view)) {
                                if views.contains(view) { views.remove(view) } else { views.insert(view) }
                            }
                        }
                    }
                    TextField("学员条件或教学目标（选填）", text: $studentNote, axis: .vertical)
                        .padding(.top, 4)
                }
                .coachCard()

                SectionLabel("说明与建议（选填）").padding(.top, 14)
                VStack(spacing: 0) {
                    TextField("超出范围时你想说明什么", text: $outOfRangeExplanation, axis: .vertical).padding(16)
                    GroupDivider()
                    TextField("对应练习建议", text: $drill, axis: .vertical).padding(16)
                    GroupDivider()
                    TextField("教练备注", text: $coachNote, axis: .vertical).padding(16)
                }
                .coachGroup()

                Toggle("启用这条规则", isOn: $isEnabled)
                    .tint(CoachStyle.accent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .coachGroup()
                    .padding(.top, 14)
                Text("超出范围只会表述为“超出已设参考范围”，不会表述为“动作错误”。")
                    .font(.caption)
                    .foregroundStyle(CoachStyle.textTertiary)
                    .padding(.horizontal, 4)

                if rule != nil {
                    Button("删除规则", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(CoachSecondaryButton(height: 50, tint: CoachStyle.alert))
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(CoachStyle.background)
        .navigationTitle(rule == nil ? "新建规则" : "编辑规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CoachStyle.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .fontWeight(.semibold)
                    .disabled(phases.isEmpty || needsSource)
            }
        }
        .onAppear(perform: load)
        .onChange(of: metricID) { _, id in
            if MetricCatalog.isBilateral(id) { side = .bilateral } else if side == .bilateral { side = .leadArm }
        }
        .confirmationDialog("删除这条规则？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除规则", role: .destructive) {
                if let rule { library.delete(rule: rule) }
                dismiss()
            }
        }
    }

    private var metricGroup: some View {
        VStack(spacing: 0) {
            HStack {
                Text("指标")
                Spacer()
                Picker("指标", selection: $metricID) {
                    ForEach(MetricID.allCases.filter { $0 != .wristPathBodyReferenced }, id: \.self) {
                        Text(MetricCatalog.definition(for: $0).nameZH).tag($0)
                    }
                }
                .labelsHidden()
                .tint(CoachStyle.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            GroupDivider()
            HStack {
                Text("侧别")
                Spacer()
                Picker("侧别", selection: $side) {
                    ForEach(sideOptions, id: \.self) { Text($0.nameZH).tag($0) }
                }
                .labelsHidden()
                .tint(CoachStyle.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            GroupDivider()
            Button { withAnimation(.snappy) { showingDefinition.toggle() } } label: {
                HStack {
                    Text("这个指标是怎么算的").foregroundStyle(CoachStyle.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CoachStyle.accent)
                        .rotationEffect(.degrees(showingDefinition ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showingDefinition {
                VStack(alignment: .leading, spacing: 6) {
                    definitionLine("公式", definition.formula)
                    definitionLine("参考系", definition.referenceFrameZH)
                    definitionLine("投影", definition.projectionZH)
                    definitionLine("零点与方向", definition.zeroAndSignZH)
                    definitionLine("范围", "\(definition.range.lowerBound.formatted()) – \(definition.range.upperBound.formatted()) \(definition.unit)")
                    Text(definition.caveatZH).font(.caption).foregroundStyle(CoachStyle.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            if definition.requiresAddressReference {
                GroupDivider()
                Label("需要先标记准备姿势关键帧，否则该指标不会有数值", systemImage: "mappin.circle")
                    .font(.caption)
                    .foregroundStyle(CoachStyle.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .coachGroup()
    }

    private func definitionLine(_ title: String, _ value: String) -> some View {
        (Text(title + "　").fontWeight(.semibold) + Text(value))
            .font(.caption)
            .foregroundStyle(CoachStyle.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func boundField(_ title: String, enabled: Binding<Bool>, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: enabled)
                .font(.footnote)
                .foregroundStyle(CoachStyle.textSecondary)
                .tint(CoachStyle.accent)
            HStack {
                TextField(title, value: value, format: .number)
                    .keyboardType(.decimalPad)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .disabled(!enabled.wrappedValue)
                Text(definition.unit).foregroundStyle(CoachStyle.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(CoachStyle.background, in: RoundedRectangle(cornerRadius: 12))
            .opacity(enabled.wrappedValue ? 1 : 0.4)
        }
        .frame(maxWidth: .infinity)
    }

    private var rangePreview: some View {
        GeometryReader { geometry in
            let low = definition.range.lowerBound, high = definition.range.upperBound
            let clamp: (Double) -> Double = { min(max($0, low), high) }
            let x: (Double) -> CGFloat = { CGFloat((clamp($0) - low) / max(high - low, 1)) * geometry.size.width }
            let from = hasLower ? lower : low, to = hasUpper ? upper : high
            ZStack(alignment: .topLeading) {
                Capsule().fill(CoachStyle.fill).frame(height: 6).offset(y: 4)
                Capsule().fill(CoachStyle.accent.opacity(0.2))
                    .overlay(Capsule().strokeBorder(CoachStyle.accent, lineWidth: 1.5))
                    .frame(width: max(8, x(to) - x(from)), height: 10)
                    .offset(x: x(from), y: 2)
                HStack {
                    Text("\(low.formatted())\(definition.unit)")
                    Spacer()
                    Text("\(high.formatted())\(definition.unit)")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(CoachStyle.textTertiary)
                .offset(y: 16)
            }
        }
        .frame(height: 32)
        .accessibilityHidden(true)
    }

    private func load() {
        guard let rule else { return }
        metricID = rule.metricID
        phases = rule.phases
        side = rule.side
        clubs = rule.clubs
        views = rule.views
        hasLower = rule.lowerBound != nil
        hasUpper = rule.upperBound != nil
        lower = rule.lowerBound ?? 0
        upper = rule.upperBound ?? 0
        studentNote = rule.studentConditionNote
        sourceNote = rule.sourceNote
        coachNote = rule.coachNote
        outOfRangeExplanation = rule.outOfRangeExplanation
        drill = rule.drillSuggestion
        isEnabled = rule.isEnabled
    }

    private func save() {
        // The hash is captured at save time. If the metric definition later
        // changes, RuleEngine refuses this range instead of reinterpreting it.
        let saved = CoachRule(
            id: rule?.id ?? UUID(),
            version: (rule?.version ?? 0) + 1,
            metricID: metricID,
            metricDefinitionHash: definition.definitionHash,
            phases: phases,
            side: side,
            clubs: clubs,
            views: views,
            studentConditionNote: studentNote,
            lowerBound: hasLower ? lower : nil,
            upperBound: hasUpper ? upper : nil,
            unit: definition.unit,
            sourceNote: sourceNote,
            coachNote: coachNote,
            outOfRangeExplanation: outOfRangeExplanation,
            drillSuggestion: drill,
            createdAt: rule?.createdAt ?? Date(),
            updatedAt: Date(),
            isEnabled: isEnabled)
        library.save(rule: saved)
        dismiss()
    }
}

extension ClubType: Identifiable { public var id: String { rawValue } }
extension CoachMeCore.CameraView: Identifiable { public var id: String { rawValue } }
