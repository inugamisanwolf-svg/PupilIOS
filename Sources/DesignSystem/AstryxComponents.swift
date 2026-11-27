//
//  AstryxComponents.swift
//  PupilIOS
//
//  Astryx のプリミティブ（Card / Badge / Button / Divider / ...）に対応する SwiftUI 部品。
//  色・余白・角丸・書体はすべて AstryxTheme（= Astryx の CSS custom property 実値）から取る。
//  見た目の根拠は docs/ASTRYX.md。
//

import SwiftUI
import UIKit

// MARK: - Card

/// `Card`（Astryx core）相当。
///
/// neutral dark では `--color-background-card` が背景と同値 (#1B1B1B) で、
/// 区切りは 1px の `--color-border` だけ（実測: docs/ASTRYX.md）。そのまま踏襲する。
struct AstryxCard<Content: View>: View {

    private let padding: AstryxSpace
    private let content: Content

    init(padding: AstryxSpace = .md, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let theme = AstryxTheme.shared
        let radius = theme.radiusLarge
        return content
            .padding(theme.space(padding))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
    }
}

// MARK: - Badge

/// `Badge`（Astryx core）相当。`tint` はピルの塗り色。
///
/// 文字色は tint の輝度から自動で決める（暗い塗り→白文字 / 明るい塗り→濃色文字）。
/// これで `AstryxBadge("12", tint: theme.surfaceRaised)` のように暗い色を渡しても読める。
struct AstryxBadge: View {

    private let text: String
    private let tint: Color

    init(_ text: String, tint: Color = AstryxTheme.shared.accent) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        let theme = AstryxTheme.shared
        return Text(text)
            .font(theme.font(.caption))
            .lineLimit(1)
            .foregroundColor(AstryxContrast.readableForeground(on: tint))
            .padding(.horizontal, theme.space(.xs))
            .padding(.vertical, 2)
            .background(tint)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
    }
}

// MARK: - Chip

/// タグチップ。`selected` で accent 塗りに切り替わる。
struct AstryxChip: View {

    private let text: String
    private let selected: Bool
    private let action: () -> Void

    init(_ text: String, selected: Bool, action: @escaping () -> Void) {
        self.text = text
        self.selected = selected
        self.action = action
    }

    var body: some View {
        let theme = AstryxTheme.shared
        return Button(action: action) {
            Text(text)
                .font(theme.font(.caption))
                .lineLimit(1)
                .foregroundColor(selected ? theme.onAccent : theme.textSecondary)
                .padding(.horizontal, theme.space(.xs))
                .padding(.vertical, theme.space(.xxs))
                .background(selected ? theme.accent : Color.clear)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : theme.border, lineWidth: 1))
        }
        .buttonStyle(AstryxPlainButtonStyle())
    }
}

/// チップ用の「押下時だけ薄くなる」スタイル。
private struct AstryxPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - Button

/// Astryx `Button` の variant に対応する ButtonStyle。
///
/// `Astryx Button` の既定 variant は `secondary`（Astryx の Button.d.ts より）。
/// `.buttonStyle(.astryx)` でそのまま使え、`primary` / `ghost` / `destructive` は
/// 明示的に選ぶ。
struct AstryxButtonStyle: ButtonStyle {

    enum Variant: Equatable {
        case primary
        case secondary
        case ghost
        case destructive
    }

    private let variant: Variant
    private let fullWidth: Bool

    init(_ variant: Variant = .secondary, fullWidth: Bool = false) {
        self.variant = variant
        self.fullWidth = fullWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        let theme = AstryxTheme.shared
        return configuration.label
            .font(theme.font(.label))
            .foregroundColor(foreground(theme))
            .padding(.horizontal, theme.space(.md))
            .frame(minHeight: theme.elementHeight)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background(theme))
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                    .strokeBorder(borderColor(theme), lineWidth: variant == .secondary ? 1 : 0)
            )
            .opacity(configuration.isPressed ? 0.82 : 1.0)
    }

    private func foreground(_ theme: AstryxTheme) -> Color {
        switch variant {
        case .primary, .destructive:
            return theme.onAccent
        case .secondary, .ghost:
            return theme.textPrimary
        }
    }

    private func background(_ theme: AstryxTheme) -> Color {
        switch variant {
        case .primary:
            return theme.accent
        case .secondary:
            return theme.surfaceRaised
        case .ghost:
            return Color.clear
        case .destructive:
            return theme.danger
        }
    }

    private func borderColor(_ theme: AstryxTheme) -> Color {
        variant == .secondary ? theme.border : Color.clear
    }
}

extension ButtonStyle where Self == AstryxButtonStyle {
    /// `.buttonStyle(.astryx)` — Astryx 既定の secondary。
    static var astryx: AstryxButtonStyle { AstryxButtonStyle() }
    /// `.buttonStyle(.astryxPrimary)` — 主要アクション。
    static var astryxPrimary: AstryxButtonStyle { AstryxButtonStyle(.primary) }
    /// `.buttonStyle(.astryxGhost)` — 背景なし。
    static var astryxGhost: AstryxButtonStyle { AstryxButtonStyle(.ghost) }
    /// `.buttonStyle(.astryxDestructive)` — 破壊的操作。
    static var astryxDestructive: AstryxButtonStyle { AstryxButtonStyle(.destructive) }
}

// MARK: - Section header

/// セクション見出し（`--text-heading-3` = 17pt bold）。
struct AstryxSectionHeader: View {

    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        let theme = AstryxTheme.shared
        return Text(title)
            .font(theme.font(.heading3))
            .foregroundColor(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, theme.space(.xxs))
    }
}

// MARK: - Divider

/// `Divider`（Astryx core）相当。`--color-border` の 1px 線。
struct AstryxDivider: View {

    var body: some View {
        Rectangle()
            .fill(AstryxTheme.shared.border)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
    }
}

// MARK: - Progress dots

/// ページ送り表示。`total` が 12 を超えるときは現在ページ周辺の 12 個だけを出す
/// （数千ページのギャラリーでも破綻しないため。docs/ASTRYX.md の「未対応/意図的な差」参照）。
struct AstryxProgressDots: View {

    private let current: Int
    private let total: Int
    private let windowSize = 12

    init(current: Int, total: Int) {
        self.current = current
        self.total = total
    }

    var body: some View {
        let theme = AstryxTheme.shared
        let count = max(total, 0)
        let index = min(max(current, 0), max(count - 1, 0))
        let window = Self.window(total: count, index: index, size: windowSize)

        return HStack(spacing: 6) {
            ForEach(window, id: \.self) { page in
                Circle()
                    .fill(page == index ? theme.accent : theme.border)
                    .frame(width: page == index ? 7 : 5, height: page == index ? 7 : 5)
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.15), value: index)
    }

    private static func window(total: Int, index: Int, size: Int) -> [Int] {
        guard total > 0 else { return [] }
        guard total > size else { return Array(0..<total) }
        var start = index - size / 2
        if start < 0 { start = 0 }
        if start > total - size { start = total - size }
        return Array(start..<(start + size))
    }
}

// MARK: - コントラスト補助

/// `Color` の相対輝度から読みやすい文字色を選ぶ。
enum AstryxContrast {

    static func readableForeground(on background: Color) -> Color {
        luminance(of: background) > 0.55
            ? AstryxTheme.shared.onAccent
            : AstryxTheme.shared.textPrimary
    }

    static func luminance(of color: Color) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let ui = UIColor(color)
        guard ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        return 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
    }
}
