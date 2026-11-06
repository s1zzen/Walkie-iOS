import SwiftUI

enum WTheme {
    static let background = WK.C.canvas
    static let card = WK.C.surface
    static let accent = WK.C.violet
    static let muted = WK.C.ink2
    static let line = WK.C.line
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(.white)
            .background(WTheme.accent.opacity(isEnabled ? 1 : 0.35), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct WalkieCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(WTheme.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(WTheme.line))
    }
}

struct DemoBadge: View {
    var body: some View {
        Label("Демо-каталог", systemImage: "sparkles")
            .font(.caption.weight(.semibold)).foregroundStyle(WTheme.accent)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(WTheme.accent.opacity(0.1), in: Capsule())
    }
}

struct InlineErrorView: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline).foregroundStyle(.orange)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("inline.error")
    }
}
