import Foundation

/// Interface language of the beta build. Follows the system: Chinese when the
/// first preferred language is Chinese, English otherwise.
public enum BetaLanguage: String, Sendable, Codable, CaseIterable {
    case zh, en

    public static func from(preferredLanguages: [String]) -> BetaLanguage {
        guard let first = preferredLanguages.first?.lowercased() else { return .en }
        return first.hasPrefix("zh") ? .zh : .en
    }

    public static var system: BetaLanguage { from(preferredLanguages: Locale.preferredLanguages) }
}

/// Every string the beta screens show, in both languages. Kept in code (not a
/// string catalog) so the core tests can check that nothing is missing.
public struct BetaStrings: Sendable {
    public let language: BetaLanguage
    public init(_ language: BetaLanguage) { self.language = language }

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    // MARK: Records list
    public var appTitle: String { t("CoachMe 内测版", "CoachMe Beta") }
    public var recordsTitle: String { t("我的分析记录", "My analyses") }
    public var recordsEmpty: String { t("还没有记录。按下方按钮，导入一段从球手正后方拍的挥杆视频。",
                                         "No analyses yet. Tap below to import a swing filmed from directly behind the golfer.") }
    public var newAnalysis: String { t("开始新的分析", "New analysis") }
    public var exportRecords: String { t("导出测试记录", "Export test log") }
    public var exportHint: String { t("导出测试记录，发给研究团队。只包含时间、版本和结论，不含视频。",
                                       "Export your test log and send it to the research team. It only has times, app version and results, no video.") }

    // MARK: Shooting guide
    public var guideTitle: String { t("拍摄引导", "How to film") }
    public var guideIntro: String { t("先用手机相机录好一次完整挥杆，再回来导入。这样拍，结果才可靠：",
                                       "Record one full swing with the Camera app first, then import it. Film it like this:") }
    public var guideItems: [String] {
        language == .zh ? [
            "站在球手正后方，镜头对准目标方向",
            "镜头高度和球手的手差不多",
            "距离球手 3–4 米",
            "全身和球杆都在画面里",
            "画面里只有一个人",
        ] : [
            "Stand directly behind the golfer, pointing at the target",
            "Hold the camera at about hand height",
            "Stay 3–4 m (10–13 ft) away",
            "Keep the whole body and the club in the frame",
            "Only one person in the frame",
        ]
    }
    public var guideTarget: String { t("目标", "Target") }
    public var guideDistance: String { t("3–4 米", "3–4 m") }
    public var guideCamera: String { t("手机", "Phone") }
    public var pickVideo: String { t("我已录好，选择视频", "I've filmed it, choose video") }
    public var noLiveCapture: String { t("这一版不支持在 App 里直接拍摄。", "This version can't record inside the app.") }

    // MARK: Analysis
    public var analysing: String { t("正在本机分析…", "Analysing on this phone…") }
    public var analysingNote: String { t("视频不会上传，也不会联网。", "Nothing is uploaded; no network is used.") }
    public var cancel: String { t("取消", "Cancel") }
    public var analysisFailed: String { t("分析失败", "Analysis failed") }
    public var tryAgain: String { t("换一段视频", "Try another video") }

    // MARK: Report
    public var reportTitle: String { t("下杆路径", "Downswing path") }
    public func verdictTitle(_ v: SwingPathAnalyzer.Verdict) -> String {
        switch v {
        case .withinProRange: return t("范围内", "Within range")
        case .overTheTop:     return t("外下过度", "Over the top")
        case .tooInside:      return t("内下过度", "Too far inside")
        case .cannotJudge:    return t("无法判断", "Can't judge")
        }
    }
    public func verdictSummary(_ v: SwingPathAnalyzer.Verdict, leftHanded: Bool) -> String {
        switch v {
        case .withinProRange:
            return t("下杆时双手的路线在职业球员的范围内。",
                     "Your hands come down inside the range pro golfers use.")
        case .overTheTop:
            return leftHanded
                ? t("下杆时双手从外侧下来，这常和左曲或拉右球有关；球怎么飞还取决于杆面。",
                    "Your hands come down from the outside. This is often linked to a slice (curving left) or a pull right; the clubface also decides how the ball flies.")
                : t("下杆时双手从外侧下来，这常和右曲或拉左球有关；球怎么飞还取决于杆面。",
                    "Your hands come down from the outside. This is often linked to a slice or a pull left; the clubface also decides how the ball flies.")
        case .tooInside:
            return leftHanded
                ? t("下杆时双手过于从内侧下来，这常和右曲或推左有关；球怎么飞还取决于杆面。",
                    "Your hands come down too far from the inside. This is often linked to a hook (curving right) or a push left; the clubface also decides how the ball flies.")
                : t("下杆时双手过于从内侧下来，这常和左曲或推右有关；球怎么飞还取决于杆面。",
                    "Your hands come down too far from the inside. This is often linked to a hook or a push right; the clubface also decides how the ball flies.")
        case .cannotJudge:
            return t("这段视频无法可靠判断。", "This video can't be judged reliably.")
        }
    }
    // MARK: Soft wording (SwingPathAnalyzer.Confidence)
    /// Shown instead of the verdict title when the offset sits next to a threshold.
    public func nearBoundaryTitle(outside: Bool) -> String {
        outside ? t("接近外下边界", "Close to over the top") : t("接近内下边界", "Close to too far inside")
    }
    public func nearBoundaryNote(outside: Bool) -> String {
        outside
            ? t("这一杆手的路线接近外下的边界，结果可能来回变。建议多拍几杆，看多数结果。",
                "This swing's hand path is close to the over-the-top line, so the result may go either way. Film a few more swings and go by what most of them show.")
            : t("这一杆手的路线接近内下的边界，结果可能来回变。建议多拍几杆，看多数结果。",
                "This swing's hand path is close to the too-far-inside line, so the result may go either way. Film a few more swings and go by what most of them show.")
    }
    public var lowConfidenceTitle: String { t("结果仅供参考", "Treat this result as a rough guide") }
    public var lowTrackingNote: String {
        t("这段视频下杆时手的追踪不太稳定，下面的结果仅供参考。可以换个光线、穿和背景对比明显的衣服再拍一次。",
          "Hand tracking wasn't steady during the downswing in this video, so treat the result below as a rough guide. Try again in different light, wearing clothes that stand out from the background.")
    }
    public var lowCameraNote: String {
        t("机位离后方正中稍有偏差，下面的结果仅供参考。下次把手机放在你身后、对准目标再拍。",
          "The camera is slightly off from directly behind you, so treat the result below as a rough guide. Next time, put the phone right behind you, pointing at the target.")
    }
    /// The headline the report and the records list show: near_boundary replaces the verdict title.
    public func headline(_ v: SwingPathAnalyzer.Verdict, confidence: SwingPathAnalyzer.Confidence?, nearOutside: Bool) -> String {
        v != .cannotJudge && confidence == .nearBoundary ? nearBoundaryTitle(outside: nearOutside) : verdictTitle(v)
    }
    /// The note for a soft state, nil for normal. Soft states get this filming advice, never a practice tip.
    public func confidenceNote(_ c: SwingPathAnalyzer.Confidence?, nearOutside: Bool) -> String? {
        switch c {
        case .nearBoundary: return nearBoundaryNote(outside: nearOutside)
        case .lowTracking: return lowTrackingNote
        case .lowCamera: return lowCameraNote
        case .normal, nil: return nil
        }
    }

    public var evidenceTitle: String { t("画面依据", "What we measured") }
    public var legendHands: String { t("下杆双手路线", "Hands on the downswing") }
    public var legendRange: String { t("职业球员范围", "Pro range") }
    public var legendReference: String { t("准备姿势参考线（手→肩）", "Address line (hands → shoulders)") }
    public var evidenceNote: String { t("背景是下杆中段的画面。路线落在绿色带内 = 范围内；偏向球一侧 = 外下；偏向身体一侧 = 内下。",
                                         "The background is mid-downswing. Inside the green band = within range; toward the ball = over the top; toward the body = too far inside.") }
    public var uncertainty: String { t("参照职业球员的路径范围，对业余球手的准确度正在测试中。",
                                        "Compared with the range pro golfers use. Accuracy for amateur golfers is still being tested.") }
    public var practiceTitle: String { t("练习建议", "Practice tip") }
    /// Text lives in PracticeTips (one place to replace once the coach signs off).
    public func practicePlaceholder(_ v: SwingPathAnalyzer.Verdict) -> String {
        PracticeTips.text(for: v, language: language)
    }
    public var pendingCoach: String { t("待教练确认", "Awaiting coach review") }
    public var done: String { t("完成", "Done") }
    public var analyseAnother: String { t("再分析一段", "Analyse another") }

    // MARK: Refusal
    public var refusalTitle: String { t("这段视频无法判断", "We couldn't judge this video") }
    public var refusalReasonTitle: String { t("原因", "Why") }
    public var refusalRetakeTitle: String { t("怎么重拍", "How to re-film") }
    public var refilm: String { t("重新拍一段再导入", "Re-film and import again") }

    // MARK: Settings
    public var settingsTitle: String { t("设置", "Settings") }
    public var versionLabel: String { t("版本", "Version") }
    public var buildLabel: String { t("Build", "Build") }
    public var betaModeLabel: String { t("内测模式", "Beta mode") }
    public var on: String { t("开", "On") }
    public var privacyTitle: String { t("隐私", "Privacy") }
    public var privacyNote: String { t("内测模式下所有分析都在本机完成，App 不发出任何网络请求，视频不会离开这台手机。",
                                        "In beta mode every analysis runs on this phone. The app makes no network requests and your videos never leave the device.") }
    public var close: String { t("关闭", "Close") }
}
