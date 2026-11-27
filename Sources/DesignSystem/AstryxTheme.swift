//
//  AstryxTheme.swift
//  PupilIOS
//
//  Astryx (Meta Open Source) のデザイントークンを Swift へ移植したもの。
//  v1.0.4 以降は「ユーザーが編集できるパレット（ThemePalette）」から都度構築する。
//
//  出典:
//    @astryxdesign/theme-neutral@0.7.17 dist/theme.css の dark 列（light-dark(a, b) の b）
//    @astryxdesign/core@0.7.17 dist/astryx.css の spacing / size / font-weight トークン
//  対応表と行番号は docs/ASTRYX.md を参照。値を変えるときは必ず元 CSS を読み直すこと。
//
//  `AstryxTheme.shared` は computed（毎回 `ThemeStore.shared.palette` から構築）。
//  呼び出し側は今まで通り `AstryxTheme.shared.accent` と書ける。
//  この型は @MainActor にしない（既定引数や computed property から非隔離文脈で読まれるため）。
//

import Foundation
import SwiftUI
import UIKit

// MARK: - スケール型

/// Astryx の spacing スケール（`--spacing-*`）に対応する抽象ステップ。
enum AstryxSpace {
    case xxs, xs, sm, md, lg, xl, xxl
}

/// Astryx のテキストロール（`--text-*-size / -weight`）に対応する抽象ロール。
enum AstryxFontRole {
    case display, heading1, heading2, heading3, body, label, caption
}

// MARK: - Astryx neutral (dark) の実値

/// `@astryxdesign/theme-neutral@0.7.17` の dark トークン実値。
/// プリセット `.astryx` の種値であり、パレットが壊れたときのフォールバックでもある。
enum AstryxTokens {

    // color（theme.css の dark 列）
    static let accent = "#F1F1F1"          // --color-accent
    static let accentMuted = "#474747"     // --color-accent-muted
    static let background = "#1B1B1B"      // --color-background-body
    static let surface = "#262626"         // --color-background-surface
    static let surfaceRaised = "#303030"   // --color-background-gray
    static let textPrimary = "#FFFFFF"     // --color-text-primary
    static let textSecondary = "#9E9E9E"   // --color-text-secondary
    static let border = "#FFFFFF"          // --color-border（描画時に alpha 0x1A ≈ 0.10）
    static let onAccent = "#111111"        // --color-on-accent
    static let danger = "#FF705D"          // --color-error
    static let success = "#64AF4C"         // --color-success

    // radius（theme-neutral の上書き値）
    static let radiusSmall: CGFloat = 6    // --radius-inner     0.375rem
    static let radiusMedium: CGFloat = 10  // --radius-element   0.625rem
    static let radiusLarge: CGFloat = 12   // --radius-container 0.75rem
    static let radiusFull: CGFloat = 9999  // --radius-full

    // size（core の :root トークン）
    static let elementHeight: CGFloat = 32 // --size-element-md
}

// MARK: - Theme

/// Astryx のテーマトークン束。`AstryxTheme.shared` だけを使う。
struct AstryxTheme {

    /// 毎回 `ThemeStore.shared.palette` から構築する（テーマ変更が即座に全画面へ効く）。
    static var shared: AstryxTheme {
        AstryxTheme(palette: ThemeStore.shared.palette)
    }

    // 面
    var background: Color
    var surface: Color
    var surfaceRaised: Color
    /// Astryx の `--color-background-card`。neutral dark では本文背景と同値で、
    /// カードの区切りは `border` の 1px だけ。壁紙の上では不透明パネルとして効く。
    var card: Color

    // 文字
    var textPrimary: Color
    var textSecondary: Color

    // 線
    var border: Color

    // 強調
    var accent: Color
    var onAccent: Color
    var danger: Color

    // 角丸
    var radiusSmall: CGFloat
    var radiusMedium: CGFloat
    var radiusLarge: CGFloat

    /// Astryx は dark トークンで固定（CONTRACT §1）。
    var colorScheme: ColorScheme { .dark }

    // 追加: 補助的に使うトークン（CONTRACT の追加は可）
    var accentMuted: Color
    var success: Color
    var radiusFull: CGFloat
    /// 既定のボタン高さ = `--size-element-md`（32px）。
    var elementHeight: CGFloat

    init(palette: ThemePalette) {
        background = AstryxHex.color(palette.background)
        surface = AstryxHex.color(palette.surface)
        surfaceRaised = AstryxHex.color(palette.surfaceRaised)
        card = AstryxHex.color(palette.background)

        textPrimary = AstryxHex.color(palette.textPrimary)
        textSecondary = AstryxHex.color(palette.textSecondary)

        // --color-border は元々「白 + alpha 0x1A」。パレットは不透明 hex なので
        // ここで相当の不透明度を掛け直す（暗すぎる境界色は見えるように持ち上げる）。
        border = AstryxHex.color(palette.border)
            .opacity(AstryxTheme.borderOpacity(forHex: palette.border))

        accent = AstryxHex.color(palette.accent)
        onAccent = AstryxHex.color(palette.onAccent)
        danger = AstryxHex.color(palette.danger)

        radiusSmall = AstryxTokens.radiusSmall
        radiusMedium = AstryxTokens.radiusMedium
        radiusLarge = AstryxTokens.radiusLarge

        accentMuted = AstryxHex.color(AstryxTokens.accentMuted)
        success = AstryxHex.color(AstryxTokens.success)
        radiusFull = AstryxTokens.radiusFull
        elementHeight = AstryxTokens.elementHeight
    }

    init() {
        self.init(palette: ThemeStore.shared.palette)
    }

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

    // MARK: border

    /// `--color-border`（白 + alpha 0x1A ≈ 0.102）相当の不透明度。
    /// パレット側は不透明 hex なので、明るさに応じて掛け率を決める。
    static func borderOpacity(forHex hex: String) -> Double {
        let luminance = AstryxHex.relativeLuminance(hex)
        if luminance < 0.02 { return 0.30 }   // ほぼ黒い境界色は 12% では見えない
        return 0.12
    }
}

// MARK: - hex ユーティリティ

/// "#RRGGBB" と SwiftUI `Color` の相互変換、輝度・混色。
enum AstryxHex {

    static func isValidHex(_ hex: String) -> Bool {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        if text.count == 8 { text = String(text.prefix(6)) }
        guard text.count == 6 else { return false }
        return text.allSatisfy { $0.isHexDigit }
    }

    /// "#RGB" / "#RRGGBB" / "RRGGBB" / "#RRGGBBAA" を "#RRGGBB" に正規化する。
    /// 解釈できない値は "#000000" を返す（呼び出し側で `isValidHex` と併用する）。
    static func normalized(_ hex: String) -> String {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        if text.count == 8 { text = String(text.prefix(6)) }
        guard text.count == 6, text.allSatisfy({ $0.isHexDigit }) else { return "#000000" }
        return "#" + text
    }

    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double) {
        let text = normalized(hex)
        let start = text.index(text.startIndex, offsetBy: 1)
        guard let value = UInt32(text[start...], radix: 16) else { return (0, 0, 0) }
        return (
            Double((value >> 16) & 0xFF) / 255.0,
            Double((value >> 8) & 0xFF) / 255.0,
            Double(value & 0xFF) / 255.0
        )
    }

    static func color(_ hex: String) -> Color {
        let components = rgb(hex)
        return Color(.sRGB, red: components.r, green: components.g, blue: components.b, opacity: 1.0)
    }

    /// `Color`（拡張色空間・P3 でも可）を sRGB の "#RRGGBB" に落とす。
    static func string(from color: Color) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#000000"
        }
        let r = Int((min(max(red, 0), 1) * 255).rounded())
        let g = Int((min(max(green, 0), 1) * 255).rounded())
        let b = Int((min(max(blue, 0), 1) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// 相対輝度（WCAG 2.x の sRGB リニア化を挟む式）。コントラスト判定に使う。
    static func relativeLuminance(_ hex: String) -> Double {
        let components = rgb(hex)

        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * channel(components.r)
            + 0.7152 * channel(components.g)
            + 0.0722 * channel(components.b)
    }

    /// 黒（#111111）と白（#FFFFFF）のうち、指定色の上でコントラストが高い方を返す。
    /// 交差するのは両者とも約 4.6:1 になる点なので、どちらを選んでも AA を満たす。
    static func bestContrastForeground(on background: String) -> String {
        let luminance = relativeLuminance(background)
        let black = (luminance + 0.05) / 0.05
        let white = 1.05 / (luminance + 0.05)
        return black >= white ? "#111111" : "#FFFFFF"
    }

    /// `a` を `b` に `ratio`（0...1）だけ寄せる。
    static func mix(_ a: String, _ b: String, ratio: Double) -> String {
        let first = rgb(a)
        let second = rgb(b)
        let t = min(max(ratio, 0), 1)

        func blend(_ x: Double, _ y: Double) -> Int {
            Int(((x * (1 - t) + y * t) * 255).rounded())
        }

        return String(
            format: "#%02X%02X%02X",
            blend(first.r, second.r),
            blend(first.g, second.g),
            blend(first.b, second.b)
        )
    }
}
