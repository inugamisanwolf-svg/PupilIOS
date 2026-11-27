import SwiftUI

/// 検索。送信で確定（`Library.addSearchHistory`）、入力中は 250ms デバウンスで
/// サジェスト（`HitomiClient.suggestions` + `TagTranslations.tagsMatching`）を出す。
/// `-` の除外と `namespace:tag` はそのまま hitomi に渡す。
struct SearchView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: Library
    @StateObject private var model = GalleryListModel()

    private let initialQuery: String?
    /// タブのルートなら自前で `NavigationStack` を持つ。詳細画面からタグで
    /// 押し込まれる場合は false（親スタックの二重ナビゲーションバー回避）。
    private let embedsStack: Bool

    @State private var text: String = ""
    @State private var submitted: String = ""
    @State private var suggestions: [Suggestion] = []
    @State private var localSuggestions: [String] = []
    @State private var didSeed: Bool = false

    init(initialQuery: String? = nil, embedsStack: Bool = true) {
        self.initialQuery = initialQuery
        self.embedsStack = embedsStack
    }

    private var theme: AstryxTheme { AstryxTheme.shared }

    var body: some View {
        if embedsStack {
            NavigationStack {
                content
                    .navigationTitle("検索")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: Int.self) { id in
                        GalleryDetailView(galleryID: id)
                    }
            }
            .task { await seed() }
            .task(id: text) { await refreshSuggestions() }
        } else {
            content
                .navigationTitle("検索")
                .navigationBarTitleDisplayMode(.inline)
                .task { await seed() }
                .task(id: text) { await refreshSuggestions() }
        }
    }

    // MARK: - 本体

    private var content: some View {
        VStack(spacing: 0) {
            searchField

            if !text.isEmpty && (!suggestions.isEmpty || !localSuggestions.isEmpty) {
                suggestionList
            }

            if submitted.isEmpty {
                headerSection
                Spacer(minLength: 0)
            } else {
                GalleryGrid(model: model, emptyMessage: "「\(submitted)」に一致するギャラリーはありません")
            }
        }
        .background(theme.background)
    }

    private var searchField: some View {
        HStack(spacing: theme.space(.xs)) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(theme.textSecondary)

            TextField("タグ・言葉で検索（例: female:big_breasts -netorare）", text: $text)
                .font(theme.font(.body))
                .foregroundColor(theme.textPrimary)
                .submitLabel(.search)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .onSubmit {
                    Task { await submit(text) }
                }

            if !text.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(theme.space(.sm))
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        .padding(theme.space(.sm))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    Task { await submit(suggestionText(suggestion)) }
                } label: {
                    HStack(spacing: theme.space(.sm)) {
                        Text(suggestion.display)
                            .font(theme.font(.body))
                            .foregroundColor(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(suggestion.count)")
                            .font(theme.font(.caption))
                            .foregroundColor(theme.textSecondary)
                    }
                    .padding(.horizontal, theme.space(.sm))
                    .padding(.vertical, theme.space(.xs))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(localSuggestions, id: \.self) { tag in
                Button {
                    Task { await submit(tag) }
                } label: {
                    HStack(spacing: theme.space(.sm)) {
                        Text(tag)
                            .font(theme.font(.body))
                            .foregroundColor(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("翻訳一致")
                            .font(theme.font(.caption))
                            .foregroundColor(theme.textSecondary)
                    }
                    .padding(.horizontal, theme.space(.sm))
                    .padding(.vertical, theme.space(.xs))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, theme.space(.xs))
        .background(theme.surfaceRaised)
    }

    @ViewBuilder
    private var headerSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.md)) {
                if library.searchHistory.isEmpty {
                    Text("タグ名や言葉を入力して検索します。\n`-` で除外、`namespace:tag` で名前空間を指定できます。")
                        .font(theme.font(.caption))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(theme.space(.sm))
                } else {
                    AstryxSectionHeader("検索履歴")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: theme.space(.xs)) {
                            ForEach(library.searchHistory, id: \.self) { entry in
                                AstryxChip(entry, selected: false) {
                                    Task { await submit(entry) }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        library.removeSearchHistory(entry)
                                    } label: {
                                        Label("履歴から削除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, theme.space(.sm))
                    }
                }
            }
            .padding(.top, theme.space(.sm))
        }
    }

    // MARK: - 挙動

    private func seed() async {
        guard !didSeed else { return }
        didSeed = true
        if let initial = initialQuery, !initial.isEmpty {
            await submit(initial)
        }
    }

    private func clearSearch() {
        text = ""
        submitted = ""
        suggestions = []
        localSuggestions = []
        model.configure(source: .ids([]), perPage: max(settings.perPage, 1))
    }

    private func submit(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        text = trimmed
        submitted = trimmed
        suggestions = []
        localSuggestions = []
        library.addSearchHistory(trimmed)

        await model.configureAndStart(
            source: .search(text: trimmed, sort: settings.sortMode),
            perPage: settings.perPage
        )
    }

    private func suggestionText(_ suggestion: Suggestion) -> String {
        let body = suggestion.display
        if text.hasPrefix("-") {
            return "-" + body
        }
        return body
    }

    /// 入力中のサジェスト。250ms 待ってから hitomi の suggestion index を叩く
    /// （`.task(id: text)` なので入力が続けば前のタスクはキャンセルされる）。
    private func refreshSuggestions() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            suggestions = []
            localSuggestions = []
            return
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }

        let body = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed

        var remote: [Suggestion] = []
        if !body.isEmpty {
            remote = (try? await HitomiClient.shared.suggestions(forQuery: body)) ?? []
        }
        if Task.isCancelled { return }
        suggestions = Array(remote.prefix(8))

        var local: [String] = []
        let language = settings.tagTranslation
        if !language.isEmpty && !body.isEmpty && !body.contains(":") {
            local = TagTranslations.shared.tagsMatching(body, language: language, limit: 5)
        }
        localSuggestions = local
    }
}
