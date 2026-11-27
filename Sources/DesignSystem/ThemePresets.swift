//
//  ThemePresets.swift
//  PupilIOS
//
//  テーマ 5 プリセットと壁紙 5 プリセットの実値（CONTRACT §1.5）。
//
//  - `.astryx` = Astryx neutral dark の実値そのまま（`AstryxTokens`）
//  - 他の 4 つは Lead 指定の accent / background / surface / textPrimary を持ち、
//    残りは決定的な式で導出する（docs/ASTRYX.md「テーマ/壁紙の拡張」に明記）:
//      onAccent      = accent の相対輝度から 黒 or 白
//      surfaceRaised = surface を 6% 白へ寄せる
//      textSecondary = textPrimary を background へ 42% 寄せる
//      border        = "#FFFFFF"（描画時に alpha 0.12）
//      danger        = Astryx の --color-error dark（#FF705D）
//

import SwiftUI

// MARK: - テーマプリセット

enum ThemePreset: String, CaseIterable, Codable {
    case astryx, midnight, pink, purple, tiffany

    var label: String {
        switch self {
        case .astryx: return "Astryx"
        case .midnight: return "ミッドナイト"
        case .pink: return "ピンク"
        case .purple: return "ムラサキ"
        case .tiffany: return "Tiffany Blue"
        }
    }

    /// プリセットを選んだときの既定壁紙。
    var defaultWallpaper: Wallpaper {
        switch self {
        case .astryx: return .none
        case .midnight: return .preset(WallpaperPreset.midnight.rawValue)
        case .pink: return .preset(WallpaperPreset.pink.rawValue)
        case .purple: return .preset(WallpaperPreset.purple.rawValue)
        case .tiffany: return .preset(WallpaperPreset.tiffany.rawValue)
        }
    }

    var palette: ThemePalette {
        ThemePresetPalettes.palette(for: self)
    }
}

enum ThemePresetPalettes {

    static func palette(for preset: ThemePreset) -> ThemePalette {
        switch preset {
        case .astryx:
            return ThemePalette(
                accent: AstryxTokens.accent,
                onAccent: AstryxTokens.onAccent,
                background: AstryxTokens.background,
                surface: AstryxTokens.surface,
                surfaceRaised: AstryxTokens.surfaceRaised,
                textPrimary: AstryxTokens.textPrimary,
                textSecondary: AstryxTokens.textSecondary,
                border: AstryxTokens.border,
                danger: AstryxTokens.danger,
                wallpaper: preset.defaultWallpaper
            )
        case .midnight:
            return derived(
                accent: "#5AA9FF",
                background: "#0B0F14",
                surface: "#141A21",
                textPrimary: "#FFFFFF",
                wallpaper: preset.defaultWallpaper
            )
        case .pink:
            return derived(
                accent: "#FF5C9A",
                background: "#141013",
                surface: "#1F181C",
                textPrimary: "#FFFFFF",
                wallpaper: preset.defaultWallpaper
            )
        case .purple:
            return derived(
                accent: "#A67CFF",
                background: "#12101A",
                surface: "#1C1826",
                textPrimary: "#FFFFFF",
                wallpaper: preset.defaultWallpaper
            )
        case .tiffany:
            return derived(
                accent: "#0ABAB5",
                background: "#0E1414",
                surface: "#16201F",
                textPrimary: "#FFFFFF",
                wallpaper: preset.defaultWallpaper
            )
        }
    }

    /// 主要 4 色から残り 5 キーを決定的に導出する。
    private static func derived(accent: String,
                                background: String,
                                surface: String,
                                textPrimary: String,
                                wallpaper: Wallpaper) -> ThemePalette {
        ThemePalette(
            accent: accent,
            onAccent: AstryxContrast.readableHexForeground(on: accent),
            background: background,
            surface: surface,
            surfaceRaised: AstryxHex.mix(surface, "#FFFFFF", ratio: 0.06),
            textPrimary: textPrimary,
            textSecondary: AstryxHex.mix(textPrimary, background, ratio: 0.42),
            border: "#FFFFFF",
            danger: AstryxTokens.danger,
            wallpaper: wallpaper
        )
    }
}

// MARK: - 壁紙プリセット

/// グラデーション壁紙 5 種。`Wallpaper.presetID` はこの rawValue。
enum WallpaperPreset: String, CaseIterable, Identifiable {
    case paper, midnight, pink, purple, tiffany

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paper: return "ペーパー"
        case .midnight: return "ミッドナイト"
        case .pink: return "ピンク"
        case .purple: return "ムラサキ"
        case .tiffany: return "Tiffany Blue"
        }
    }

    /// 斜めグラデーションの開始色（左上）。
    var topHex: String {
        switch self {
        case .paper: return "#101013"
        case .midnight: return "#05070C"
        case .pink: return "#12060B"
        case .purple: return "#0D0817"
        case .tiffany: return "#04100F"
        }
    }

    /// 斜めグラデーションの終了色（右下）。
    var bottomHex: String {
        switch self {
        case .paper: return "#1C1C21"
        case .midnight: return "#12203A"
        case .pink: return "#2A0C18"
        case .purple: return "#1E1230"
        case .tiffany: return "#0C201E"
        }
    }

    /// 右上に薄く乗せるアクセントの光。`nil` なら光なし。
    var glowHex: String? {
        switch self {
        case .paper: return nil
        case .midnight: return "#5AA9FF"
        case .pink: return "#FF5C9A"
        case .purple: return "#A67CFF"
        case .tiffany: return "#0ABAB5"
        }
    }
}
