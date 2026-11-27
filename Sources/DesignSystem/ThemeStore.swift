//
//  ThemeStore.swift
//  PupilIOS
//
//  カスタムテーマ / 壁紙の永続化ストア（CONTRACT §1.5）。
//
//  - 色パレットは UserDefaults に JSON で保存
//  - 壁紙画像は Application Support/Wallpaper/<uuid>.jpg に保存し、Wallpaper.fileName に持つ
//    （差し替え時は旧ファイルを削除）
//  - revision は変更のたび +1。Root 側が `.id(ThemeStore.shared.revision)` で再構築する
//
//  ## 隔離（重要）
//  このクラスには @MainActor を付けない。`AstryxTheme.shared` は
//  `AstryxTheme.shared.accent` のような既定引数・computed property から
//  非隔離文脈で読まれるため、@MainActor を付けると隔離違反になる。
//  変更系メソッドは SwiftUI（メインスレッド）から呼ばれる前提とし、
//  デバッグビルドでは `dispatchPrecondition` でメインスレッドを検証する。
//

import Dispatch
import Foundation
import ImageIO
import SwiftUI
import UIKit

// MARK: - 色キー

/// ユーザーが個別に編集できる 9 つの色。並び順がそのまま編集画面の並び順になる。
enum ThemeColorKey: String, CaseIterable, Codable {
    case accent, onAccent, background, surface, surfaceRaised, textPrimary, textSecondary, border, danger

    var label: String {
        switch self {
        case .accent: return "アクセント（ボタン等）"
        case .onAccent: return "アクセント上の文字"
        case .background: return "背景"
        case .surface: return "面（カード）"
        case .surfaceRaised: return "浮いた面"
        case .textPrimary: return "本文"
        case .textSecondary: return "補助テキスト"
        case .border: return "境界線"
        case .danger: return "危険（削除など）"
        }
    }
}

// MARK: - 壁紙

enum WallpaperKind: String, Codable {
    case none, preset, image
}

struct Wallpaper: Codable, Equatable {
    var kind: WallpaperKind
    /// kind == .preset のときの `WallpaperPreset.rawValue`。
    var presetID: String
    /// kind == .image のとき Application Support/Wallpaper/ 内のファイル名。
    var fileName: String

    static let none = Wallpaper(kind: .none, presetID: "", fileName: "")

    static func preset(_ id: String) -> Wallpaper {
        Wallpaper(kind: .preset, presetID: id, fileName: "")
    }

    static func image(_ fileName: String) -> Wallpaper {
        Wallpaper(kind: .image, presetID: "", fileName: fileName)
    }
}

// MARK: - パレット

struct ThemePalette: Codable, Equatable {
    var accent: String            // "#RRGGBB"
    var onAccent: String
    var background: String
    var surface: String
    var surfaceRaised: String
    var textPrimary: String
    var textSecondary: String
    var border: String            // "#RRGGBB"（不透明）。描画時に alpha 0.12 相当を再現する
    var danger: String
    var wallpaper: Wallpaper

    subscript(_ key: ThemeColorKey) -> String {
        get {
            switch key {
            case .accent: return accent
            case .onAccent: return onAccent
            case .background: return background
            case .surface: return surface
            case .surfaceRaised: return surfaceRaised
            case .textPrimary: return textPrimary
            case .textSecondary: return textSecondary
            case .border: return border
            case .danger: return danger
            }
        }
        set {
            switch key {
            case .accent: accent = newValue
            case .onAccent: onAccent = newValue
            case .background: background = newValue
            case .surface: surface = newValue
            case .surfaceRaised: surfaceRaised = newValue
            case .textPrimary: textPrimary = newValue
            case .textSecondary: textSecondary = newValue
            case .border: border = newValue
            case .danger: danger = newValue
            }
        }
    }

    /// 保存データの hex を "#RRGGBB" に正規化する。壊れた値は入れ替える。
    func sanitized() -> ThemePalette {
        var copy = self
        for key in ThemeColorKey.allCases {
            copy[key] = AstryxHex.isValidHex(self[key])
                ? AstryxHex.normalized(self[key])
                : AstryxThemeDefaults.value(for: key)
        }
        if copy.wallpaper.kind == .image && copy.wallpaper.fileName.isEmpty {
            copy.wallpaper = .none
        }
        if copy.wallpaper.kind == .preset && WallpaperPreset(rawValue: copy.wallpaper.presetID) == nil {
            copy.wallpaper = .none
        }
        return copy
    }
}

/// 壊れた保存データを直すときの最終フォールバック（Astryx neutral dark）。
enum AstryxThemeDefaults {
    static func value(for key: ThemeColorKey) -> String {
        switch key {
        case .accent: return AstryxTokens.accent
        case .onAccent: return AstryxTokens.onAccent
        case .background: return AstryxTokens.background
        case .surface: return AstryxTokens.surface
        case .surfaceRaised: return AstryxTokens.surfaceRaised
        case .textPrimary: return AstryxTokens.textPrimary
        case .textSecondary: return AstryxTokens.textSecondary
        case .border: return AstryxTokens.border
        case .danger: return AstryxTokens.danger
        }
    }
}

// MARK: - 壁紙ファイル

/// Application Support/Wallpaper/ の読み書き。MainActor 非依存（描画側から直接使える）。
final class WallpaperImageCache {

    static let shared = WallpaperImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 4
    }

    static var directoryURL: URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let url = base.appendingPathComponent("Wallpaper", isDirectory: true)
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func image(fileName: String) -> UIImage? {
        guard !fileName.isEmpty else { return nil }
        if let cached = cache.object(forKey: fileName as NSString) {
            return cached
        }
        let url = WallpaperImageCache.directoryURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: fileName as NSString)
        return image
    }

    /// 実ファイルがあるか（デコードはしない）。`screenBackground` の判定用。
    func exists(fileName: String) -> Bool {
        guard !fileName.isEmpty else { return false }
        if cache.object(forKey: fileName as NSString) != nil { return true }
        return FileManager.default.fileExists(
            atPath: WallpaperImageCache.directoryURL.appendingPathComponent(fileName).path
        )
    }

    /// 画像データを保存してファイル名を返す（取り込みの本線）。
    /// `CGImageSource` のサムネイル生成を `kCGImageSourceCreateThumbnailWithTransform: true` で
    /// 使うので **EXIF の回転がピクセルに焼き込まれる**（横向き写真が保存後に回転しない）。
    func save(imageData data: Data) -> String? {
        guard let prepared = WallpaperImageCache.decoded(data: data, maxDimension: 2400) else {
            return nil
        }
        return write(prepared)
    }

    /// UIImage から保存する版（互換用）。向きは再描画で焼き込む。
    func save(image: UIImage) -> String? {
        write(WallpaperImageCache.redrawn(image, maxDimension: 2400))
    }

    private func write(_ image: UIImage) -> String? {
        let fileName: String
        let bytes: Data
        if let jpeg = image.jpegData(compressionQuality: 0.92) {
            fileName = "wallpaper-\(UUID().uuidString).jpg"
            bytes = jpeg
        } else if let png = image.pngData() {
            fileName = "wallpaper-\(UUID().uuidString).png"
            bytes = png
        } else {
            return nil
        }

        let url = WallpaperImageCache.directoryURL.appendingPathComponent(fileName)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        // 取り込み直後でも `wallpaperImage()` が返せるよう、キャッシュに投入しておく。
        cache.setObject(image, forKey: fileName as NSString)
        return fileName
    }

    func delete(fileName: String) {
        guard !fileName.isEmpty else { return }
        cache.removeObject(forKey: fileName as NSString)
        let url = WallpaperImageCache.directoryURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    /// 参照されていない壁紙ファイルを掃除する。
    func removeOrphans(keeping fileName: String) {
        let manager = FileManager.default
        let dir = WallpaperImageCache.directoryURL
        guard let contents = try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents where url.lastPathComponent != fileName {
            try? manager.removeItem(at: url)
        }
    }

    /// 受け取った画像データを、向きを正した長辺 `maxDimension` 以下の UIImage にする。
    ///
    /// `kCGImageSourceCreateThumbnailWithTransform: true` により **EXIF の回転が適用される**
    /// （これが無いと横向き写真が回転したまま保存される）。ImageIO が扱えない形式のときだけ
    /// UIKit の再描画にフォールバックする（`UIImage.draw(in:)` も向きを適用する）。
    static func decoded(data: Data, maxDimension: CGFloat) -> UIImage? {
        let pixelSize = Int(maxDimension.rounded())

        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: thumbnail)
            }
        }

        guard let image = UIImage(data: data) else { return nil }
        return redrawn(image, maxDimension: maxDimension)
    }

    /// 向きが .up でない、または大きすぎる画像を、向きを焼き込んだ上で縮小する。
    static func redrawn(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return image }

        let scale = longest > maxDimension ? maxDimension / longest : 1.0
        if scale == 1.0 && image.imageOrientation == .up {
            return image
        }

        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// 旧名（互換）。
    static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        redrawn(image, maxDimension: maxDimension)
    }
}

// MARK: - Store

final class ThemeStore: ObservableObject {

    static let shared = ThemeStore()

    private static let paletteKey = "theme.palette.v1"
    private static let presetKey = "theme.basePreset.v1"

    @Published private(set) var palette: ThemePalette
    @Published private(set) var revision: Int
    /// プリセットそのままの状態のときだけ非 nil。色を 1 つでも編集すると nil。
    @Published private(set) var activePreset: ThemePreset?

    /// 「プリセットに戻す」の戻り先。編集後も直前のプリセットを覚えておく。
    private var basePreset: ThemePreset = .astryx
    /// ユーザーが onAccent を明示的に編集したか（accent 変更時の自動追従を止める）。
    private var hasCustomOnAccent = false

    private init() {
        let defaults = UserDefaults.standard

        var loaded = ThemePreset.astryx.palette
        if let data = defaults.data(forKey: ThemeStore.paletteKey),
           let decoded = try? JSONDecoder().decode(ThemePalette.self, from: data) {
            loaded = decoded.sanitized()
        }

        let preset = ThemePreset(rawValue: defaults.string(forKey: ThemeStore.presetKey) ?? "")
            ?? ThemePreset.astryx

        palette = loaded
        revision = 0
        basePreset = preset
        activePreset = (loaded == preset.palette) ? preset : nil
        hasCustomOnAccent = (loaded.onAccent != AstryxContrast.readableHexForeground(on: loaded.accent))

        // 壁紙の自己修復: 画像ファイルが消えている / 壊れている場合はプリセットグラデへ戻す。
        // これをやらないと、次回起動で「黒一色」になる。
        let healed = ThemeStore.healedWallpaper(
            palette.wallpaper,
            fallbackID: preset.defaultWallpaper.presetID
        )
        if healed != palette.wallpaper {
            palette.wallpaper = healed
            activePreset = (palette == preset.palette) ? preset : nil
            persist()
        }
    }

    /// 描画できない壁紙をプリセットへ戻す純粋関数。
    /// - `.none` はそのまま
    /// - `.preset` は未知の ID なら `fallbackID`（無効なら `paper`）へ
    /// - `.image` は実ファイルが無ければ、元の `presetID` → `fallbackID` → `paper` の順で復元
    static func healedWallpaper(_ wallpaper: Wallpaper, fallbackID: String) -> Wallpaper {
        switch wallpaper.kind {
        case .none:
            return wallpaper

        case .preset:
            if WallpaperPreset(rawValue: wallpaper.presetID) != nil { return wallpaper }
            let restored = WallpaperPreset(rawValue: fallbackID)?.rawValue ?? WallpaperPreset.paper.rawValue
            return .preset(restored)

        case .image:
            if WallpaperImageCache.shared.exists(fileName: wallpaper.fileName) { return wallpaper }
            let restored = WallpaperPreset(rawValue: wallpaper.presetID)?.rawValue
                ?? WallpaperPreset(rawValue: fallbackID)?.rawValue
                ?? WallpaperPreset.paper.rawValue
            return .preset(restored)
        }
    }

    // MARK: プリセット

    func apply(_ preset: ThemePreset) {
        assertMainThread()
        basePreset = preset
        hasCustomOnAccent = false
        palette = preset.palette
        activePreset = preset
        commit()
    }

    func setHex(_ hex: String, for key: ThemeColorKey) {
        assertMainThread()
        let normalized = AstryxHex.normalized(hex)
        guard normalized != palette[key] else { return }

        palette[key] = normalized
        activePreset = nil

        if key == .accent {
            // accent を変えたら onAccent は自動でコントラストを保つ（ユーザーが明示編集するまでは）。
            let derived = AstryxContrast.readableHexForeground(on: normalized)
            if !hasCustomOnAccent {
                palette.onAccent = derived
            }
        } else if key == .onAccent {
            hasCustomOnAccent = true
        }

        commit()
    }

    func resetToPreset() {
        assertMainThread()
        hasCustomOnAccent = false
        apply(basePreset)
    }

    // MARK: 壁紙

    func setWallpaper(_ wallpaper: Wallpaper) {
        assertMainThread()
        let previous = palette.wallpaper
        guard previous != wallpaper else { return }

        palette.wallpaper = wallpaper
        if previous.kind == .image, previous.fileName != wallpaper.fileName {
            WallpaperImageCache.shared.delete(fileName: previous.fileName)
        }
        commit()
    }

    /// 画像を取り込み、壁紙に設定する。
    ///
    /// 成功条件（すべて満たしたときだけ true）:
    ///  1. 画像として解釈できる（ImageIO / UIImage）
    ///  2. `Application Support/Wallpaper/` に書き込み成功
    ///  3. `palette.wallpaper = .image(fileName)`
    ///  4. `revision += 1`（commit 内）
    ///  5. 直後に `wallpaperImage()` がその画像を返す（`save` がキャッシュに投入済み）
    @discardableResult
    func importWallpaper(data: Data) -> Bool {
        assertMainThread()

        // 1 + 2: デコード＆向き補正＆縮小して保存（失敗すれば nil）。
        guard let fileName = WallpaperImageCache.shared.save(imageData: data) else { return false }

        // 5（先に確認）: 保存したファイルが実際に読み戻せること。
        // ここを飛ばすと「取り込み直後は黒い／再起動したら出る」になる。
        guard WallpaperImageCache.shared.image(fileName: fileName) != nil else {
            WallpaperImageCache.shared.delete(fileName: fileName)
            return false
        }

        // 3
        let previous = palette.wallpaper
        palette.wallpaper = .image(fileName)
        if previous.kind == .image, previous.fileName != fileName {
            WallpaperImageCache.shared.delete(fileName: previous.fileName)
        }
        WallpaperImageCache.shared.removeOrphans(keeping: fileName)

        // 4
        commit()
        return true
    }

    func wallpaperImage() -> UIImage? {
        guard palette.wallpaper.kind == .image else { return nil }
        return WallpaperImageCache.shared.image(fileName: palette.wallpaper.fileName)
    }

    // MARK: 永続化

    private func commit() {
        revision += 1
        persist()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(palette) {
            defaults.set(data, forKey: ThemeStore.paletteKey)
        }
        defaults.set(basePreset.rawValue, forKey: ThemeStore.presetKey)
    }

    /// デバッグ時のみメインスレッドを検証する（リリースでは no-op）。
    private func assertMainThread() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
    }
}
