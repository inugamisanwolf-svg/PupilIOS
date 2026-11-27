//
//  WallpaperView.swift
//  PupilIOS
//
//  テーマの壁紙レイヤ（CONTRACT §1.5）。Root の最背面に敷く。
//
//  - kind == .preset: 斜めグラデーション + 右上のアクセント光（`WallpaperPreset`）
//  - kind == .image : Application Support/Wallpaper/ の画像を scaledToFill で敷き、
//                     可読性のため黒スクリム（0〜0.35）を重ねる
//  - kind == .none  : テーマの背景色べた
//
//  セーフエリア: 既定では `.ignoresSafeArea()` で画面端まで塗る。
//  サムネイル用途では `init(palette:fillsSafeArea:)` に false を渡す。
//  画像の読み込みは `WallpaperImageCache`（MainActor 非依存）経由なので、
//  この View は非隔離文脈から生成しても安全。
//

import SwiftUI
import UIKit

// MARK: - プリセット壁紙の描画

/// グラデーション壁紙 1 枚分のレイヤ。
struct WallpaperPresetLayer: View {

    let preset: WallpaperPreset

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AstryxHex.color(preset.topHex),
                    AstryxHex.color(preset.bottomHex),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let glowHex = preset.glowHex {
                let glow = AstryxHex.color(glowHex)
                RadialGradient(
                    colors: [glow.opacity(0.30), glow.opacity(0.0)],
                    center: .topTrailing,
                    startRadius: 4,
                    endRadius: 420
                )
                .blendMode(.plusLighter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 壁紙レイヤ

struct WallpaperView: View {

    private let palette: ThemePalette
    private let fillsSafeArea: Bool

    /// CONTRACT §1.5 のシグネチャ（Root から使う）。
    init(palette: ThemePalette) {
        self.init(palette: palette, fillsSafeArea: true)
    }

    /// サムネイル用。`fillsSafeArea: false` で親のサイズに収める。
    init(palette: ThemePalette, fillsSafeArea: Bool) {
        self.palette = palette
        self.fillsSafeArea = fillsSafeArea
    }

    @ViewBuilder
    var body: some View {
        if fillsSafeArea {
            layer.ignoresSafeArea()
        } else {
            layer
        }
    }

    private var layer: some View {
        ZStack {
            base
            scrim
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var base: some View {
        switch palette.wallpaper.kind {
        case .image:
            if let image = WallpaperImageCache.shared.image(fileName: palette.wallpaper.fileName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else {
                // 画像が読めない（ファイル欠損・デコード失敗）→ 黒一色にせずプリセットのグラデへ戻す。
                WallpaperPresetLayer(preset: fallbackPreset)
            }
        case .preset:
            WallpaperPresetLayer(preset: fallbackPreset)
        case .none:
            fallbackBase
        }
    }

    /// 未知の presetID でも `paper` に落として必ず何かを描く。
    private var fallbackPreset: WallpaperPreset {
        WallpaperPreset(rawValue: palette.wallpaper.presetID) ?? .paper
    }

    /// 壁紙がないとき（または画像が消えていたとき）の背景色。
    private var fallbackBase: some View {
        AstryxHex.color(palette.background)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 画像の上にだけ敷く黒スクリム。プリセットは元から暗いので敷かない。
    /// 画像が実際に描けない場合（ファイル欠損）はグラデが見えるのでスクリムも外す。
    private var scrim: Color {
        guard palette.wallpaper.kind == .image,
              WallpaperImageCache.shared.exists(fileName: palette.wallpaper.fileName) else {
            return Color.clear
        }
        let opacity = AstryxContrast.scrimOpacity(forBackgroundHex: palette.background)
        return Color.black.opacity(opacity)
    }
}
