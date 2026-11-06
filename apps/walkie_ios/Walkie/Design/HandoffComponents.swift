//
//  WalkieComponents.swift
//  Базовые компоненты Walkie, повторяющие компоненты Figma (страница «🧩 Компоненты»).
//  Иконки: Assets.xcassets/Icons/<name> (template, SVG с Preserve Vector Data).
//

import SwiftUI

// MARK: - Icon

struct WKIcon: View {
    let name: String
    var size: CGFloat = 24
    var color: Color = WK.C.ink
    var body: some View {
        Image("icon-\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// Иконка в цветной подложке (категории мест, пункты списков).
struct WKIconBadge: View {
    let icon: String
    var bg: Color = WK.C.violetSoft
    var fg: Color = WK.C.violet
    var size: CGFloat = 44
    var radius: CGFloat? = nil
    var body: some View {
        WKIcon(name: icon, size: size * 0.5, color: fg)
            .frame(width: size, height: size)
            .background(bg, in: RoundedRectangle(cornerRadius: radius ?? size / 2, style: .continuous))
    }
}

// MARK: - Buttons (Figma: Button / kind=…)

enum WKButtonKind { case primary, dark, secondary, tinted, glass, danger, lime, plain }

struct WKButtonStyle: ButtonStyle {
    var kind: WKButtonKind = .primary
    var height: CGFloat = WK.Size.button
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        let (bg, fg, stroke) = colors
        return configuration.label
            .wkFont(.bodyS, color: fg)
            .lineLimit(1)
            .padding(.horizontal, 24)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background {
                if kind == .glass {
                    Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(Color.white.opacity(0.55)))
                } else {
                    Capsule().fill(bg)
                }
            }
            .overlay { if let stroke { Capsule().strokeBorder(stroke, lineWidth: 1) } }
            .shadow(color: kind == .primary ? WK.C.violet.opacity(0.30) : .clear, radius: 10, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(WKMotion.select, value: configuration.isPressed)
            .contentShape(Capsule())
    }

    static func foreground(_ kind: WKButtonKind) -> Color { WKButtonStyle(kind: kind).colors.1 }

    private var colors: (Color, Color, Color?) {
        switch kind {
        case .primary:   return (WK.C.violet, .white, nil)
        case .dark:      return (WK.C.ink, .white, nil)
        case .secondary: return (WK.C.surface, WK.C.ink, WK.C.line)
        case .tinted:    return (WK.C.violet.opacity(0.12), WK.C.violet, nil)
        case .glass:     return (.clear, WK.C.ink, Color.white.opacity(0.95))
        case .danger:    return (WK.C.danger.opacity(0.10), WK.C.danger, nil)
        case .lime:      return (WK.C.lime, WK.C.ink, nil)
        case .plain:     return (.clear, WK.C.violet, nil)
        }
    }
}

struct WKButton: View {
    let title: String
    var kind: WKButtonKind = .primary
    var icon: String? = nil
    var fullWidth = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { WKIcon(name: icon, size: 20, color: WKButtonStyle.foreground(kind)) }
                Text(title)
            }
        }
        .buttonStyle(WKButtonStyle(kind: kind, fullWidth: fullWidth))
    }
}

/// Круглая стеклянная кнопка 44 pt (назад, закрыть, колокольчик, «ещё»).
struct WKCircleButton: View {
    let icon: String
    var badge: Int? = nil
    var accessibilityLabel: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            WKIcon(name: icon, size: 22)
                .frame(width: 44, height: 44)
                .wkGlass(Circle())
                .overlay(alignment: .topTrailing) {
                    if let badge, badge > 0 {
                        Text("\(badge)").wkFont(.micro, color: .white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(WK.C.coral, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white, lineWidth: 2))
                            .offset(x: 4, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Questionnaire option card (Figma: Option/…, шаблон S-09)

struct WKOptionCard: View {
    let title: String
    var icon: String? = nil
    var iconBg: Color = WK.C.sunken
    var iconFg: Color = WK.C.ink
    var isSelected: Bool
    var isMulti = false
    var isDimmed = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon { WKIconBadge(icon: icon, bg: iconBg, fg: iconFg, size: 44, radius: WK.R.iconBadge) }
                Text(title).wkFont(.bodyS).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                ZStack {
                    RoundedRectangle(cornerRadius: isMulti ? 8 : 12, style: .continuous)
                        .fill(isSelected ? WK.C.violet : WK.C.surface)
                    RoundedRectangle(cornerRadius: isMulti ? 8 : 12, style: .continuous)
                        .strokeBorder(isSelected ? .clear : WK.C.line, lineWidth: 2)
                    if isSelected { WKIcon(name: "check", size: 14, color: .white) }
                }
                .frame(width: 24, height: 24)
            }
            .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
            .frame(minHeight: WK.Size.option)
            .background(isSelected ? WK.C.violetSoft : WK.C.surface,
                        in: RoundedRectangle(cornerRadius: WK.R.option, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: WK.R.option, style: .continuous)
                .strokeBorder(isSelected ? WK.C.violet : WK.C.line, lineWidth: isSelected ? 2 : 1))
            .opacity(isDimmed ? 0.45 : 1)
            .animation(WKMotion.select, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Chip

struct WKChip: View {
    let title: String
    var icon: String? = nil
    var isSelected = false
    var bg: Color = WK.C.surface
    var selectedBg: Color = WK.C.ink
    var body: some View {
        HStack(spacing: 6) {
            if let icon { WKIcon(name: icon, size: 18, color: isSelected ? .white : WK.C.ink) }
            Text(title).wkFont(.calloutS, color: isSelected ? .white : WK.C.ink)
        }
        .padding(.leading, icon == nil ? 16 : 10).padding(.trailing, 16)
        .frame(height: WK.Size.chip)
        .background(isSelected ? selectedBg : bg, in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? .clear : WK.C.line, lineWidth: 1))
    }
}

// MARK: - Avatar

struct WKAvatar: View {
    let initials: String
    let userId: String
    var size: CGFloat = 44
    var body: some View {
        Text(initials)
            .wkFont(size > 56 ? .h2 : (size > 36 ? .calloutS : .micro), color: .white)
            .frame(width: size, height: size)
            .background(WK.C.avatar(for: userId), in: Circle())
            .accessibilityLabel(initials)
    }
}

// MARK: - Progress

/// Прогресс анкеты: «Шаг 3 из 15» (профиль стартует с 3 — согласие и имя засчитаны).
struct WKProgressBar: View {
    let step: Int
    let total: Int
    var color: Color = WK.C.violet
    var label: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(WK.C.sunken)
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(step) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 8)
            Text(label ?? "Шаг \(step) из \(total)").wkFont(.captionS, color: WK.C.ink2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Сегментный прогресс прогулки: посещено (mint) / текущая (violet) / впереди (sunken).
struct WKWalkProgress: View {
    let visited: Int
    let total: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { i in
                Capsule().fill(i < visited ? WK.C.mint : (i == visited ? WK.C.violet : WK.C.sunken))
                    .frame(height: 8)
            }
        }
    }
}

/// Шаги создания прогулки: Старт · Финиш · Время · Анкета.
struct WKStepper: View {
    let current: Int
    var labels = ["Старт", "Финиш", "Время", "Анкета"]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(i <= current ? WK.C.violet : WK.C.line).frame(height: 4)
                    Text(labels[i]).wkFont(.micro, color: i == current ? WK.C.violet : (i < current ? WK.C.ink2 : WK.C.ink3))
                }
            }
        }
    }
}

// MARK: - Text field

struct WKTextFieldStyle: TextFieldStyle {
    var icon: String? = nil
    var isError = false
    var isFocused = false
    func _body(configuration: TextField<Self._Label>) -> some View {
        HStack(spacing: 10) {
            if let icon { WKIcon(name: icon, size: 20, color: WK.C.ink3) }
            configuration.wkFont(.body)
        }
        .padding(.horizontal, 16)
        .frame(height: WK.Size.field)
        .background(WK.C.surface, in: RoundedRectangle(cornerRadius: WK.R.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WK.R.field, style: .continuous)
            .strokeBorder(isError ? WK.C.danger : (isFocused ? WK.C.violet : WK.C.line),
                          lineWidth: (isError || isFocused) ? 2 : 1))
    }
}

// MARK: - Banner (предупреждение / ошибка / инфо)

struct WKBanner: View {
    enum Kind { case warning, error, success, info }
    let title: String
    var message: String? = nil
    var icon: String = "alert"
    var kind: Kind = .warning
    var body: some View {
        let (bg, badgeBg, badgeFg): (Color, Color, Color) = {
            switch kind {
            case .warning: return (WK.C.sunSoft, WK.C.sun, WK.C.ink)
            case .error:   return (WK.C.dangerSoft, WK.C.danger, .white)
            case .success: return (WK.C.mintSoft, WK.C.mint, .white)
            case .info:    return (WK.C.violetSoft, WK.C.violet, .white)
            }
        }()
        HStack(alignment: .top, spacing: 12) {
            WKIconBadge(icon: icon, bg: badgeBg, fg: badgeFg, size: 36, radius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).wkFont(.calloutS)
                if let message { Text(message).wkFont(.caption, color: WK.C.ink2) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(bg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Tab bar (плавающая стеклянная капсула)

enum WKTab: Int, CaseIterable, Identifiable {
    case route, myRoutes, friends, profile
    var id: Int { rawValue }
    var title: String { ["Маршрут", "Мои маршруты", "Друзья", "Профиль"][rawValue] }
    var icon: String { ["route", "map", "users", "user"][rawValue] }
}

struct WKTabBar: View {
    @Binding var selection: WKTab
    var body: some View {
        HStack(spacing: 2) {
            ForEach(WKTab.allCases) { tab in
                let on = tab == selection
                Button { withAnimation(WKMotion.select) { selection = tab } } label: {
                    VStack(spacing: 3) {
                        WKIcon(name: tab.icon, size: 24, color: on ? WK.C.violet : WK.C.ink2)
                        Text(tab.title).wkFont(.micro, color: on ? WK.C.violet : WK.C.ink2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(on ? WK.C.violet.opacity(0.12) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(6)
        .wkGlass(Capsule())
        .padding(.horizontal, 16)
    }
}

// MARK: - Bottom sheet container (шторки на карте)

struct WKSheetContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(WK.C.line).frame(width: 40, height: 5).frame(maxWidth: .infinity)
            content
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .background(WK.C.surface, in: UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32, style: .continuous))
        .shadow(color: Color(hex: 0x121320, opacity: 0.16), radius: 16, x: 0, y: -8)
    }
}

// MARK: - Previews

#Preview("Components") {
    ScrollView {
        VStack(spacing: 12) {
            WKButton(title: "Начать прогулку", kind: .primary, icon: "play") {}
            WKButton(title: "Войти с Apple", kind: .dark, icon: "apple") {}
            WKButton(title: "Войти по почте", kind: .secondary, icon: "mail") {}
            WKButton(title: "Другой вариант", kind: .tinted, icon: "refresh") {}
            WKOptionCard(title: "Сначала почитаю отзывы", icon: "star", isSelected: true) {}
            WKOptionCard(title: "Зайду сразу, интересно", icon: "sparkles", isSelected: false) {}
            HStack { WKChip(title: "Парки", icon: "tree"); WKChip(title: "Виды", icon: "eye", isSelected: true) }
            WKProgressBar(step: 3, total: 15)
            WKBanner(title: "Финиш недостижим за 1,5 часа", message: "Увеличь время или убери конечную точку", kind: .error)
        }
        .padding(20)
    }
    .background(WK.C.canvas)
}
