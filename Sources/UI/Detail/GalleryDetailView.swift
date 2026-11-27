import SwiftUI

/// ギャラリー詳細。表紙 + タイトル + クレジット/タグチップ + 言語切替 + サムネイル +
/// 関連。`ReaderView` を fullScreenCover で開き、`Library.page(for:)` から再開する。
struct GalleryDetailView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: Library

    let galleryID: Int

    @State private var gallery: Gallery?
    @State private var related: [GalleryBlock] = []
    @State private var loading: Bool = false
    @State private var errorMessage: String?
    @State private var showReader: Bool = false
    @State private var readerPage: Int = 0

    private static let knownNamespaces: Set<String> = [
        "female", "male", "artist", "group", "character", "series", "type", "language", "tag",
    ]

    init(galleryID: Int) {
        self.galleryID = galleryID
    }

    private var theme: AstryxTheme { AstryxTheme.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.md)) {
                if let gallery = gallery {
                    AstryxCard {
                        header(gallery)
                    }
                    actionBar(gallery)
                    AstryxDivider()
                    languageSection(gallery)
                    creditSection(gallery)
                    tagSection(gallery)
                    thumbnailSection(gallery)
                    relatedSection
                } else if let message = errorMessage {
                    errorState(message)
                } else {
                    HStack(spacing: theme.space(.sm)) {
                        ProgressView()
                        Text("読み込み中…")
                            .font(theme.font(.caption))
                            .foregroundColor(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(theme.space(.xl))
                }
            }
            .padding(theme.space(.md))
        }
        .background(theme.background)
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .onAppear {
            library.recordVisit(galleryID)
        }
        .fullScreenCover(isPresented: $showReader) {
            ReaderView(galleryID: galleryID, startPage: readerPage)
        }
    }

    private var titleText: String {
        if let gallery = gallery {
            return gallery.displayTitle(japaneseTitles: settings.japaneseTitles)
        }
        return "詳細"
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ gallery: Gallery) -> some View {
        HStack(alignment: .top, spacing: theme.space(.md)) {
            Color.clear
                .aspectRatio(coverRatio(gallery), contentMode: .fit)
                .frame(width: 128)
                .overlay(
                    RemoteImage(url: gallery.coverURL, contentMode: .fill)
                )
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: theme.space(.xs)) {
                Text(gallery.displayTitle(japaneseTitles: settings.japaneseTitles))
                    .font(theme.font(.heading2))
                    .foregroundColor(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.japaneseTitles,
                   let japanese = gallery.japaneseTitle,
                   !japanese.isEmpty,
                   japanese != gallery.title {
                    Text(gallery.title)
                        .font(theme.font(.caption))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !creditLine(gallery).isEmpty {
                    Text(creditLine(gallery))
                        .font(theme.font(.caption))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: theme.space(.xs)) {
                    if !gallery.type.isEmpty {
                        AstryxBadge(gallery.type.uppercased())
                    }
                    if !gallery.language.isEmpty {
                        AstryxBadge(gallery.language, tint: theme.surfaceRaised)
                    }
                    AstryxBadge("\(gallery.pageCount)p", tint: theme.surfaceRaised)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func coverRatio(_ gallery: Gallery) -> CGFloat {
        let ratio = gallery.coverAspectRatio
        if ratio <= 0.1 || ratio >= 3 { return 0.72 }
        return ratio
    }

    private func creditLine(_ gallery: Gallery) -> String {
        var parts: [String] = []
        if !gallery.artists.isEmpty { parts.append(gallery.artists.joined(separator: ", ")) }
        if !gallery.groups.isEmpty { parts.append(gallery.groups.joined(separator: ", ")) }
        return parts.joined(separator: " / ")
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionBar(_ gallery: Gallery) -> some View {
        VStack(alignment: .leading, spacing: theme.space(.sm)) {
            Button {
                readerPage = library.page(for: galleryID) ?? 0
                if readerPage < 0 || readerPage >= gallery.pageCount { readerPage = 0 }
                showReader = true
            } label: {
                Label(readLabel(gallery), systemImage: "book")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.astryx)
            .disabled(gallery.pageCount == 0)

            HStack(spacing: theme.space(.sm)) {
                Button {
                    library.toggleFavorite(galleryID)
                } label: {
                    Label(
                        library.isFavorite(galleryID) ? "お気に入り済み" : "お気に入り",
                        systemImage: library.isFavorite(galleryID) ? "heart.fill" : "heart"
                    )
                }
                .buttonStyle(.astryx)

                Button {
                    library.toggleReadLater(galleryID)
                } label: {
                    Label(
                        library.isInReadLater(galleryID) ? "後で読む済み" : "後で読む",
                        systemImage: library.isInReadLater(galleryID) ? "bookmark.fill" : "bookmark"
                    )
                }
                .buttonStyle(.astryx)

                ShareLink(item: shareURL) {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func readLabel(_ gallery: Gallery) -> String {
        if let page = library.page(for: galleryID), page > 0, page < gallery.pageCount {
            return "読む（p.\(page + 1) から再開）"
        }
        return "読む"
    }

    private var shareURL: URL {
        if let url = URL(string: "https://hitomi.la/galleries/\(galleryID).html") {
            return url
        }
        return URL(fileURLWithPath: "/")
    }

    // MARK: - 言語

    @ViewBuilder
    private func languageSection(_ gallery: Gallery) -> some View {
        if gallery.languages.count > 1 {
            VStack(alignment: .leading, spacing: theme.space(.sm)) {
                AstryxSectionHeader("言語")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: theme.space(.xs)) {
                        ForEach(Array(gallery.languages.enumerated()), id: \.offset) { pair in
                            languageChip(pair.element)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func languageChip(_ entry: (name: String, galleryID: String)) -> some View {
        if let id = Int(entry.galleryID) {
            if id == galleryID {
                AstryxChip(entry.name, selected: true) { }
            } else {
                NavigationLink {
                    GalleryDetailView(galleryID: id)
                } label: {
                    // `AstryxChip` は中で Button なので、そのまま入れるとタップを
                    // チップ側が食ってリンクが発火しないことがある。
                    AstryxChip(entry.name, selected: false) { }
                        .allowsHitTesting(false)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - クレジット

    @ViewBuilder
    private func creditSection(_ gallery: Gallery) -> some View {
        VStack(alignment: .leading, spacing: theme.space(.sm)) {
            chipRow(title: "アーティスト", names: gallery.artists, namespace: "artist")
            chipRow(title: "グループ", names: gallery.groups, namespace: "group")
            chipRow(title: "シリーズ", names: gallery.series, namespace: "series")
            chipRow(title: "キャラクター", names: gallery.characters, namespace: "character")
        }
    }

    @ViewBuilder
    private func chipRow(title: String, names: [String], namespace: String) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: theme.space(.xs)) {
                Text(title)
                    .font(theme.font(.caption))
                    .foregroundColor(theme.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: theme.space(.xs)) {
                        ForEach(names, id: \.self) { name in
                            chipLink(name, query: tagQuery(namespace: namespace, name: name))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - タグ

    @ViewBuilder
    private func tagSection(_ gallery: Gallery) -> some View {
        if !gallery.tags.isEmpty {
            VStack(alignment: .leading, spacing: theme.space(.sm)) {
                AstryxSectionHeader("タグ")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: theme.space(.xs)) {
                        ForEach(gallery.tags, id: \.self) { raw in
                            chipLink(tagLabel(raw), query: queryForTag(raw))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func queryForTag(_ raw: String) -> String {
        let split = splitTag(raw)
        return tagQuery(namespace: split.namespace, name: split.name)
    }

    private func splitTag(_ tag: String) -> (namespace: String?, name: String) {
        guard let index = tag.firstIndex(of: ":") else { return (nil, tag) }
        let candidate = String(tag[tag.startIndex..<index]).lowercased()
        guard GalleryDetailView.knownNamespaces.contains(candidate) else { return (nil, tag) }
        let name = String(tag[tag.index(after: index)...])
        return (candidate, name)
    }

    /// タグ翻訳（`Settings.tagTranslation`）があれば表示名に使う。
    private func tagLabel(_ raw: String) -> String {
        let language = settings.tagTranslation
        if language.isEmpty { return raw }

        let split = splitTag(raw)
        if let translated = TagTranslations.shared.translation(of: split.name, language: language) {
            if let namespace = split.namespace {
                return "\(namespace):\(translated)"
            }
            return translated
        }
        return raw
    }

    private func tagQuery(namespace: String?, name: String) -> String {
        let normalized = name.replacingOccurrences(of: " ", with: "_").lowercased()
        if let namespace = namespace, !namespace.isEmpty {
            return "\(namespace):\(normalized)"
        }
        return normalized
    }

    private func chipLink(_ label: String, query: String) -> some View {
        NavigationLink {
            SearchView(initialQuery: query, embedsStack: false)
        } label: {
            // 同上: チップ内部の Button がタップを吸わないようにする。
            AstryxChip(label, selected: false) { }
                .allowsHitTesting(false)
        }
        .buttonStyle(.plain)
    }

    // MARK: - サムネイル

    @ViewBuilder
    private func thumbnailSection(_ gallery: Gallery) -> some View {
        if !gallery.thumbnails.isEmpty {
            VStack(alignment: .leading, spacing: theme.space(.sm)) {
                AstryxSectionHeader("ページ（タップで開く）")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: theme.space(.xs)) {
                        ForEach(Array(gallery.thumbnails.prefix(30).enumerated()), id: \.offset) { pair in
                            Button {
                                // サムネは `try?` で落ちた分だけ詰めて並ぶので、
                                // 添字がそのままページ番号とは限らない。せめて
                                // pageCount の外へは出さない（Reader の初期位置）。
                                guard gallery.pageCount > 0 else { return }
                                readerPage = min(max(pair.offset, 0), gallery.pageCount - 1)
                                showReader = true
                            } label: {
                                Color.clear
                                    .frame(width: 56, height: 78)
                                    .overlay(
                                        RemoteImage(url: pair.element, contentMode: .fill)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                                            .stroke(theme.border, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 関連

    @ViewBuilder
    private var relatedSection: some View {
        if !related.isEmpty {
            VStack(alignment: .leading, spacing: theme.space(.sm)) {
                AstryxSectionHeader("関連")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: theme.space(.sm)) {
                        ForEach(related) { block in
                            NavigationLink(value: block.id) {
                                GalleryCard(block: block)
                                    .frame(width: 116)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 状態

    @ViewBuilder
    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space(.sm)) {
            Text(message)
                .font(theme.font(.body))
                .foregroundColor(theme.danger)
                .fixedSize(horizontal: false, vertical: true)

            Button("再試行") {
                Task { await load() }
            }
            .buttonStyle(.astryx)
        }
        .padding(theme.space(.lg))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
    }

    // MARK: - 読み込み

    private func load() async {
        if loading { return }
        if gallery != nil && errorMessage == nil { return }

        loading = true
        errorMessage = nil

        do {
            let fetched = try await HitomiClient.shared.gallery(galleryID)
            gallery = fetched
            errorMessage = nil

            // `related` に同じ ID が二度入ることがある。`relatedSection` は
            // `ForEach(related)`（id は `GalleryBlock.id`）なので、重複したまま
            // 積むと SwiftUI の id 重複になる。先に一意化してから先頭 20 件。
            let ids = Array(GalleryListModel.uniqueIDs(fetched.related).prefix(20))
            var blocks = await GalleryListModel.fetchBlocks(ids: ids)
            if Task.isCancelled {
                loading = false
                return
            }
            blocks.removeAll { $0.id == galleryID }
            related = blocks
        } catch {
            if Task.isCancelled || GalleryListModel.isCancellation(error) {
                // 画面を離れて `.task` がキャンセルされただけ。エラー面を出すと
                // 戻ってきたときに「読み込み失敗」のまま残る。
                loading = false
                return
            }
            errorMessage = GalleryListModel.describe(error)
        }

        loading = false
    }
}
