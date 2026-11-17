import XCTest
import SwiftUI
import CoachMeCore
@testable import CoachMe

/// Renders the beta screens in both languages so they can be reviewed without
/// a Mac. CI sets COACHME_SCREENSHOT_DIR (via TEST_RUNNER_) and uploads the PNGs.
@MainActor
final class BetaScreenshotTests: XCTestCase {

    private var outputDir: URL {
        if let dir = ProcessInfo.processInfo.environment["COACHME_SCREENSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("beta-screenshots", isDirectory: true)
    }

    func testRenderBetaScreens() throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let frame = Self.syntheticFrame()
        for lang in BetaLanguage.allCases {
            try shot("1_guide", lang, height: 852) {
                NavigationStack { ShootingGuideView(onPicked: { _ in }) }
            }
            let within = Self.record(.withinProRange, offset: -0.12)
            try shot("2_within_range", lang, height: 1500) {
                NavigationStack { BetaReportView(record: within, evidence: within.evidence!, frameImage: frame, onAgain: {}) }
            }
            let ott = Self.record(.overTheTop, offset: 0.34)
            try shot("3_over_the_top", lang, height: 1500) {
                NavigationStack { BetaReportView(record: ott, evidence: ott.evidence!, frameImage: frame, onAgain: {}) }
            }
            try shot("4_refusal_camera", lang, height: 1200) {
                NavigationStack { BetaRefusalView(refusal: .cameraOffAxis, onRefilm: {}) }
            }
            let list = Self.sampleRecords()
            let exportURL = BetaRootView.writeExport(list)
            try shot("5_records", lang, height: 852) {
                NavigationStack { BetaRecordsView(records: list, exportURL: exportURL, onNew: {}, onOpen: { _ in }) }
            }
            try shot("6_settings", lang, height: 852) { BetaSettingsView() }
            let near = Self.record(.withinProRange, offset: 0.12, confidence: .nearBoundary)
            try shot("7_near_boundary", lang, height: 1500) {
                NavigationStack { BetaReportView(record: near, evidence: near.evidence!, frameImage: frame, onAgain: {}) }
            }
            let low = Self.record(.overTheTop, offset: 0.3, confidence: .lowTracking)
            try shot("8_low_tracking", lang, height: 1600) {
                NavigationStack { BetaReportView(record: low, evidence: low.evidence!, frameImage: frame, onAgain: {}) }
            }
            let cam = Self.record(.withinProRange, offset: -0.2, confidence: .lowCamera)
            try shot("9_low_camera", lang, height: 1600) {
                NavigationStack { BetaReportView(record: cam, evidence: cam.evidence!, frameImage: frame, onAgain: {}) }
            }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: outputDir.path).filter { $0.hasSuffix(".png") }
        XCTAssertGreaterThanOrEqual(files.count, 18)
        print("BETA_SCREENSHOTS \(outputDir.path) \(files.count) files")
    }

    private func shot<V: View>(_ name: String, _ lang: BetaLanguage, height: CGFloat,
                               @ViewBuilder _ content: () -> V) throws {
        let view = content()
            .environment(\.betaStrings, BetaStrings(lang))
            .environment(\.locale, Locale(identifier: lang == .zh ? "zh_CN" : "en_US"))
            .environment(\.colorScheme, .light)
            .tint(CoachStyle.accent)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.frame = CGRect(x: 0, y: 0, width: 393, height: height)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: outputDir.appendingPathComponent("\(name)_\(lang.rawValue).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name)_\(lang.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Fixtures

    static let imageWidth = 720.0, imageHeight = 1280.0

    /// Portrait down-the-line geometry: address hands, shoulders, top of swing.
    static func evidence(_ verdict: SwingPathAnalyzer.Verdict, offset: Double,
                         confidence: SwingPathAnalyzer.Confidence = .normal) -> PathEvidence {
        let hands = PathEvidence.Point(x: 430, y: 840), shoulders = PathEvidence.Point(x: 330, y: 560)
        let torso = 260.0
        func refX(_ y: Double) -> Double { hands.x + (y - hands.y) * (shoulders.x - hands.x) / (shoulders.y - hands.y) }
        var down: [PathEvidence.Point] = []
        let topY = 360.0
        for i in 0...24 {
            let f = Double(i) / 24
            let y = topY + (hands.y - topY) * f
            // Bulge away from the address line by `offset` torso lengths mid-downswing.
            down.append(.init(x: refX(y) + sin(f * .pi) * offset * torso * 1.3, y: y))
        }
        return PathEvidence(verdict: verdict, refusal: nil, offset: offset, side: 1, imageWidth: imageWidth,
                            imageHeight: imageHeight, downswing: down, referenceLine: [hands, shoulders],
                            torsoPixels: torso, evidenceSeconds: 1.0, confidence: confidence)
    }

    static func record(_ verdict: SwingPathAnalyzer.Verdict, offset: Double,
                       confidence: SwingPathAnalyzer.Confidence = .normal) -> BetaRecord {
        BetaRecord(createdAt: Date(timeIntervalSince1970: 1_794_143_400), appVersion: "0.1.0", build: "1",
                   verdict: verdict, refusal: nil, offset: offset, swingID: nil,
                   evidence: evidence(verdict, offset: offset, confidence: confidence), confidence: confidence)
    }

    static func sampleRecords() -> [BetaRecord] {
        let base = Date(timeIntervalSince1970: 1_794_143_400)
        return [
            BetaRecord(createdAt: base, appVersion: "0.1.0", build: "1", verdict: .overTheTop, refusal: nil,
                       offset: 0.34, swingID: nil, evidence: nil),
            BetaRecord(createdAt: base.addingTimeInterval(-3_600), appVersion: "0.1.0", build: "1", verdict: .cannotJudge,
                       refusal: .cameraOffAxis, offset: nil, swingID: nil, evidence: nil),
            BetaRecord(createdAt: base.addingTimeInterval(-86_400), appVersion: "0.1.0", build: "1", verdict: .withinProRange,
                       refusal: nil, offset: -0.12, swingID: nil, evidence: nil),
            BetaRecord(createdAt: base.addingTimeInterval(-87_000), appVersion: "0.1.0", build: "1", verdict: .withinProRange,
                       refusal: nil, offset: 0.12, swingID: nil, evidence: evidence(.withinProRange, offset: 0.12, confidence: .nearBoundary),
                       confidence: .nearBoundary),
            BetaRecord(createdAt: base.addingTimeInterval(-90_000), appVersion: "0.1.0", build: "1", verdict: .cannotJudge,
                       refusal: .downswingGap, offset: nil, swingID: nil, evidence: nil),
        ]
    }

    /// A stand-in video frame: sky, trees, grass and a simple golfer silhouette.
    static func syntheticFrame() -> UIImage {
        let size = CGSize(width: imageWidth / 2, height: imageHeight / 2)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor(red: 0.62, green: 0.78, blue: 0.9, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.45))
            UIColor(red: 0.2, green: 0.38, blue: 0.22, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: size.height * 0.38, width: size.width, height: size.height * 0.1))
            UIColor(red: 0.36, green: 0.6, blue: 0.3, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: size.height * 0.45, width: size.width, height: size.height * 0.55))
            // Golfer (scaled 0.5 from the 720×1280 geometry)
            UIColor(white: 0.15, alpha: 0.85).setFill()
            c.fillEllipse(in: CGRect(x: 135, y: 230, width: 40, height: 44))                 // head
            c.fill(CGRect(x: 140, y: 275, width: 50, height: 150))                              // torso
            c.fill(CGRect(x: 145, y: 420, width: 18, height: 170))                              // legs
            c.fill(CGRect(x: 172, y: 420, width: 18, height: 170))
            UIColor.white.setFill()
            c.fillEllipse(in: CGRect(x: 250, y: 575, width: 10, height: 10))                    // ball
        }
    }
}
