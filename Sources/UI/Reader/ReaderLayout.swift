import SwiftUI

/// リーダーの表示モード。
///
/// `paged` は 1 ページずつ水平に送る現行の表示、`vertical` は縦に連続して並べる
/// （webtoon）表示。
enum ReaderMode: String, CaseIterable, Codable, Hashable {
    case paged
    case vertical

    var label: String {
        switch self {
        case .paged: return "ページ送り"
        case .vertical: return "縦スクロール"
        }
    }

    var symbolName: String {
        switch self {
        case .paged: return "rectangle.portrait.on.rectangle.portrait"
        case .vertical: return "rectangle.split.1x2"
        }
    }
}

/// ページの大きさ。
///
/// ページ送りでは「最初に見せる倍率」、縦スクロールでは「1 ページに与える枠」に
/// なる。どちらも下限は画面に合わせた大きさ（＝ピンチで戻れる地点）で、そこから
/// 拡大する方向にだけ効かせる。
enum ReaderFit: String, CaseIterable, Codable, Hashable {
    case fitScreen
    case fitWidth
    case fitHeight
    case original

    var label: String {
        switch self {
        case .fitScreen: return "画面に合わせる"
        case .fitWidth: return "横幅に合わせる"
        case .fitHeight: return "高さに合わせる"
        case .original: return "原寸"
        }
    }

    var symbolName: String {
        switch self {
        case .fitScreen: return "arrow.down.right.and.arrow.up.left"
        case .fitWidth: return "arrow.left.and.right"
        case .fitHeight: return "arrow.up.and.down"
        case .original: return "1.magnifyingglass"
        }
    }

    /// ダブルタップで送る次の大きさ。
    var next: ReaderFit {
        switch self {
        case .fitScreen: return .fitWidth
        case .fitWidth: return .fitHeight
        case .fitHeight: return .original
        case .original: return .fitScreen
        }
    }

    /// 縦スクロールで 1 ページに与える大きさ（ポイント）。
    ///
    /// 画像の実寸は `GalleryFiles.width/height` から来るので、画像を読み込む前
    /// に枠が決まる。`LazyVStack` が行の高さを先に知れるので、スクロール中に
    /// 高さが飛ばない。
    func pageSize(for image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else {
            return CGSize(width: max(box.width, 1), height: max(box.width, 1))
        }

        switch self {
        case .fitScreen:
            let scale = min(box.width / image.width, box.height / image.height)
            return CGSize(width: max(image.width * scale, 1), height: max(image.height * scale, 1))
        case .fitWidth:
            let scale = box.width / image.width
            return CGSize(width: box.width, height: max(image.height * scale, 1))
        case .fitHeight:
            let scale = box.height / image.height
            return CGSize(width: max(image.width * scale, 1), height: box.height)
        case .original:
            return CGSize(width: image.width, height: image.height)
        }
    }

    /// ページ送りで、この大きさにするための初期ズーム倍率。
    ///
    /// 1.0 が「画面に合わせた状態」（`minimumZoomScale`）。fitWidth / fitHeight /
    /// original はそこから拡大した倍率を返すので、ピンチで 1.0 まで戻せば
    /// ページ送りのスワイプが効く状態に必ず戻れる。
    func initialZoomScale(for image: CGSize, in box: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return 1 }

        let fitScale = min(box.width / image.width, box.height / image.height)
        guard fitScale > 0 else { return 1 }

        switch self {
        case .fitScreen:
            return 1
        case .fitWidth:
            return max(1, (box.width / image.width) / fitScale)
        case .fitHeight:
            return max(1, (box.height / image.height) / fitScale)
        case .original:
            // 1 ピクセル = 1 ポイント。
            return max(1, 1 / fitScale)
        }
    }
}

extension Settings {
    /// 保存されている生の文字列を型に戻す。未知の値は既定へ落とす
    /// （`Picker` の選択肢が変わっても読めなくならないように）。
    var readerModeValue: ReaderMode {
        ReaderMode(rawValue: readerMode) ?? .paged
    }

    var readerFitValue: ReaderFit {
        ReaderFit(rawValue: readerFit) ?? .fitScreen
    }

    var readerSpreadValue: ReaderSpread {
        ReaderSpread(rawValue: readerSpread) ?? .single
    }

    var readerDirectionValue: ReaderDirection {
        ReaderDirection(rawValue: readerDirection) ?? .rtl
    }
}

// MARK: - 見開き / 開き方向

/// 1 画面に 1 ページ出すか、2 ページ並べるか。
enum ReaderSpread: String, CaseIterable, Codable, Hashable {
    case single
    case double

    var label: String {
        switch self {
        case .single: return "単独表示"
        case .double: return "見開き表示"
        }
    }

    var symbolName: String {
        switch self {
        case .single: return "rectangle"
        case .double: return "rectangle.split.2x1"
        }
    }
}

/// ページを送る向き。`rtl` が漫画の右開き。
enum ReaderDirection: String, CaseIterable, Codable, Hashable {
    case ltr
    case rtl

    var label: String {
        switch self {
        case .ltr: return "左開き（左から右）"
        case .rtl: return "右開き（右から左）"
        }
    }

    var symbolName: String {
        switch self {
        case .ltr: return "chevron.forward.2"
        case .rtl: return "chevron.backward.2"
        }
    }
}

/// ページ index と「表示スロット」の対応を 1 箇所に閉じ込める。
///
/// スロットは `TabView` の 1 ページ分で、1〜2 ページを持つ。
/// - **読み順スロット**: 0,1,2… とページの進む順。
/// - **表示スロット**: `TabView` が並べる順。`rtl` では読み順を反転させる
///   （右開きなので、次のページは右方向のスワイプで出てくる）。
///
/// `Library.setPage` に渡すのは常に **ページ index（0 始まり）**。スロット番号は
/// 保存しないので、見開きの設定を変えても読了位置は動かない。
struct ReaderSpreadLayout {
    let pageCount: Int
    let spread: ReaderSpread
    let coverSingle: Bool
    let direction: ReaderDirection

    /// 配列は組まない。`TabView(selection:)` の Binding から毎回参照されるので、
    /// ここは O(1) の算術だけにしてある（2000 ページの作品で
    /// スワイプのたびに `[[Int]]` を作ると重い）。
    init(pageCount: Int, spread: ReaderSpread, coverSingle: Bool, direction: ReaderDirection) {
        self.pageCount = max(pageCount, 0)
        self.spread = spread
        self.coverSingle = coverSingle
        self.direction = direction
    }

    /// 見開きが実際に効いているか（1 ページの作品は常に単独）。
    var isDouble: Bool { spread == .double && pageCount > 1 }

    var slotCount: Int {
        guard pageCount > 0 else { return 0 }
        guard isDouble else { return pageCount }

        // 表紙単独: [0], (1,2), (3,4)… / 表紙も対: (0,1), (2,3)…
        return coverSingle ? 1 + pageCount / 2 : (pageCount + 1) / 2
    }

    /// 読み順スロットの先頭ページ。読了位置として保存する値。
    func pageForSlot(_ slot: Int) -> Int {
        guard pageCount > 0, slotCount > 0 else { return 0 }

        let s = min(max(slot, 0), slotCount - 1)
        guard isDouble else { return s }

        if coverSingle {
            return s == 0 ? 0 : 2 * s - 1
        }
        return 2 * s
    }

    /// ページを含む読み順スロット。
    func slotForPage(_ page: Int) -> Int {
        guard pageCount > 0, slotCount > 0 else { return 0 }

        let p = min(max(page, 0), pageCount - 1)
        guard isDouble else { return p }

        if coverSingle {
            return p == 0 ? 0 : (p + 1) / 2
        }
        return p / 2
    }

    /// 読み順スロットに入っているページ（1〜2 個）。
    func pages(forReadingSlot slot: Int) -> [Int] {
        guard pageCount > 0, slot >= 0, slot < slotCount else { return [] }

        let first = pageForSlot(slot)
        guard isDouble else { return [first] }

        // 表紙だけ単独のスロット。
        if coverSingle, slot == 0 { return [0] }

        if first + 1 < pageCount { return [first, first + 1] }
        return [first]
    }

    /// 全スロット（デバッグ・検証用。ホットパスからは呼ばない）。
    var slots: [[Int]] {
        (0..<slotCount).map { pages(forReadingSlot: $0) }
    }

    /// 表示スロット（`TabView` の並び）→ 読み順スロット。
    func readingSlot(forVisualSlot visual: Int) -> Int {
        guard slotCount > 0 else { return 0 }

        let clamped = min(max(visual, 0), slotCount - 1)
        return direction == .rtl ? slotCount - 1 - clamped : clamped
    }

    /// 読み順スロット → 表示スロット。
    func visualSlot(forReadingSlot slot: Int) -> Int {
        guard slotCount > 0 else { return 0 }

        let clamped = min(max(slot, 0), slotCount - 1)
        return direction == .rtl ? slotCount - 1 - clamped : clamped
    }

    /// 見開きの中の並び（左→右）。`rtl` では右が先のページになる。
    func visualPages(forReadingSlot slot: Int) -> [Int] {
        let pages = pages(forReadingSlot: slot)

        guard direction == .rtl, pages.count > 1 else { return pages }
        return Array(pages.reversed())
    }
}
