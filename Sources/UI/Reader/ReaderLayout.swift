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
}
