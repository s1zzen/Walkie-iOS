//
//  WalkieTheme.swift
//  Walkie — дизайн-токены для SwiftUI.
//  Источник: tokens/tokens.json (Figma «Wakie», коллекции переменных Walkie/*).
//  iOS 17+. Шрифты Unbounded и Onest нужно добавить в бандл (см. README → «Шрифты»).
//

import SwiftUI

// MARK: - Colors

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum WK {
    enum C {
        // bg
        static let canvas  = Color(hex: 0xF4F2ED)
        static let surface = Color(hex: 0xFFFFFF)
        static let sunken  = Color(hex: 0xEBE8E1)
        // text
        static let ink  = Color(hex: 0x121316)
        static let ink2 = Color(hex: 0x5C5F66)
        static let ink3 = Color(hex: 0x9A9DA4)
        // line
        static let line = Color(hex: 0xE2DFD7)
        // brand
        static let violet     = Color(hex: 0x5B3DF5)
        static let violetSoft = Color(hex: 0xECE8FF)
        // accents
        static let lime      = Color(hex: 0xD7FF3D)
        static let coral     = Color(hex: 0xFF6A3D)
        static let coralSoft = Color(hex: 0xFFE7DE)
        static let sky       = Color(hex: 0x3DB8FF)
        static let mint      = Color(hex: 0x1FBF85)
        static let mintSoft  = Color(hex: 0xDDF6EA)
        static let sun       = Color(hex: 0xFFC53D)
        static let sunSoft   = Color(hex: 0xFFF3CF)
        // state
        static let danger     = Color(hex: 0xFF3B30)
        static let dangerSoft = Color(hex: 0xFFE5E3)

        /// Цвет аватара по идентификатору пользователя (UC: «Аватар — инициалы на цветном фоне»).
        static let avatarPalette: [Color] = [
            Color(hex: 0x5B3DF5), Color(hex: 0xFF6A3D), Color(hex: 0x1FBF85),
            Color(hex: 0x3DB8FF), Color(hex: 0xE8488A), Color(hex: 0xD99A00)
        ]
        static func avatar(for userId: String) -> Color {
            // Стабильный хеш (String.hashValue меняется между запусками — не используем).
            let sum = userId.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFFFFFF }
            return avatarPalette[sum % avatarPalette.count]
        }
    }

    // MARK: Spacing / radius / sizes
    enum S {
        static let xxs: CGFloat = 4, xs: CGFloat = 8, s: CGFloat = 12, m: CGFloat = 16
        static let l: CGFloat = 20, xl: CGFloat = 24, xxl: CGFloat = 32
        static let screen: CGFloat = 20
    }
    enum R {
        static let iconBadge: CGFloat = 14, field: CGFloat = 18, chip: CGFloat = 20, option: CGFloat = 20
        static let card: CGFloat = 24, sheet: CGFloat = 32, hero: CGFloat = 32, heroLarge: CGFloat = 36
    }
    enum Size {
        static let button: CGFloat = 56, buttonCompact: CGFloat = 48, field: CGFloat = 56
        static let option: CGFloat = 64, chip: CGFloat = 40, circleButton: CGFloat = 44
        static let tabBar: CGFloat = 64, mapPin: CGFloat = 30, mapPinActive: CGFloat = 40
    }
}

// MARK: - Typography

enum WKFont {
    case display, h1, h2, h3, body, bodyS, callout, calloutS, caption, captionS, micro

    /// PostScript-имена — проверь после добавления шрифтов: `UIFont.familyNames`.
    private var spec: (name: String, size: CGFloat, lineHeight: CGFloat, tracking: CGFloat) {
        switch self {
        case .display:  return ("Unbounded-Regular_Bold", 30, 36, -0.6)
        case .h1:       return ("Unbounded-Regular_SemiBold", 24, 30, -0.48)
        case .h2:       return ("Onest-Bold", 22, 28, 0)
        case .h3:       return ("Onest-SemiBold", 18, 24, 0)
        case .body:     return ("Onest-Regular", 17, 24, 0)
        case .bodyS:    return ("Onest-SemiBold", 17, 24, 0)
        case .callout:  return ("Onest-Regular", 15, 20, 0)
        case .calloutS: return ("Onest-SemiBold", 15, 20, 0)
        case .caption:  return ("Onest-Regular", 13, 18, 0)
        case .captionS: return ("Onest-Medium", 13, 18, 0)
        case .micro:    return ("Onest-SemiBold", 11, 14, 0)
        }
    }
    var font: Font { .custom(spec.name, size: spec.size, relativeTo: relative) }
    var lineSpacing: CGFloat { max(0, spec.lineHeight - spec.size * 1.2) }
    var tracking: CGFloat { spec.tracking }
    private var relative: Font.TextStyle {
        switch self {
        case .display: return .largeTitle
        case .h1: return .title
        case .h2: return .title2
        case .h3: return .title3
        case .body, .bodyS: return .body
        case .callout, .calloutS: return .callout
        case .caption, .captionS: return .caption
        case .micro: return .caption2
        }
    }
}

extension View {
    /// Применить текстовый стиль Walkie: `.wkFont(.h1)`. Поддерживает Dynamic Type.
    func wkFont(_ f: WKFont, color: Color = WK.C.ink) -> some View {
        self.font(f.font).tracking(f.tracking).lineSpacing(f.lineSpacing).foregroundStyle(color)
    }
}

// MARK: - Elevation & glass

extension View {
    func wkCardShadow() -> some View {
        shadow(color: Color(hex: 0x121320, opacity: 0.06), radius: 8, x: 0, y: 4)
    }
    func wkElevated() -> some View {
        shadow(color: Color(hex: 0x121320, opacity: 0.14), radius: 16, x: 0, y: 12)
    }
    /// Карточка: белая, радиус 24, мягкая тень.
    func wkCard(padding: CGFloat = WK.S.m, radius: CGFloat = WK.R.card) -> some View {
        self.padding(padding)
            .background(WK.C.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .wkCardShadow()
    }
    /// «Жидкое стекло» поверх карты. На iOS 26 SDK замени тело на `.glassEffect(.regular, in: shape)`.
    func wkGlass<S: InsettableShape>(_ shape: S) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .background(Color.white.opacity(0.55), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.95), lineWidth: 1))
            .shadow(color: Color(hex: 0x121320, opacity: 0.12), radius: 12, x: 0, y: 8)
    }
    func wkGlass(radius: CGFloat = 28) -> some View {
        wkGlass(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Motion

enum WKMotion {
    static let screen = Animation.easeOut(duration: 0.3)
    static let sheet  = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let select = Animation.spring(response: 0.25, dampingFraction: 0.8)
}
