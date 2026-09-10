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
    let timeline: MetricTimeline?
    let metric: MetricID
    let handedness: Handedness
    let keyframes: [Keyframe]
    let currentTime: Double
    let onScrub: (Double) -> Void

    private struct Sample: Identifiable {
        let id = UUID()
        let t: Double
        let value: Double?
        let series: String
    }

    private var samples: [Sample] {
        guard let timeline else { return [] }
        if MetricCatalog.isBilateral(metric) {
            return timeline.series(metric, side: nil).map { Sample(t: $0.t, value: $0.value, series: "整体") }
        }
        let lead = timeline.series(metric, side: handedness.leadSide).map {
            Sample(t: $0.t, value: $0.value, series: "引导臂")
        }
        let trail = timeline.series(metric, side: handedness.trailSide).map {
            Sample(t: $0.t, value: $0.value, series: "后侧臂")
        }
        return lead + trail
    }

    private var missingCount: Int { samples.filter { $0.value == nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if samples.isEmpty {
                ContentUnavailableView("暂无曲线数据", systemImage: "chart.xyaxis.line")
            } else {
                chart
                footer
            }
        }
    }

    /// Lead is solid, trail is dashed. Chosen over two hues alone so the series
    /// stay distinguishable in greyscale and for colour-blind viewers.
    static func strokeStyle(for series: String) -> StrokeStyle {
        switch series {
        case "后侧臂": return StrokeStyle(lineWidth: 2, dash: [6, 3])
        default:      return StrokeStyle(lineWidth: 2)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(samples) { sample in
                if let value = sample.value {
                    LineMark(x: .value("时间", sample.t),
                             y: .value("角度", value),
                             series: .value("系列", sample.series))
                        .foregroundStyle(by: .value("系列", sample.series))
                        // Colour alone does not separate the two arms for a
                        // colour-blind coach, and the two hues are close in
                        // luminance. The dash pattern carries the same
                        // distinction independently.
                        .lineStyle(Self.strokeStyle(for: sample.series))
                        .interpolationMethod(.linear)
                }
            }

            ForEach(keyframes) { keyframe in
                RuleMark(x: .value("关键帧", keyframe.timestampSeconds))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(.init(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Text(keyframe.phase.nameZH)
                            .font(.caption2)
                            .padding(.horizontal, 3)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
                    }
            }

            RuleMark(x: .value("当前", currentTime))
                .foregroundStyle(Palette.leadArm)
                .lineStyle(.init(lineWidth: 2))
        }
        .chartForegroundStyleScale([
            "引导臂": Palette.leadArm,
            "后侧臂": Palette.trailArm,
            "整体": Color.primary
        ])
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
                                if let seconds: Double = proxy.value(atX: x) { onScrub(seconds) }
                            }
                    )
                    .accessibilityLabel("拖动以定位视频时间")
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        let definition = MetricCatalog.definition(for: metric)
        VStack(alignment: .leading, spacing: 2) {
            if missingCount > 0 {
                Label("\(missingCount) 个采样点无法可靠计算，曲线在该处断开（未做插值）",
                      systemImage: "chart.line.downtrend.xyaxis")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(definition.caveatZH)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
