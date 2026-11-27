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

    /// 1 ページ件数を `perPageOptions` のどれかに寄せる（近いほう）。
    ///
    /// Astryx 面のステッパは 10〜100 を 10 刻みで出すので、その値をそのまま
    /// `Settings.perPage` に入れると `Picker` の選択肢と一致しなくなり、設定画面の
    /// 行が空欄になる。保存・反映の前にここで丸める。
    static func snappedPerPage(_ value: Int) -> Int? {
        guard value > 0 else { return nil }
        var best = perPageOptions[0]
        for option in perPageOptions where abs(option - value) < abs(best - value) {
            best = option
        }
        return best
    }

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
                            AstryxAboutPage()
                        } label: {
                            Label("Astryx About 面", systemImage: "sparkles")
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
            .onAppear { normalizeStoredSettings() }
        }
    }

    /// 保存値の掃除。v1.0.1 までは Astryx 面の値をそのまま `Settings` に入れて
    /// いたため、`Picker` の選択肢に無い値（perPage 10/20/…/100、未知の言語）が
    /// UserDefaults に残っている端末がありうる。`Picker` の選択が tag と一致しないと
    /// 行が空欄になるので、開いたときに丸め直す。
    private func normalizeStoredSettings() {
        if let snapped = SettingsView.snappedPerPage(settings.perPage) {
            if snapped != settings.perPage { settings.perPage = snapped }
        } else {
            settings.perPage = 24
        }

        if SortMode(rawValue: settings.browseSort) == nil {
            settings.browseSort = SortMode.popularWeek.rawValue
        }

        if !Settings.languages.contains(where: { $0.id == settings.browseLanguage }) {
            settings.browseLanguage = "all"
        }

        if !settings.tagTranslation.isEmpty,
           !TagTranslations.availableLanguages.contains(settings.tagTranslation) {
            settings.tagTranslation = ""
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
        // 親に `ScrollView` を置かない。WKWebView は自身でスクロールするので、
        // 二重スクロールは同じドラッグを奪い合い、小さい端末では面の下端に
        // 届かなくなる。面は残りの高さいっぱいに広げる。
        VStack(alignment: .leading, spacing: theme.space(.sm)) {
            Text("Astryx コンポーネントで描いた面です。ここでの変更はネイティブの設定と同じ値に反映されます。")
                .font(theme.font(.caption))
                .foregroundColor(theme.textSecondary)

            AstryxWebView(surface: .settings, payload: payload, onEvent: apply)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )
        }
        .padding(theme.space(.md))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            // 同梱 tags/*.json に無い言語を入れると、設定の Picker が
            // 一致する tag を失って空欄になる（表示だけの問題だが直せない）。
            if value.isEmpty || TagTranslations.availableLanguages.contains(value) {
                settings.tagTranslation = value
            }
        case "perPage":
            // Astryx 面は 10〜100 を 10 刻みで出すので、そのまま入れると
            // ネイティブの Picker（12/24/36/48/60）と一致しなくなる。
            if let number = Int(value), let snapped = SettingsView.snappedPerPage(number) {
                settings.perPage = snapped
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
            // 未知の言語は nozomi の URL を 404 にするだけなので捨てる。
            if Settings.languages.contains(where: { $0.id == value }) {
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
/// 表記は SwiftUI で直に置く（WebView が読めない環境でもライセンス表記が
/// 消えないように）。Astryx の About 面は高さを固定できないので別ページ
/// (`AstryxAboutPage`) に分けてある。
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
            }
            .padding(theme.space(.md))
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Pupil について")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Astryx About 面

/// Astryx の About 面。
///
/// 高さを固定せずページいっぱいに広げる。`WKWebView` 自身がスクロールするので、
/// 親に `ScrollView` を置くとドラッグを奪い合って面の下端に届かなくなる。
/// ライセンス表記はネイティブ側 (`AboutView`) にも直書きしてあるので、この面が
/// 描けなくても消えない。
private struct AstryxAboutPage: View {
    private var theme: AstryxTheme { AstryxTheme.shared }

    var body: some View {
        AstryxWebView(surface: .about, payload: aboutPayload, onEvent: handleEvent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Astryx About")
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
