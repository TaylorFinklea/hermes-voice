import SwiftUI

// Compact mirror of the iPhone Brand.swift palette. Kept duplicated rather
// than shared via xcodegen because the Watch target only uses a small
// subset of tokens and the file is tiny.
enum HVColor {
    static let bg          = Color(hex: 0x141414)
    static let amber       = Color(hex: 0xFFBF00)
    static let gold        = Color(hex: 0xFFD700)
    static let bronze      = Color(hex: 0xCD7F32)
    static let cream       = Color(hex: 0xF5E9D3)
    static let creamDim    = Color(hex: 0x8A8479)
    static let danger      = Color(hex: 0xCC4444)
    static let dangerSoft  = Color(hex: 0xFF8A8A)
    static let amberGlow   = Color(hex: 0xFFBF00).opacity(0.18)
    static let creamSurface = Color.white.opacity(0.06)
}

enum HVFont {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let body    = mono(14)
    static let bodyDim = mono(13)
    static let caption = mono(12)
    static let chip    = mono(10, weight: .semibold)
    static let micro   = mono(9)
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
