//
//  AstryxTheme.swift
//  PupilIOS
//
//  Astryx (Meta Open Source) のデザイントークンを Swift へ移植したもの。
//
//  出典: @astryxdesign/theme-neutral@0.7.17 dist/theme.css の dark 列（light-dark(a, b) の b）
//        @astryxdesign/core@0.7.17 dist/astryx.css の spacing / size / font-weight トークン
//  対応表と行番号は docs/ASTRYX.md を参照。値を変えるときは必ず元 CSS を読み直すこと。
//
//  Astryx は「常に dark トークン」で使う（CONTRACT §1: colorScheme は .dark 固定）。
//

import SwiftUI

// MARK: - スケール型

/// Astryx の spacing スケール（`--spacing-*`）に対応する抽象ステップ。
enum AstryxSpace {
    case xxs, xs, sm, md, lg, xl, xxl
}

/// Astryx のテキストロール（`--text-*-size / -weight`）に対応する抽象ロール。
enum AstryxFontRole {
    case display, heading1, heading2, heading3, body, label, caption
}

// MARK: - トークン実値

/// CSS custom property の実値。ここだけが「数値の正本」。
private enum AstryxTokens {

    // --- color（theme-neutral@0.7.17 の dark 列） ---
    static let backgroundBody = Color(astryxHex: 0x1B1B1B)          // --color-background-body
    static let backgroundSurface = Color(astryxHex: 0x262626)       // --color-background-surface
    static let backgroundCard = Color(astryxHex: 0x1B1B1B)          // --color-background-card
    static let backgroundGray = Color(astryxHex: 0x303030)          // --color-background-gray
    static let textPrimary = Color(astryxHex: 0xFFFFFF)             // --color-text-primary
    static let textSecondary = Color(astryxHex: 0x9E9E9E)           // --color-text-secondary
    static let border = Color(astryxHex: 0xFFFFFF, alphaByte: 0x1A) // --color-border (#ffffff1A)
    static let accent = Color(astryxHex: 0xF1F1F1)                  // --color-accent
    static let onAccent = Color(astryxHex: 0x111111)                // --color-on-accent
    static let accentMuted = Color(astryxHex: 0x474747)             // --color-accent-muted
    static let error = Color(astryxHex: 0xFF705D)                   // --color-error
    static let success = Color(astryxHex: 0x64AF4C)                 // --color-success

    // --- radius（theme-neutral の上書き値） ---
    static let radiusSmall: CGFloat = 6    // --radius-inner     0.375rem
    static let radiusMedium: CGFloat = 10  // --radius-element   0.625rem
    static let radiusLarge: CGFloat = 12   // --radius-container 0.75rem
    static let radiusFull: CGFloat = 9999  // --radius-full

    // --- size（core の :root トークン） ---
    static let elementHeightMedium: CGFloat = 32  // --size-element-md
}

// MARK: - Theme

/// Astryx のテーマトークン束。`AstryxTheme.shared` だけを使う。
struct AstryxTheme {

    static let shared = AstryxTheme()

    // 面
    var background: Color = AstryxTokens.backgroundBody
    var surface: Color = AstryxTokens.backgroundSurface
    var surfaceRaised: Color = AstryxTokens.backgroundGray
    /// `--color-background-card`。neutral dark では背景と同値 (#1B1B1B) で、
    /// カードの区切りは `border` の 1px だけ（Astryx の実描画と同じ）。
    var card: Color = AstryxTokens.backgroundCard

    // 文字
    var textPrimary: Color = AstryxTokens.textPrimary
    var textSecondary: Color = AstryxTokens.textSecondary

    // 線
    var border: Color = AstryxTokens.border

    // 強調
    var accent: Color = AstryxTokens.accent
    var onAccent: Color = AstryxTokens.onAccent
    var danger: Color = AstryxTokens.error

    // 角丸
    var radiusSmall: CGFloat = AstryxTokens.radiusSmall
    var radiusMedium: CGFloat = AstryxTokens.radiusMedium
    var radiusLarge: CGFloat = AstryxTokens.radiusLarge

    /// Astryx は dark トークンで固定（CONTRACT §1）。
    var colorScheme: ColorScheme { .dark }

    /// 追加: 補助的に使うトークン（CONTRACT の追加は可）。
    var accentMuted: Color = AstryxTokens.accentMuted
    var success: Color = AstryxTokens.success
    var radiusFull: CGFloat = AstryxTokens.radiusFull
    /// 既定のボタン高さ = `--size-element-md`（32px）。
    var elementHeight: CGFloat = AstryxTokens.elementHeightMedium

    init() {}

    // MARK: spacing

    /// `--spacing-*`（1rem = 16pt 換算）。Astryx の 4px グリッド。
    func space(_ step: AstryxSpace) -> CGFloat {
        switch step {
        case .xxs: return 4    // --spacing-1    0.25rem
        case .xs:  return 8    // --spacing-2    0.5rem
        case .sm:  return 12   // --spacing-3    0.75rem
        case .md:  return 16   // --spacing-4    1rem
        case .lg:  return 20   // --spacing-5    1.25rem
        case .xl:  return 24   // --spacing-6    1.5rem
        case .xxl: return 32   // --spacing-8    2rem
        }
    }

    // MARK: typography

    /// `--text-*` の size / weight。iOS では SF (system font) に写像する。
    /// 行間・Dynamic Type の完全一致は未対応（docs/ASTRYX.md の「未対応」参照）。
    func font(_ role: AstryxFontRole) -> Font {
        switch role {
        case .display:  return .system(size: 35, weight: .regular)   // --font-size-4xl 2.1875rem
        case .heading1: return .system(size: 24, weight: .semibold)  // --font-size-2xl 1.5rem
        case .heading2: return .system(size: 20, weight: .semibold)  // --font-size-xl  1.25rem
        case .heading3: return .system(size: 17, weight: .bold)      // --font-size-lg  1.0625rem / theme は bold
        case .body:     return .system(size: 14, weight: .regular)   // --font-size-base 0.875rem
        case .label:    return .system(size: 14, weight: .medium)    // label = base + medium
        case .caption:  return .system(size: 12, weight: .regular)   // --font-size-sm  0.75rem
        }
    }
}

// MARK: - Color(hex:)

private extension Color {
    /// `#RRGGBB` を sRGB で。`alpha` は 0...1。
    init(astryxHex hex: UInt32, alpha: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// CSS の 8 桁 hex（`#RRGGBBAA`）の AA 部分をそのまま渡す版。
    init(astryxHex hex: UInt32, alphaByte: UInt32) {
        self.init(astryxHex: hex, alpha: Double(alphaByte & 0xFF) / 255.0)
    }
}
