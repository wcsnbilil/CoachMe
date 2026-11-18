import SwiftUI
import Charts
import CoachMeCore

/// Angle-vs-time chart sharing the video's clock.
///
/// Gaps matter here. A frame whose metric was unavailable contributes `nil`, and
/// consecutive gaps break the line rather than being bridged. Interpolating
/// across a long occlusion would draw motion that was never measured.
@MainActor
struct AngleChartView: View {
    /// A coach range drawn as a short bar at the frame it applies to.
    struct ChartRange {
        let time: Double
        let lower: Double
        let upper: Double
        let text: String
    }

    let timeline: MetricTimeline?
    let metric: MetricID
    let handedness: Handedness
    let keyframes: [Keyframe]
    let currentTime: Double
    var clipStart: Double = 0
    var highlightedPhase: SwingPhase?
    var range: ChartRange?
    let onScrub: (Double) -> Void

    struct Sample: Identifiable {
        var id: String { "\(series)-\(t)" }
        let segment: Int
        let t: Double
        let value: Double?
        let series: String
    }

    private var sideNames: (lead: String, trail: String) {
        metric == .kneeInteriorAngle ? ("引导侧", "后侧") : ("引导臂", "后侧臂")
    }

    static func segmentedSamples(_ values: [(t: Double, value: Double?)], series: String, clipStart: Double) -> [Sample] {
        var segment = 0
        return values.map { item in
            let value = item.value.flatMap { $0.isFinite ? $0 : nil }
            if value == nil { segment += 1 }
            return Sample(segment: segment, t: item.t - clipStart, value: value, series: series)
        }
    }

    private var samples: [Sample] {
        guard let timeline else { return [] }
        if MetricCatalog.isBilateral(metric) {
            return Self.segmentedSamples(timeline.series(metric, side: nil), series: "整体", clipStart: clipStart)
        }
        return Self.segmentedSamples(timeline.series(metric, side: handedness.leadSide), series: sideNames.lead, clipStart: clipStart)
            + Self.segmentedSamples(timeline.series(metric, side: handedness.trailSide), series: sideNames.trail, clipStart: clipStart)
    }

    private var currentValue: Double? {
        let side: BodySide? = MetricCatalog.isBilateral(metric) ? nil : handedness.leadSide
        return timeline?.metrics(at: currentTime)?.outcome(metric, side).value
    }

    private var missingCount: Int { samples.filter { $0.value == nil }.count }

    /// Explicit domains: the automatic "nice" bounds padded a 2 s clip to −2…4 s.
    private var xDomain: ClosedRange<Double> {
        0...max(samples.map(\.t).max() ?? 0, 0.1)
    }

    private var yDomain: ClosedRange<Double> {
        var values = samples.compactMap(\.value)
        if let range { values += [range.lower, range.upper] }
        guard let low = values.min(), let high = values.max() else { return 0...180 }
        let pad = max(5, (high - low) * 0.1)
        return (low - pad)...(high + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if samples.isEmpty {
                ContentUnavailableView("暂无曲线数据", systemImage: "chart.xyaxis.line")
            } else {
                chart
                legend
                footer
            }
        }
    }

    /// Lead is solid, trail is dashed, so the two stay distinguishable in
    /// greyscale and for colour-blind viewers.
    static func strokeStyle(for series: String) -> StrokeStyle {
        switch series {
        case "后侧臂", "后侧": return StrokeStyle(lineWidth: 2, dash: [6, 3])
        default: return StrokeStyle(lineWidth: 2)
        }
    }

    private var chart: some View {
        Chart {
            if let range {
                RectangleMark(xStart: .value("开始", range.time - clipStart - 0.025),
                              xEnd: .value("结束", range.time - clipStart + 0.025),
                              yStart: .value("下限", range.lower),
                              yEnd: .value("上限", range.upper))
                    .foregroundStyle(CoachStyle.accent.opacity(0.22))
            }

            ForEach(keyframes) { keyframe in
                let highlighted = keyframe.phase == highlightedPhase
                RuleMark(x: .value("关键帧", keyframe.timestampSeconds - clipStart))
                    .foregroundStyle(highlighted ? CoachStyle.forest : CoachStyle.textTertiary.opacity(0.5))
                    .lineStyle(highlighted ? .init(lineWidth: 1.5) : .init(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .center) {
                        if highlighted {
                            Text(keyframe.phase.nameZH)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(CoachStyle.forest, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
            }

            ForEach(samples) { sample in
                if let value = sample.value {
                    LineMark(x: .value("时间", sample.t),
                             y: .value("角度", value),
                             series: .value("连续片段", "\(sample.series)-\(sample.segment)"))
                        .foregroundStyle(by: .value("系列", sample.series))
                        .lineStyle(Self.strokeStyle(for: sample.series))
                        .interpolationMethod(.linear)
                }
            }

            RuleMark(x: .value("当前", currentTime - clipStart))
                .foregroundStyle(CoachStyle.forest)
                .lineStyle(.init(lineWidth: 1.5))
            if let currentValue {
                PointMark(x: .value("当前", currentTime - clipStart), y: .value("角度", currentValue))
                    .symbolSize(90)
                    .foregroundStyle(CoachStyle.forest)
                PointMark(x: .value("当前", currentTime - clipStart), y: .value("角度", currentValue))
                    .symbolSize(36)
                    .foregroundStyle(CoachStyle.limeOnDark)
            }
        }
        .chartForegroundStyleScale([
            sideNames.lead: CoachStyle.forest,
            sideNames.trail: CoachStyle.textSecondary,
            "整体": CoachStyle.forest
        ])
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxisLabel("秒")
        .chartYAxisLabel(MetricCatalog.definition(for: metric).unit)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = drag.location.x - geometry[plotFrame].origin.x
                                if let seconds: Double = proxy.value(atX: x) { onScrub(seconds + clipStart) }
                            }
                    )
                    .accessibilityLabel("拖动曲线定位视频时间")
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            if !MetricCatalog.isBilateral(metric) {
                legendItem(sideNames.lead, dash: [])
                legendItem(sideNames.trail, dash: [6, 3], colour: CoachStyle.textSecondary)
            }
            HStack(spacing: 5) {
                Rectangle().fill(CoachStyle.forest).frame(width: 1.5, height: 12)
                Text("当前帧")
            }
            if let range {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(CoachStyle.accent.opacity(0.22)).frame(width: 8, height: 12)
                    Text(range.text).lineLimit(1)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(CoachStyle.textSecondary)
    }

    private func legendItem(_ title: String, dash: [CGFloat], colour: Color = CoachStyle.forest) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 2))
                path.addLine(to: CGPoint(x: 16, y: 2))
            }
            .stroke(colour, style: StrokeStyle(lineWidth: 2, dash: dash))
            .frame(width: 16, height: 4)
            Text(title)
        }
    }

    @ViewBuilder
    private var footer: some View {
        let definition = MetricCatalog.definition(for: metric)
        VStack(alignment: .leading, spacing: 2) {
            if missingCount > 0 {
                Text("曲线空缺处关键点可见度不足，未做推算（\(missingCount) 个采样点）。点按或拖动曲线跳到对应画面。")
            } else {
                Text("点按或拖动曲线跳到对应画面。")
            }
            Text(definition.caveatZH)
        }
        .font(.caption2)
        .foregroundStyle(CoachStyle.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
