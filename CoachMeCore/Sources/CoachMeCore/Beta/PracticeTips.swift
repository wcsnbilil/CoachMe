import Foundation

/// 练习建议文案，集中在这一处。教练定稿后只改这里（中英两套），并把
/// `isCoachApproved` 改成 true；界面上的「待教练确认」标签会跟着消失。
public enum PracticeTips {
    public static let isCoachApproved = false

    public static let zh: [SwingPathAnalyzer.Verdict: String] = [
        .withinProRange: "（占位）目前只看到手的路线，看不到杆身；可以多拍几杆，看结果是否一致。",
        .overTheTop:     "（占位）下杆开始时让双手先往下落，而不是往前推。",
        .tooInside:      "（占位）下杆时让双手更贴近准备时的参考线下来。",
        .cannotJudge:    "（占位）先按下面的方法重拍。",
    ]

    public static let en: [SwingPathAnalyzer.Verdict: String] = [
        .withinProRange: "(Placeholder) Only the hands are tracked, not the club; film a few more swings to see if the result holds.",
        .overTheTop:     "(Placeholder) Start the downswing by letting the hands drop, not push out.",
        .tooInside:      "(Placeholder) Bring the hands down closer to the address line.",
        .cannotJudge:    "(Placeholder) Re-film using the steps below first.",
    ]

    public static func text(for verdict: SwingPathAnalyzer.Verdict, language: BetaLanguage) -> String {
        (language == .zh ? zh : en)[verdict] ?? ""
    }
}
