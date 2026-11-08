import SwiftUI
import CoachMeCore

/// The beta report says one thing: the downswing path verdict, with the frame
/// it is based on, how sure we are, and a practice tip slot.
@MainActor
struct BetaReportView: View {
    @Environment(\.betaStrings) private var s
    let record: BetaRecord
    let evidence: PathEvidence
    let frameImage: UIImage?
    var onAgain: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                verdictHeader
                evidenceCard
                Label(s.uncertainty, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(CoachStyle.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                practiceCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(CoachStyle.background)
        .navigationTitle(s.reportTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(action: onAgain) { Label(s.analyseAnother, systemImage: "arrow.counterclockwise") }
                .buttonStyle(CoachSecondaryButton())
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(CoachStyle.background)
        }
    }

    private var verdictHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.dateText(record.createdAt)).font(.caption).foregroundStyle(CoachStyle.textSecondary)
            Text(s.verdictTitle(evidence.verdict))
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(evidence.verdict.betaColor)
            Text(s.verdictSummary(evidence.verdict, leftHanded: evidence.side == -1))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(evidence.verdict.betaFill, in: RoundedRectangle(cornerRadius: 20))
    }

    private var evidenceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.evidenceTitle).font(.subheadline.weight(.semibold))
            PathEvidenceCanvas(evidence: evidence, frameImage: frameImage)
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                legend(color: PathEvidenceCanvas.handsColor(evidence.verdict), text: s.legendHands, dashed: false)
                legend(color: PathEvidenceCanvas.bandColor, text: s.legendRange, dashed: false, band: true)
                legend(color: .white, text: s.legendReference, dashed: true)
            }
            Text(s.evidenceNote).font(.caption).foregroundStyle(CoachStyle.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .coachCard()
    }

    private func legend(color: Color, text: String, dashed: Bool, band: Bool = false) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(CoachStyle.stage).frame(width: 26, height: 14)
                if band {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 22, height: 10)
                } else {
                    Path { p in p.move(to: CGPoint(x: 2, y: 7)); p.addLine(to: CGPoint(x: 24, y: 7)) }
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, dash: dashed ? [4, 3] : []))
                        .frame(width: 26, height: 14)
                }
            }
            Text(text).font(.caption)
        }
    }

    private var practiceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(s.practiceTitle).font(.subheadline.weight(.semibold))
                Spacer()
                Text(s.pendingCoach)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CoachStyle.pending)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(CoachStyle.pendingFill, in: Capsule())
            }
            Text(s.practicePlaceholder(evidence.verdict))
                .font(.callout).foregroundStyle(CoachStyle.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .coachCard()
    }
}

/// The video frame with the hand path, the address line and the pro band on top.
struct PathEvidenceCanvas: View {
    let evidence: PathEvidence
    let frameImage: UIImage?

    static let bandColor = Color(red: 0.45, green: 0.85, blue: 0.5).opacity(0.38)
    static func handsColor(_ v: SwingPathAnalyzer.Verdict) -> Color {
        v == .withinProRange ? Color(red: 0.62, green: 0.95, blue: 0.55) : Color(red: 1.0, green: 0.55, blue: 0.3)
    }

    var body: some View {
        GeometryReader { geo in
            let iw = max(evidence.imageWidth, 1), ih = max(evidence.imageHeight, 1)
            let scale = min(geo.size.width / iw, geo.size.height / ih)
            let ox = (geo.size.width - iw * scale) / 2, oy = (geo.size.height - ih * scale) / 2
            let map = { (p: PathEvidence.Point) in CGPoint(x: ox + p.x * scale, y: oy + p.y * scale) }
            ZStack {
                CoachStyle.stage
                if let frameImage {
                    Image(uiImage: frameImage).resizable()
                        .frame(width: iw * scale, height: ih * scale)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .opacity(0.85)
                }
                if let band = evidence.rangeBand() {
                    Path { p in
                        let pts = band.inside.map(map) + band.outside.reversed().map(map)
                        guard let first = pts.first else { return }
                        p.move(to: first)
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                        p.closeSubpath()
                    }
                    .fill(Self.bandColor)
                }
                if evidence.referenceLine.count == 2 {
                    Path { p in
                        p.move(to: map(evidence.referenceLine[0]))
                        p.addLine(to: map(evidence.referenceLine[1]))
                    }
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
                if evidence.downswing.count > 1 {
                    Path { p in
                        p.move(to: map(evidence.downswing[0]))
                        evidence.downswing.dropFirst().forEach { p.addLine(to: map($0)) }
                    }
                    .stroke(Self.handsColor(evidence.verdict), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    if let last = evidence.downswing.last {
                        Circle().fill(Self.handsColor(evidence.verdict)).frame(width: 9, height: 9).position(map(last))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
