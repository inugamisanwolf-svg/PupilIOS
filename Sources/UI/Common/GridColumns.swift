import SwiftUI

/// 一覧グリッドの列定義。Pupil の一覧と同じ 3 列固定。
enum GridColumns {
    static let count: Int = 3

    static var standard: [GridItem] {
        columns(spacing: 8)
    }

    static func columns(spacing: CGFloat = 8) -> [GridItem] {
        var items: [GridItem] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            items.append(GridItem(.flexible(), spacing: spacing, alignment: .top))
        }
        return items
    }

    /// 3 列に割ったときの 1 枚あたりの幅（カードの高さ計算用）。
    static func tileWidth(containerWidth: CGFloat, spacing: CGFloat = 8) -> CGFloat {
        let gaps = spacing * CGFloat(count - 1)
        let usable = containerWidth - gaps
        if usable <= 1 { return 1 }
        return usable / CGFloat(count)
    }
}
