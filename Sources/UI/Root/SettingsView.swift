import SwiftUI
import UIKit

/// 設定タブ。
///
/// ネイティブの `Form` は `AstryxTheme` の面と配色で描き、そのうえで本物の
/// Astryx（React）を WKWebView で描いた設定面と About を別ページとして持つ。
/// Astryx 面はオフラインで動く同梱物なので、ここでは高さだけ与えて配置する。
/// 設定値の正本はあくまでネイティブの `Settings` で、Astryx 面はイベントで
/// それを書き換えるだけ（どちらの面から変えても値は一致する）。
struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: Library

    private var theme: AstryxTheme { AstryxTheme.shared }

    private static let perPageOptions: [Int] = [12, 24, 36, 48, 60]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Group {
                        Toggle("日本語タイトルを優先", isOn: $settings.japaneseTitles)
                            .tint(theme.accent)

                        Picker("タグ翻訳", selection: $settings.tagTranslation) {
                            Text("なし").tag("")
                            ForEach(TagTranslations.availableLanguages, id: \.self) { code in
                                Text(SettingsView.languageName(code)).tag(code)
                            }
                        }
                    }
                    .listRowBackground(theme.surface)
                } header: {
                    sectionHeader("表示")
                }

                Section {
                    Group {
                        Picker("1ページの件数", selection: $settings.perPage) {
                            ForEach(SettingsView.perPageOptions, id: \.self) { value in
                                Text("\(value) 件").tag(value)
                            }
                        }

                        Picker("テーマ", selection: $settings.theme) {
                            Text("システム").tag("system")
                            Text("ダーク").tag("dark")
                            Text("ライト").tag("light")
                        }
                    }
                    .listRowBackground(theme.surface)
                } header: {
                    sectionHeader("外観")
                }

                Section {
                    Group {
                        Picker("既定の並び順", selection: $settings.browseSort) {
                            ForEach(SortMode.allCases) { mode in
                                Text(mode.label).tag(mode.rawValue)
                            }
                        }

                        Picker("既定の言語", selection: $settings.browseLanguage) {
                            // `Settings.languages` はタプルなので keyPath で識別できない。
                            // 添字で回す。
                            ForEach(Settings.languages.indices, id: \.self) { index in
                                Text(Settings.languages[index].label)
                                    .tag(Settings.languages[index].id)
                            }
                        }
                    }
                    .listRowBackground(theme.surface)
                } header: {
                    sectionHeader("ブラウズ")
                }

                Section {
                    Group {
                        NavigationLink {
                            AstryxSettingsSurface(settings: settings)
                        } label: {
                            Label("Astryx 設定パネル", systemImage: "slider.horizontal.3")
                        }

                        NavigationLink {
                            AboutView()
                        } label: {
                            Label("Pupil について", systemImage: "info.circle")
                        }
                    }
                    .listRowBackground(theme.surface)
                } header: {
                    sectionHeader("Astryx")
                }

                Section {
                    Group {
                        if library.favoriteTags.isEmpty {
                            Text("お気に入りタグはまだありません")
                                .foregroundColor(theme.textSecondary)
                        } else {
                            ForEach(library.favoriteTags, id: \.self) { tag in
                                Text(tag).lineLimit(1)
                            }
                            .onDelete(perform: deleteFavoriteTags)
                        }
                    }
                    .listRowBackground(theme.surface)
                } header: {
                    sectionHeader("お気に入りタグ")
                }

                Section {
                    Group {
                        Button(role: .destructive) {
                            library.clearHistory()
                        } label: {
                            Text("履歴を消去")
                        }

                        Text(PupilIOSAppInfo.versionLine)
                            .foregroundColor(theme.textSecondary)
                    }
                    .listRowBackground(theme.surface)
                } header: {
                    sectionHeader("データ")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .tint(theme.accent)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundColor(theme.textSecondary)
    }

    private func deleteFavoriteTags(at offsets: IndexSet) {
        let tags = offsets.compactMap { index -> String? in
            library.favoriteTags.indices.contains(index) ? library.favoriteTags[index] : nil
        }
        for tag in tags {
            library.toggleFavoriteTag(tag)
        }
    }

    /// タグ翻訳のファイル名（es / id / ko / zh）を読める名前にする。
    static func languageName(_ code: String) -> String {
        switch code.lowercased() {
        case "es": return "スペイン語"
        case "id": return "インドネシア語"
        case "ko": return "韓国語"
        case "zh": return "中国語"
        case "ja": return "日本語"
        case "en": return "英語"
        default: return code
        }
    }
}

/// アプリ名とバージョン。About と設定の両方が使う。
enum PupilIOSAppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        if let build = build, !build.isEmpty {
            return "\(short) (\(build))"
        }
        return short
    }

    static var versionLine: String {
        "Pupil \(version)"
    }
}

/// Astryx 面から飛んできた URL を開く。http/https だけ通す。
private func openExternalURL(_ string: String?) {
    guard let string = string,
          let url = URL(string: string),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else { return }

    UIApplication.shared.open(url, options: [:], completionHandler: nil)
}

// MARK: - Astryx 設定面

/// 本物の Astryx を WKWebView で描いた設定面。
///
/// イベントは `{name, payload}` で届く。`payload["key"]` / `payload["value"]` の
/// 組を 1 つの形として受け、`name` 自体が設定キーになっている場合も同じ経路で
/// 扱う（Astryx 側の実装がどちらでも動くようにするため）。
private struct AstryxSettingsSurface: View {
    @ObservedObject var settings: Settings

    private var theme: AstryxTheme { AstryxTheme.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.md)) {
                Text("Astryx 設定パネル")
                    .font(theme.font(.heading2))
                    .foregroundColor(theme.textPrimary)

                Text("Astryx コンポーネントで描いた面です。ここでの変更はネイティブの設定と同じ値に反映されます。")
                    .font(theme.font(.caption))
                    .foregroundColor(theme.textSecondary)

                AstryxWebView(surface: .settings, payload: payload, onEvent: apply)
                    .frame(height: 620)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    )
            }
            .padding(theme.space(.md))
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Astryx 設定")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Astryx 面に渡す現在値。すべて文字列（`[String: String]`）。
    private var payload: [String: String] {
        [
            "appName": "Pupil",
            "japaneseTitles": settings.japaneseTitles ? "true" : "false",
            "tagTranslation": settings.tagTranslation,
            "perPage": String(settings.perPage),
            "theme": settings.theme,
            "browseSort": settings.browseSort,
            "browseLanguage": settings.browseLanguage,
            "languages": Settings.languages.map { "\($0.id)=\($0.label)" }.joined(separator: ","),
            "sortModes": SortMode.allCases.map { "\($0.rawValue)=\($0.label)" }.joined(separator: ","),
            "tagTranslationLanguages": TagTranslations.availableLanguages.joined(separator: ","),
        ]
    }

    /// Astryx（JS）からのイベント。
    ///
    /// `setting` は `{key, value}`、`openurl` は `{url}`、`ready` は `{surface, core}`。
    /// `ready` は何もしない。`setting` のキーが `payload` に無く `name` 自体に
    /// なっている場合も同じ経路で扱う（Astryx 側の実装がどちらでも動くように）。
    private func apply(_ name: String, _ eventPayload: [String: String]) {
        switch name {
        case "openurl":
            openExternalURL(eventPayload["url"])
            return
        case "ready":
            return
        default:
            break
        }

        let key = eventPayload["key"] ?? name
        let value = eventPayload["value"] ?? ""

        switch key {
        case "japaneseTitles":
            settings.japaneseTitles = (value == "true" || value == "1" || value == "on")
        case "tagTranslation":
            settings.tagTranslation = value
        case "perPage":
            if let number = Int(value), number > 0 {
                settings.perPage = number
            }
        case "theme":
            if ["system", "dark", "light"].contains(value) {
                settings.theme = value
            }
        case "browseSort":
            if SortMode(rawValue: value) != nil {
                settings.browseSort = value
            }
        case "browseLanguage":
            if !value.isEmpty {
                settings.browseLanguage = value
            }
        default:
            break
        }
    }
}

// MARK: - About

/// About。GPLv3 と移植元、Astryx の MIT を明記する。
///
/// 表記は SwiftUI 側でも直に置き、Astryx の About 面はその上に重ねる形に
/// してある（WebView が読めない環境でもライセンス表記が消えないように）。
private struct AboutView: View {
    private var theme: AstryxTheme { AstryxTheme.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.md)) {
                VStack(alignment: .leading, spacing: theme.space(.xxs)) {
                    Text("Pupil")
                        .font(theme.font(.display))
                        .foregroundColor(theme.textPrimary)

                    Text("hitomi.la ビューア（iOS 移植）")
                        .font(theme.font(.body))
                        .foregroundColor(theme.textSecondary)

                    Text(PupilIOSAppInfo.versionLine)
                        .font(theme.font(.caption))
                        .foregroundColor(theme.textSecondary)
                        .monospacedDigit()
                }

                AstryxDivider()

                VStack(alignment: .leading, spacing: theme.space(.xs)) {
                    Text("ライセンス")
                        .font(theme.font(.heading3))
                        .foregroundColor(theme.textPrimary)

                    Text("Pupil は GNU General Public License v3.0 の下で配布されます。本アプリは Android 版 Pupil の移植で、同じライセンスを引き継ぎます。")
                        .font(theme.font(.body))
                        .foregroundColor(theme.textPrimary)

                    Link("移植元: codeberg.org/pupil/Pupil", destination: URL(string: "https://codeberg.org/pupil/Pupil") ?? URL(string: "https://codeberg.org")!)
                        .font(theme.font(.caption))
                        .foregroundColor(theme.accent)

                    Text("GNU GPL v3.0 全文: https://www.gnu.org/licenses/gpl-3.0.txt")
                        .font(theme.font(.caption))
                        .foregroundColor(theme.textSecondary)

                    Text("デザインシステム Astryx は MIT License の下で利用しています。")
                        .font(theme.font(.body))
                        .foregroundColor(theme.textPrimary)
                }

                AstryxDivider()

                VStack(alignment: .leading, spacing: theme.space(.xs)) {
                    Text("注意")
                        .font(theme.font(.heading3))
                        .foregroundColor(theme.textPrimary)

                    Text("本アプリは hitomi.la 上のコンテンツを表示するビューアです。コンテンツの権利は各権利者に帰属し、本アプリは何も配布しません。")
                        .font(theme.font(.caption))
                        .foregroundColor(theme.textSecondary)
                }

                AstryxWebView(surface: .about, payload: aboutPayload, onEvent: handleEvent)
                    .frame(height: 620)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    )
            }
            .padding(theme.space(.md))
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Pupil について")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var aboutPayload: [String: String] {
        [
            "appName": "Pupil",
            "version": PupilIOSAppInfo.version,
            "license": "GPL-3.0",
            "upstream": "https://codeberg.org/pupil/Pupil",
            "astryxLicense": "MIT",
        ]
    }

    /// About 面のイベント。`openurl` だけ拾う。
    private func handleEvent(_ name: String, _ payload: [String: String]) {
        guard name == "openurl" else { return }
        openExternalURL(payload["url"])
    }
}
