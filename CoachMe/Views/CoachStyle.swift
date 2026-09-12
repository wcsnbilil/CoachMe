import SwiftUI
import UIKit

/// Shared visual language; semantic surfaces also adapt to Dark Mode.
enum CoachStyle {
    static let background = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red:0.06,green:0.09,blue:0.08,alpha:1) : UIColor(red:0.96,green:0.96,blue:0.94,alpha:1) })
    static let surface = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red:0.10,green:0.14,blue:0.12,alpha:1) : .white })
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red:0.61,green:0.80,blue:0.67,alpha:1) : UIColor(red:0.17,green:0.34,blue:0.27,alpha:1) })
    static let forest = Color(red:0.12,green:0.25,blue:0.20)
    static let lime = Color(red:0.82,green:0.90,blue:0.65)
    static let line = Color.primary.opacity(0.07)
}

struct CoachPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth:.infinity, minHeight:52)
            .foregroundStyle(.white)
            .background(CoachStyle.forest.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in:RoundedRectangle(cornerRadius:16))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

extension View {
    func coachCard() -> some View {
        self.padding(18)
            .frame(maxWidth:.infinity, alignment:.leading)
            .background(CoachStyle.surface, in:RoundedRectangle(cornerRadius:22))
            .overlay(RoundedRectangle(cornerRadius:22).stroke(CoachStyle.line,lineWidth:1))
    }
}
