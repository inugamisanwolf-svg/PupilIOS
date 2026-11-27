# PupilIOS — 実装コントラクト（全エージェント共通・凍結API）

作業ディレクトリ: `C:\Users\kaito\Documents\PupilIOS`
GitHub: `https://github.com/inugamisanwolf-svg/PupilIOS` (public / Actions有効)
ターゲット: `PupilIOS`（iOS 16.0+, iPhone only, SwiftUI, Swift 5 モード, 追加Swift依存パッケージ禁止）

移植元: `C:\Users\kaito\Documents\Pupil\` （Android/Kotlin, GPLv3）。プロトコル仕様は移植元の
`app/src/main/java/xyz/quaver/pupil/hitomi/*.kt` が正。全エンドポイントは curl で実機検証済み。

**重要**: このマシンに `swiftc` は無い。ローカルでコンパイル確認は不可能。よって
- 凝った言語機能（result builder 自作、property wrapper 自作、advanced generics）は使わない
- SwiftUI は iOS 16 で確実に存在する API のみ（`NavigationStack` は可、`@Observable` は不可 → `ObservableObject`）
- 各ファイルは単体で型が通るように書く。存在しない型・関数を仮定しない（下記の凍結APIのみ前提にしてよい）

## 1. 凍結API（実装済み・変更禁止 / 追加は可）

### Sources/Hitomi — `HitomiClient`（actor, `HitomiClient.shared`）

```swift
// ギャラリー
func galleryInfo(_ galleryID: Int) async throws -> GalleryInfo
func galleryBlock(_ galleryID: Int) async throws -> GalleryBlock      // カード用（サムネURL込み）
func gallery(_ galleryID: Int) async throws -> Gallery                // 詳細用（thumbnail配列/related/languages込み）

// 画像URL（gg.js のサブドメイン解決を内部で行う。URLは遅延解決なので毎回 await する）
func thumbnailURL(_ galleryID: Int, image: GalleryFiles, dir: String = "webpbigtn") async throws -> URL
func pageURL(_ galleryID: Int, image: GalleryFiles) async throws -> URL
func imageData(_ url: URL) async throws -> Data                        // Referer/UA付き取得

// 一覧・検索
func nozomiWindow(_ args: SearchArgs, _ sort: SortMode, offset: Int, count: Int) async throws -> (ids: [Int], total: Int)
func allGalleryIDs(_ sort: SortMode, language: String = "all") async throws -> [Int]
func search(_ text: String, sort: SortMode, context: SearchContext, language: String = "all") async throws -> [Int]
func suggestions(forQuery query: String) async throws -> [Suggestion]
func invalidateCaches()                                               // 引っ張って更新時に呼ぶ
```

`SearchArgs(area:tag:language:)`、ブラウズは `SearchArgs(area: "all", tag: "index", language: 設定言語)`
（`sort` が `.dateAdded`/`.random` 以外なら nozomi 側が人気順ファイルに切り替わる。実装済み）。

### Sources/Hitomi — モデル

`GalleryInfo`（`title`, `japanese_title`, `artists`, `groups`, `parodys`, `tags`, `related`, `languages`,
`characters`, `fileList: [GalleryFiles]`, `pageCount`, `tagNames: [String]`, `displayTitle(japaneseTitles:)`）、
`GalleryBlock`（`id`, `title`, `japaneseTitle`, `artists`, `series`, `groups`, `type`, `language`,
`relatedTags`, `thumbnailURL: URL?`, `pageCount: Int`, `displayTitle(japaneseTitles:)`, `subtitle`）、
`Gallery`（`coverURL`, `thumbnails: [URL]`, `related`, `languages: [(name, galleryID)]`, `tags`, `pageCount`, `displayTitle(...)`）、
`GalleryFiles`（`hash`, `name`, `width`, `height`, `aspectRatio`）、`Suggestion`（`tag`, `count`, `namespace`, `display`）、
`SortMode`（`.dateAdded/.datePublished/.popularToday/.popularWeek/.popularMonth/.popularYear/.random`, `label`）。
`ContentRange` の総数は `nozomiWindow` の `total`。

### Sources/Hitomi — `TagTranslations.shared`

```swift
static var availableLanguages: [String]           // バンドル同梱 tags/*.json（es/id/ko/zh）
func translation(of tag: String, language: String) -> String?
func tagsMatching(_ term: String, language: String, limit: Int = 5) -> [String]
```

### Sources/Store — `Settings.shared` / `Library.shared`（`@MainActor`, `ObservableObject`）

`Settings`: `japaneseTitles: Bool`, `tagTranslation: String`, `perPage: Int`, `theme: String`("system"/"dark"/"light"),
`browseLanguage: String`, `browseSort: String`, `sortMode: SortMode`, `colorScheme: ColorScheme?`, `static languages: [(id,label)]`

`Library`: `favorites: [Int]`, `history: [Int]`, `readLater: [Int]`, `favoriteTags: [String]`, `searchHistory: [String]`,
`isFavorite(_:)`, `toggleFavorite(_:)`, `recordVisit(_:)`, `clearHistory()`, `isInReadLater(_:)`, `toggleReadLater(_:)`,
`toggleFavoriteTag(_:)`, `isFavoriteTag(_:)`, `addSearchHistory(_:)`, `removeSearchHistory(_:)`,
`page(for:) -> Int?`, `setPage(_:for:)`, `searchContext: SearchContext`

### Sources/DesignSystem — Astryx 由来デザインシステム（astryx-design が実装）

```swift
struct AstryxTheme {                      // Astryx の theme CSS custom property を Swift に移植したもの
    static let shared: AstryxTheme
    var background: Color; var surface: Color; var surfaceRaised: Color
    var textPrimary: Color; var textSecondary: Color; var border: Color
    var accent: Color; var onAccent: Color; var danger: Color
    var radiusSmall: CGFloat; var radiusMedium: CGFloat; var radiusLarge: CGFloat
    func space(_ step: AstryxSpace) -> CGFloat
    func font(_ role: AstryxFontRole) -> Font
    var colorScheme: ColorScheme        // 常に dark（Astryx dark トークン）
}
enum AstryxSpace { case xxs, xs, sm, md, lg, xl, xxl }
enum AstryxFontRole { case display, heading1, heading2, heading3, body, label, caption }

// Astryx のプリミティブに対応する SwiftUI 部品
struct AstryxCard<Content: View>: View          // init(padding: AstryxSpace = .md, @ViewBuilder content:)
struct AstryxBadge: View                        // init(_ text: String, tint: Color = AstryxTheme.shared.accent)
struct AstryxChip: View                         // init(_ text: String, selected: Bool, action: () -> Void)
struct AstryxButtonStyle: ButtonStyle           // .buttonStyle(.astryx) で使えるよう static var astryx
struct AstryxSectionHeader: View                // init(_ title: String)
struct AstryxDivider: View
struct AstryxProgressDots: View                 // init(current: Int, total: Int)  ページ送り表示

// 本物の Astryx (React) を WKWebView でオフライン描画する面
enum AstryxSurface: String { case about = "about", settings = "settings" }
struct AstryxWebView: UIViewRepresentable {
    init(surface: AstryxSurface, payload: [String: String], onEvent: @escaping (String, [String: String]) -> Void)
}
```

`AstryxWebView` は `Resources/astryx/pupil-astryx.html` を `loadFileURL(_:allowingReadAccessTo:)` で読み、
`astryx.js` / `astryx.css`（esbuild で事前同梱）を使う。イベントは
`window.webkit.messageHandlers.pupil.postMessage({name, payload})` で Swift へ、Swift からは
`window.pupilUpdate(json文字列)` を `evaluateJavaScript` で叩く。オフラインで動くこと（外部CDN不可）。

### Sources/UI — 画面間シグネチャ（凍結）

```swift
// ui-reader 所有。ui-browse の詳細画面がこの形で呼ぶ。startPage は 0 始まり index。
struct ReaderView: View { init(galleryID: Int, startPage: Int) }

// ui-browse 所有。リーダーは ImageCache を共有する。
final class ImageCache {
    static let shared: ImageCache
    func image(for url: URL) async -> UIImage?
}
```

`GalleryBlock.pageCount` は `galleryBlock(_:)` が `galleryInfo` から詰める（追加リクエストなし）。

### Sources/UI — ビュー分割（所有権つき）

| 担当 | ファイル |
|---|---|
| ui-shell | `Sources/App/PupilIOSApp.swift`, `Sources/UI/Root/RootView.swift`, `Sources/UI/Root/SettingsView.swift` |
| ui-browse | `Sources/UI/Browse/BrowseView.swift`, `Sources/UI/Browse/GalleryListModel.swift`, `Sources/UI/Browse/GalleryCard.swift`, `Sources/UI/Search/SearchView.swift`, `Sources/UI/Detail/GalleryDetailView.swift`, `Sources/UI/Common/RemoteImage.swift`, `Sources/UI/Common/GridColumns.swift`, `Sources/UI/Common/GalleryGrid.swift`（4画面で共有するグリッド+フッター+refresh。Lead 承認済み）, `Sources/UI/Library/FavoritesView.swift`, `Sources/UI/Library/HistoryView.swift` |
| ui-reader | `Sources/UI/Reader/ReaderView.swift`, `Sources/UI/Reader/ZoomablePageView.swift`, `Sources/UI/Reader/ReaderOverlay.swift` |
| astryx-design | `Sources/DesignSystem/**`, `Resources/astryx/**`, `design/**`, `docs/ASTRYX.md` |
| core-api | `Sources/Hitomi/**`, `Sources/Store/**` |
| build-ci | `project.yml`, `.github/**`, `Resources/Info.plist`, `Resources/Assets.xcassets/**`, `scripts/**`, `README.md` |

他の担当のファイルは**編集しない**。必要なら Lead に依頼する。`docs/CONTRACT.md`（このファイル）は Lead のみ編集。

## 1.5 テーマ / リーダー拡張（v1.0.4 で追加・凍結）

```swift
// Sources/DesignSystem/ThemeStore.swift  (astryx-design 所有)
enum ThemeColorKey: String, CaseIterable, Codable {
    case accent, onAccent, background, surface, surfaceRaised, textPrimary, textSecondary, border, danger
    var label: String   // 日本語ラベル
}

enum WallpaperKind: String, Codable { case none, preset, image }

struct Wallpaper: Codable, Equatable {
    var kind: WallpaperKind
    var presetID: String     // "midnight" / "pink" / "purple" / "tiffany" / "paper"
    var fileName: String     // kind == .image のとき Application Support/Wallpaper/ 内のファイル名
}

struct ThemePalette: Codable, Equatable {
    var accent: String            // "#RRGGBB"
    var onAccent: String
    var background: String
    var surface: String
    var surfaceRaised: String
    var textPrimary: String
    var textSecondary: String
    var border: String            // "#RRGGBB"（不透明でよい。内部で alpha 0.10 相当を再現）
    var danger: String
    var wallpaper: Wallpaper
    subscript(_ key: ThemeColorKey) -> String { get set }
}

enum ThemePreset: String, CaseIterable, Codable {
    case astryx, midnight, pink, purple, tiffany
    var label: String                       // "Astryx" / "ミッドナイト" / "ピンク" / "ムラサキ" / "Tiffany Blue"
    var palette: ThemePalette { get }
}

@MainActor を付けない理由: `AstryxTheme.shared` は computed で `ThemeStore.shared.palette` を読み、既存コードには
`AstryxTheme.shared.accent` を非隔離文脈から触る箇所（既定引数・`private var theme`）があるため。
変更系メソッドは MainActor から呼ばれる前提でよい。

final class ThemeStore: ObservableObject {
    static let shared: ThemeStore
    @Published private(set) var palette: ThemePalette
    @Published private(set) var revision: Int            // 変更のたび +1（画面再構築のトリガ）
    @Published private(set) var activePreset: ThemePreset?
    func apply(_ preset: ThemePreset)
    func setHex(_ hex: String, for key: ThemeColorKey)   // プリセットから外れる（activePreset = nil）
    func resetToPreset()
    func setWallpaper(_ wallpaper: Wallpaper)
    func importWallpaper(data: Data) -> Bool             // 画像を取り込み Wallpaper.image に設定
    func wallpaperImage() -> UIImage?                    // kind == .image のとき読み込み
}

// 壁紙レイヤ（Root の最背面に敷く）
struct WallpaperView: View { init(palette: ThemePalette) }

// テーマ編集画面（設定から NavigationLink で開く）
struct ThemeEditorView: View { init() }
```

`AstryxTheme.shared` は **`static var`（computed）** に変更し、`ThemeStore.shared.palette` から都度構築する。
**呼び出し側（`AstryxTheme.shared.accent` など既存の書き方）は変更不要**。
テーマ変更を全画面へ反映するのは Root 側の責務: `RootView` が `.id(ThemeStore.shared.revision)` を TabView に付けて再構築する。

### リーダー拡張（ui-reader 所有）

```swift
enum ReaderMode: String, CaseIterable, Codable { case paged, vertical }   // paged=現行 / vertical=縦スクロール（webtoon）
enum ReaderFit: String, CaseIterable, Codable {
    case fitScreen   // 画面に合わせる（aspect fit）
    case fitWidth    // 横幅に合わせる
    case fitHeight   // 高さに合わせる
    case original    // 原寸（100%）
    var label: String
}
// Settings に追加（既存の didSet 永続化パターンに従う）
//   var readerMode: String   // ReaderMode.rawValue
//   var readerFit: String    // ReaderFit.rawValue
```



1. **Root**: `TabView` 5タブ = ブラウズ / 検索 / お気に入り / 履歴 / 設定。各タブ `NavigationStack`。
   環境オブジェクト `Settings.shared` / `Library.shared` を注入（App 側で `.environmentObject`）。
2. **ブラウズ**: `SortMode` メニュー + 言語メニュー。3列グリッド、無限スクロール（末尾6件で追加ロード）、
   下引っ張り更新（`invalidateCaches()` → 先頭から）、失敗時インラインエラー + 再試行。
3. **検索**: 検索バー（送信で確定、履歴チップ）、入力中サジェスト（`suggestions(forQuery:)` +
   `TagTranslations.tagsMatching`）、結果グリッド、`-`除外と `namespace:tag` をそのまま受け付ける。
4. **詳細**: 表紙・タイトル（`japaneseTitles` 反映）・artist/group/parody/tag チップ・言語切替（`languages`）・
   関連（`related` 先頭20）・「読む（p.3 から再開）」・お気に入り/後で読む/共有。
5. **リーダー**: 全画面。水平ページ送り（`TabView` + `.page`）、ピンチ/ダブルタップズーム（`UIScrollView`）、
   タップでクローム表示切替、ページスライダー + `n / total`、読了位置の保存と復帰、プリフェッチ（前後2ページ）。
6. **お気に入り / 履歴**: ID一覧をグリッド表示（`GalleryBlock` を並列取得）。空状態メッセージ。
7. **設定**: 日本語タイトル / タグ翻訳言語 / 1ページ件数 / テーマ / ブラウズ既定。**Astryx の設定面**
   （`AstryxWebView(surface: .settings)`）と About（GPLv3 表記 + 移植元リンク）を必ず含む。

UI 文言は日本語。画像は必ず `RemoteImage`（Referer 付き）経由。`AsyncImage` は使わない（403になる）。

## 3. ビルド

- 署名なし IPA を GitHub Actions（macos-15 + XcodeGen）で生成。`.github/workflows/ios-build.yml` 実装済み。
- ビルド実行は build-ci のみが行う。他エージェントは push しない（Lead も含め、push は build-ci の役割）。
- コンパイルエラーは build-ci がログから抽出し、該当ファイルの担当へ `send_message` で返す。
