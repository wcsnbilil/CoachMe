import SwiftUI
import CoachMeCore

@MainActor
struct RuleListView: View {
    @Environment(SwingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var editing: CoachRule?
    @State private var creating = false

    var body: some View {
        List {
            Section {
                Text("App 不内置任何参考范围。这里的每一条都由你自己设定，并会带着来源和适用条件出现在报告里。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if library.rules.isEmpty {
                EmptyStateRow(icon: "slider.horizontal.3",
                              title: "还没有规则",
                              message: "新建一条，为某个指标在某个动作阶段设定你自己的参考范围。")
            }

            ForEach(library.rules) { rule in
                Button { editing = rule } label: { RuleRow(rule: rule) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for index in offsets { library.delete(rule: library.rules[index]) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CoachStyle.background)
        .navigationTitle("教练规则")
        .toolbar(.visible,for:.navigationBar)
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
struct RuleRow: View {
    let rule: CoachRule

    private var definition: MetricDefinition { MetricCatalog.definition(for: rule.metricID) }
    private var stale: Bool { rule.metricDefinitionHash != definition.definitionHash }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(definition.nameZH).font(.subheadline.bold())
                Spacer()
                Text("v\(rule.version)").font(.caption2).foregroundStyle(.secondary)
            }
            Text(rangeText).font(.caption.monospacedDigit())
            Text("\(rule.side.nameZH) · \(rule.phases.sorted { $0.order < $1.order }.map(\.nameZH).joined(separator: "、"))")
                .font(.caption).foregroundStyle(.secondary)
            if stale {
                Label("指标定义已更新，这条范围当前不会被应用", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var rangeText: String {
        switch (rule.lowerBound, rule.upperBound) {
        case let (lower?, upper?): return "\(lower.formatted()) – \(upper.formatted()) \(rule.unit)"
        case let (lower?, nil):    return "≥ \(lower.formatted()) \(rule.unit)"
        case let (nil, upper?):    return "≤ \(upper.formatted()) \(rule.unit)"
        default:                   return "暂无参考范围"
        }
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

    private var definition: MetricDefinition { MetricCatalog.definition(for: metricID) }

    var body: some View {
        Form {
            Section("指标") {
                Picker("指标", selection: $metricID) {
                    ForEach(MetricID.allCases.filter { $0 != .wristPathBodyReferenced }, id: \.self) {
                        Text(MetricCatalog.definition(for: $0).nameZH).tag($0)
                    }
                }
                DisclosureGroup("这个指标是怎么算的") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("公式", value: definition.formula)
                        LabeledContent("参考系", value: definition.referenceFrameZH)
                        LabeledContent("投影", value: definition.projectionZH)
                        LabeledContent("零点与方向", value: definition.zeroAndSignZH)
                        LabeledContent("范围", value: "\(definition.range.lowerBound.formatted()) – \(definition.range.upperBound.formatted()) \(definition.unit)")
                        Text(definition.caveatZH).font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                if definition.requiresAddressReference {
                    Label("需要先标记准备姿势关键帧，否则该指标不会有数值", systemImage: "mappin.circle")
                        .font(.caption)
                }
            }

            Section("适用条件") {
                MultiPicker(title: "动作阶段", options: SwingPhase.allCases,
                            selection: $phases, label: \.nameZH)
                Picker("侧", selection: $side) {
                    ForEach(RuleSide.allCases, id: \.self) { Text($0.nameZH).tag($0) }
                }
                MultiPicker(title: "球杆", options: ClubType.allCases,
                            selection: $clubs, label: \.nameZH)
                MultiPicker(title: "拍摄视角", options: CoachMeCore.CameraView.allCases,
                            selection: $views, label: \.nameZH)
                TextField("学员条件或教学目标（选填）", text: $studentNote, axis: .vertical)
            }

            Section("参考范围") {
                Toggle("设置下限", isOn: $hasLower)
                if hasLower {
                    HStack {
                        Text("下限")
                        Spacer()
                        TextField("", value: $lower, format: .number).multilineTextAlignment(.trailing)
                        Text(definition.unit)
                    }
                }
                Toggle("设置上限", isOn: $hasUpper)
                if hasUpper {
                    HStack {
                        Text("上限")
                        Spacer()
                        TextField("", value: $upper, format: .number).multilineTextAlignment(.trailing)
                        Text(definition.unit)
                    }
                }
                if !hasLower && !hasUpper {
                    Label("没有任何边界时，报告会显示「暂无参考范围」", systemImage: "info.circle")
                        .font(.caption)
                }
            }

            Section("说明与建议") {
                TextField("范围来源（例如：我自己对 30 名学员的观察）", text: $sourceNote, axis: .vertical)
                TextField("教练备注", text: $coachNote, axis: .vertical)
                TextField("超出范围时你想说明什么", text: $outOfRangeExplanation, axis: .vertical)
                TextField("对应练习建议", text: $drill, axis: .vertical)
            }

            Section {
                Text("超出范围只会表述为「超出你设置的范围」，不会表述为「动作错误」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(rule == nil ? "新建规则" : "编辑规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
        }
        .onAppear(perform: load)
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
            updatedAt: Date())
        library.save(rule: saved)
        dismiss()
    }
}

/// Simple multi-select row used for phases, clubs and views.
struct MultiPicker<T: Hashable & Identifiable>: View {
    let title: String
    let options: [T]
    @Binding var selection: Set<T>
    let label: (T) -> String

    init(title: String, options: [T], selection: Binding<Set<T>>, label: KeyPath<T, String>) {
        self.title = title
        self.options = options
        self._selection = selection
        self.label = { $0[keyPath: label] }
    }

    var body: some View {
        DisclosureGroup {
            ForEach(options) { option in
                Button {
                    if selection.contains(option) { selection.remove(option) } else { selection.insert(option) }
                } label: {
                    HStack {
                        Text(label(option))
                        Spacer()
                        if selection.contains(option) { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection.contains(option) ? .isSelected : [])
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(selection.isEmpty ? "未选择" : "\(selection.count) 项")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension SwingPhase: Identifiable {}
extension ClubType: Identifiable { public var id: String { rawValue } }
extension CoachMeCore.CameraView: Identifiable { public var id: String { rawValue } }
extension CoachRule: Identifiable {}
