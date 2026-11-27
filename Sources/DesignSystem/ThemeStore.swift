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

    /// 画像を保存してファイル名を返す。長辺 2400px に縮小して JPEG で保存する。
    func save(image: UIImage) -> String? {
        let prepared = WallpaperImageCache.downscaled(image, maxDimension: 2400)

        let fileName: String
        let bytes: Data
        if let jpeg = prepared.jpegData(compressionQuality: 0.92) {
            fileName = "wallpaper-\(UUID().uuidString).jpg"
            bytes = jpeg
        } else if let png = prepared.pngData() {
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
        cache.setObject(prepared, forKey: fileName as NSString)
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

    static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }

        let scale = maxDimension / longest
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
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

        // 画像壁紙の実ファイルが消えていたら「なし」に落とす。
        if loaded.wallpaper.kind == .image,
           WallpaperImageCache.shared.image(fileName: loaded.wallpaper.fileName) == nil {
            palette.wallpaper = .none
            activePreset = nil
            persist()
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

    @discardableResult
    func importWallpaper(data: Data) -> Bool {
        assertMainThread()
        guard let image = UIImage(data: data) else { return false }
        guard let fileName = WallpaperImageCache.shared.save(image: image) else { return false }

        let previous = palette.wallpaper
        palette.wallpaper = .image(fileName)
        if previous.kind == .image, previous.fileName != fileName {
            WallpaperImageCache.shared.delete(fileName: previous.fileName)
        }
        WallpaperImageCache.shared.removeOrphans(keeping: fileName)
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
