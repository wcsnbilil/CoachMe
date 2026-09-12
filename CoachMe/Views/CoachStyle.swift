import SwiftUI
import UIKit

/// Shared visual language: warm white ground, charcoal text, forest green for
/// actions, lime only for the current frame and selection. Video panels stay
/// dark in both appearances so the skeleton and angle marks read clearly.
enum CoachStyle {
    static let background = dynamic(0xF5F5F0, dark: 0x0F1714)
    static let surface = dynamic(0xFFFFFF, dark: 0x19231F)
    /// Segmented-control track and quiet chip fill.
    static let fill = dynamic(0xECECE6, dark: 0x26302B)
    static let line = Color.primary.opacity(0.08)

    static let text = dynamic(0x1D211F, dark: 0xF0F2EE)
    static let textSecondary = dynamic(0x5E645F, dark: 0xA9B0AA)
    static let textTertiary = dynamic(0x8A8F89, dark: 0x7D847E)

    static let accent = dynamic(0x2B5745, dark: 0x9CCCAB)
    static let forest = Color(hex: 0x1F4033)
    static let lime = Color(hex: 0xD1E6A6)
    static let limeOnDark = Color(hex: 0xC6E47F)

    static let stage = Color(hex: 0x0E1311)
    static let stageRaised = Color(hex: 0x1A211E)
    static let onStage = Color(hex: 0xF2F4F0)

    static let pending = dynamic(0x7A5200, dark: 0xF0C674)
    static let pendingFill = dynamic(0xF6ECD6, dark: 0x3A2E14)
    static let confirmed = dynamic(0x1F4033, dark: 0x9CCCAB)
    static let confirmedFill = dynamic(0xE4ECE5, dark: 0x1E3329)
    static let alert = dynamic(0x9C4221, dark: 0xE59A7B)
    static let alertFill = dynamic(0xF6E5DD, dark: 0x3B2219)
    static let neutralFill = dynamic(0xECECE6, dark: 0x26302B)

    /// Status colours used on top of video.
    static let pendingOnStage = Color(hex: 0xF0C674)
    static let confirmedOnStage = Color(hex: 0x8FC0A0)

    static let display = Font.system(size: 32, weight: .semibold, design: .serif)

    private static func dynamic(_ light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

// MARK: - Buttons

struct CoachPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var height: CGFloat = 52
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(.white)
            .background(CoachStyle.forest.opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: height > 48 ? 16 : 12))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct CoachSecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var height: CGFloat = 52
    var tint: Color = CoachStyle.accent
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: height > 48 ? 16 : 12)
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(tint.opacity(enabled ? 1 : 0.4))
            .background(CoachStyle.surface.opacity(configuration.isPressed ? 0.7 : 1), in: shape)
            .overlay(shape.strokeBorder(tint.opacity(0.24), lineWidth: 1))
    }
}

/// 44 pt round button used in navigation headers.
struct CoachCircleButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(CoachStyle.text)
            .frame(width: 44, height: 44)
            .background(CoachStyle.surface, in: Circle())
            .overlay(Circle().strokeBorder(CoachStyle.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Square-ish control drawn on top of video.
struct StageButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(CoachStyle.onStage)
            .frame(minWidth: 44, minHeight: 44)
            .background(CoachStyle.stage.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Status

/// Every status carries an icon and words, never colour alone.
enum CoachStatus {
    case pending, confirmed, autoDetected, manual, unmarked
    case outOfRange, inRange, noRange, unavailable, incomplete

    var label: String {
        switch self {
        case .pending: return "待复核"
        case .confirmed: return "已确认"
        case .autoDetected: return "自动识别"
        case .manual: return "手动调整"
        case .unmarked: return "未标记"
        case .outOfRange: return "超出已设参考范围"
        case .inRange: return "在参考范围内"
        case .noRange: return "未设置参考范围"
        case .unavailable: return "无法可靠计算"
        case .incomplete: return "分析未完成"
        }
    }

    var symbol: String {
        switch self {
        case .pending, .unmarked: return "circle.dashed"
        case .confirmed, .inRange: return "checkmark.circle.fill"
        case .autoDetected: return "sparkle"
        case .manual: return "pencil"
        case .outOfRange: return "arrow.up.arrow.down"
        case .noRange: return "square.dashed"
        case .unavailable: return "minus.circle"
        case .incomplete: return "exclamationmark.triangle"
        }
    }

    var foreground: Color {
        switch self {
        case .pending: return CoachStyle.pending
        case .confirmed, .manual, .inRange: return CoachStyle.confirmed
        case .outOfRange: return CoachStyle.alert
        default: return CoachStyle.textSecondary
        }
    }

    var fill: Color {
        switch self {
        case .pending: return CoachStyle.pendingFill
        case .confirmed, .manual, .inRange: return CoachStyle.confirmedFill
        case .outOfRange: return CoachStyle.alertFill
        default: return CoachStyle.neutralFill
        }
    }

    var onStage: Color {
        switch self {
        case .pending, .unmarked: return CoachStyle.pendingOnStage
        case .confirmed, .manual: return CoachStyle.confirmedOnStage
        default: return CoachStyle.onStage.opacity(0.75)
        }
    }
}

struct StatusTag: View {
    let status: CoachStatus
    var text: String?
    var onStage = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol).font(.caption2.weight(.bold))
            Text(text ?? status.label).font(.caption.weight(.semibold))
        }
        .foregroundStyle(onStage ? status.onStage : status.foreground)
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 3)
        .background(onStage ? CoachStyle.stage.opacity(0.82) : status.fill,
                    in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Containers

extension View {
    func coachCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CoachStyle.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    /// Grouped list container: rows supply their own padding and dividers.
    func coachGroup() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .background(CoachStyle.surface, in: RoundedRectangle(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(CoachStyle.textTertiary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GroupDivider: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle().fill(CoachStyle.line).frame(height: 1).padding(.leading, inset)
    }
}

/// Segmented control drawn to match the design, light or on video.
struct CoachSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var onStage = false
    var segmentWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { option in
                let selected = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: segmentWidth == nil ? .infinity : nil)
                        .frame(width: segmentWidth, height: onStage ? 38 : 36)
                        .foregroundStyle(foreground(selected))
                        .background(background(selected), in: RoundedRectangle(cornerRadius: 9))
                        .shadow(color: selected && !onStage ? .black.opacity(0.1) : .clear, radius: 1.5, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(onStage ? CoachStyle.stage.opacity(0.82) : CoachStyle.fill,
                    in: RoundedRectangle(cornerRadius: onStage ? 12 : 11))
    }

    private func foreground(_ selected: Bool) -> Color {
        if onStage { return selected ? CoachStyle.stage : CoachStyle.onStage.opacity(0.72) }
        return selected ? CoachStyle.text : CoachStyle.textSecondary
    }

    private func background(_ selected: Bool) -> Color {
        guard selected else { return .clear }
        return onStage ? CoachStyle.onStage : CoachStyle.surface
    }
}

/// Selectable capsule, with a checkmark so selection never relies on colour.
struct ChoiceChip: View {
    let title: String
    let selected: Bool
    var showsCheck = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if showsCheck && selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .foregroundStyle(selected ? Color.white : CoachStyle.text)
            .background(selected ? CoachStyle.forest : CoachStyle.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? .clear : CoachStyle.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Icon + text line used for privacy and measurement notes.
struct FootnoteLine: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.caption2)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(CoachStyle.textTertiary)
    }
}

/// Left-aligned wrapping row for chips and tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: proposal.width ?? width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
