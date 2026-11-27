//
//  ThemeEditorView.swift
//  PupilIOS
//
//  カスタムテーマ / 壁紙の編集画面（CONTRACT §1.5）。設定画面から NavigationLink で開く。
//
//  - 上部: プリセット 5 つ（横スクロール）
//  - 中部: 9 キーの色（ColorPicker。`ThemeStore.setHex` 経由で hex 保存）
//  - 下部: 壁紙（なし + プリセット 5 種 + PhotosPicker で画像取り込み）
//  - 最下部: プリセットに戻す
//
//  PhotosPicker は iOS 16 の out-of-process ピッカーなので、写真ライブラリの
//  権限ダイアログは出ない（NSPhotoLibraryUsageDescription も不要）。
//

import PhotosUI
import SwiftUI

struct ThemeEditorView: View {

    @ObservedObject private var store: ThemeStore
    @State private var pendingPhoto: PhotosPickerItem?
    @State private var showsImportFailure = false

    init() {
        _store = ObservedObject(wrappedValue: ThemeStore.shared)
    }

    var body: some View {
        let theme = AstryxTheme.shared

        return List {
            Section {
                previewRow(theme)
            }
            .listRowBackground(Color.clear)

            Section("プリセット") {
                presetRow(theme)
                    .listRowBackground(theme.surface)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

                Text(store.activePreset.map { "\($0.label) を使用中" } ?? "カスタム（プリセットから変更済み）")
                    .font(theme.font(.caption))
                    .foregroundColor(theme.textSecondary)
                    .listRowBackground(theme.surface)
            }

            Section("色（個別に変更できます）") {
                ForEach(ThemeColorKey.allCases, id: \.self) { key in
                    colorRow(key, theme: theme)
                }
            }

            Section("壁紙") {
                wallpaperRow(theme)
                    .listRowBackground(theme.surface)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

                PhotosPicker(selection: $pendingPhoto, matching: .images) {
                    Label("画像を読み込む", systemImage: "photo.badge.plus")
                        .font(theme.font(.body))
                        .foregroundColor(theme.accent)
                }
                .listRowBackground(theme.surface)

                Text("端末の写真から壁紙を作れます（権限ダイアログは出ません）。長辺 2400px に縮小して保存します。")
                    .font(theme.font(.caption))
                    .foregroundColor(theme.textSecondary)
                    .listRowBackground(theme.surface)
            }

            Section {
                Button(role: .destructive) {
                    store.resetToPreset()
                } label: {
                    Label("プリセットに戻す", systemImage: "arrow.counterclockwise")
                        .font(theme.font(.body))
                }
                .listRowBackground(theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .navigationTitle("テーマ")
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.accent)
        .onChange(of: pendingPhoto) { item in
            guard let item else { return }
            Task {
                await importPhoto(item)
            }
        }
        .alert("画像を読み込めませんでした", isPresented: $showsImportFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("別の画像で試してください（HEIC / JPEG / PNG に対応）。")
        }
    }

    // MARK: - プレビュー

    private func previewRow(_ theme: AstryxTheme) -> some View {
        ZStack {
            WallpaperView(palette: store.palette, fillsSafeArea: false)

            VStack(alignment: .leading, spacing: 8) {
                Text("PupilIOS")
                    .font(theme.font(.heading2))
                    .foregroundColor(theme.textPrimary)
                Text("壁紙とテーマのプレビュー")
                    .font(theme.font(.caption))
                    .foregroundColor(theme.textSecondary)

                AstryxCard {
                    Text("カードは不透明なので、壁紙の上でも本文が読めます。")
                        .font(theme.font(.body))
                        .foregroundColor(theme.textPrimary)
                }

                HStack(spacing: 8) {
                    samplePill("ボタン", background: theme.accent, foreground: theme.onAccent, theme: theme)
                    samplePill("危険", background: theme.danger, foreground: theme.onAccent, theme: theme)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private func samplePill(_ text: String,
                            background: Color,
                            foreground: Color,
                            theme: AstryxTheme) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundColor(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
    }

    // MARK: - プリセット

    private func presetRow(_ theme: AstryxTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ThemePreset.allCases, id: \.self) { preset in
                    presetChip(preset, theme: theme)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func presetChip(_ preset: ThemePreset, theme: AstryxTheme) -> some View {
        let palette = preset.palette
        let selected = store.activePreset == preset

        return Button {
            store.apply(preset)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AstryxHex.color(palette.background))
                    Circle()
                        .fill(AstryxHex.color(palette.accent))
                        .frame(width: 22, height: 22)
                }
                .frame(width: 52, height: 52)

                Text(preset.label)
                    .font(theme.font(.caption))
                    .foregroundColor(selected ? theme.accent : theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(6)
            .background(selected ? theme.surfaceRaised : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                    .strokeBorder(selected ? theme.accent : theme.border, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 色

    private func colorRow(_ key: ThemeColorKey, theme: AstryxTheme) -> some View {
        HStack(spacing: theme.space(.sm)) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AstryxHex.color(store.palette[key]))
                .frame(width: 26, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )

            Text(key.label)
                .font(theme.font(.body))
                .foregroundColor(theme.textPrimary)

            Spacer(minLength: theme.space(.sm))

            Text(store.palette[key])
                .font(theme.font(.caption))
                .foregroundColor(theme.textSecondary)

            ColorPicker("", selection: binding(for: key), supportsOpacity: false)
                .labelsHidden()
        }
        .listRowBackground(theme.surface)
    }

    private func binding(for key: ThemeColorKey) -> Binding<Color> {
        Binding(
            get: { AstryxHex.color(store.palette[key]) },
            set: { newColor in store.setHex(AstryxHex.string(from: newColor), for: key) }
        )
    }

    // MARK: - 壁紙

    private func wallpaperRow(_ theme: AstryxTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                wallpaperThumb(wallpaper: .none, label: "なし", theme: theme)

                ForEach(WallpaperPreset.allCases) { preset in
                    wallpaperThumb(wallpaper: .preset(preset.rawValue), label: preset.label, theme: theme)
                }

                if store.palette.wallpaper.kind == .image {
                    imageThumb(theme)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func wallpaperThumb(wallpaper: Wallpaper, label: String, theme: AstryxTheme) -> some View {
        let selected = store.palette.wallpaper == wallpaper
        var preview = store.palette
        preview.wallpaper = wallpaper

        return Button {
            store.setWallpaper(wallpaper)
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    WallpaperView(palette: preview, fillsSafeArea: false)
                        .frame(width: 64, height: 96)

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(theme.onAccent)
                            .background(theme.accent.clipShape(Circle()))
                            .padding(4)
                    }
                }
                .frame(width: 64, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                        .strokeBorder(selected ? theme.accent : theme.border, lineWidth: selected ? 2 : 1)
                )

                Text(label)
                    .font(theme.font(.caption))
                    .foregroundColor(selected ? theme.accent : theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 64)
            }
        }
        .buttonStyle(.plain)
    }

    private func imageThumb(_ theme: AstryxTheme) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                WallpaperView(palette: store.palette, fillsSafeArea: false)
                    .frame(width: 64, height: 96)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(theme.onAccent)
                    .background(theme.accent.clipShape(Circle()))
                    .padding(4)
            }
            .frame(width: 64, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                    .strokeBorder(theme.accent, lineWidth: 2)
            )

            Text("写真")
                .font(theme.font(.caption))
                .foregroundColor(theme.accent)
                .lineLimit(1)
                .frame(width: 64)
        }
    }

    // MARK: - 取り込み

    private func importPhoto(_ item: PhotosPickerItem) async {
        let data = try? await item.loadTransferable(type: Data.self)

        // 反映とファイル保存はメインスレッドで（ThemeStore は @MainActor ではないため明示する）。
        await MainActor.run {
            if let data = data {
                if !store.importWallpaper(data: data) {
                    showsImportFailure = true
                }
            } else {
                showsImportFailure = true
            }
            pendingPhoto = nil
        }
    }
}
