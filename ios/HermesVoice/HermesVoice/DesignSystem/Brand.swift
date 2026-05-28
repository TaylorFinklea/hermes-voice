import SwiftUI

// Brand palette sampled from the existing Hermes Agent banner. These hex
// values are the source of truth for every tinted surface in the app —
// don't introduce new accent colors without updating this file first.
enum HVColor {
    static let bg          = Color(hex: 0x141414)
    static let bg2         = Color(hex: 0x0C0C0C)
    static let amber       = Color(hex: 0xFFBF00)
    static let gold        = Color(hex: 0xFFD700)
    static let bronze      = Color(hex: 0xCD7F32)
    static let cream       = Color(hex: 0xF5E9D3)
    static let creamDim    = Color(hex: 0x8A8479)
    static let creamFaint  = Color(hex: 0x4A463F)
    static let bronzeDim   = Color(hex: 0x6B421A)
    static let amberDim    = Color(hex: 0x8A6800)
    static let danger      = Color(hex: 0xCC4444)
    static let dangerSoft  = Color(hex: 0xFF8A8A)

    // Translucent tints used for chip backgrounds + hairline dividers.
    static let amberGlow   = Color(hex: 0xFFBF00).opacity(0.18)
    static let goldGlow    = Color(hex: 0xFFD700).opacity(0.22)
    static let bronzeGlow  = Color(hex: 0xCD7F32).opacity(0.16)
    static let creamSurface = Color.white.opacity(0.04)
    static let hairline    = Color.white.opacity(0.08)
}

enum HVFont {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let body        = mono(14)
    static let bodyDim     = mono(13)
    static let caption     = mono(12)
    static let captionTiny = mono(11)
    static let micro       = mono(10)
    static let chip        = mono(11, weight: .semibold)
    static let chipTiny    = mono(10, weight: .semibold)
    static let heroUser    = mono(22, weight: .semibold)
    static let heroReply   = mono(19, weight: .medium)
    static let heroSpeak   = mono(28, weight: .semibold)
    static let title       = mono(14, weight: .semibold)
    static let largeTitle  = mono(26, weight: .bold)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self = Color(red: r, green: g, blue: b, opacity: alpha)
    }
}
