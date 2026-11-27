import SwiftUI

/// The reader's chrome: a bar at the top and one at the bottom, over material so
/// the page shows through. The reader opens with it up and moves it on a tap.
///
/// The bottom bar's slider is the page number as a control: dragging it reports
/// the page under the thumb straight away, so the page under the chrome follows
/// the drag rather than jumping when the thumb is let go. The thumb's own number
/// is held locally while dragging so the slider never fights the page that is
/// arriving underneath it.
struct ReaderOverlay: View {
    let title: String
    /// 1 始まりの表示番号。
    let currentPage: Int
    let pageCount: Int
    let isFavorite: Bool
    let isInReadLater: Bool
    let mode: ReaderMode
    let fit: ReaderFit
    let spread: ReaderSpread
    let direction: ReaderDirection
    let onClose: () -> Void
    /// 1 始まりのページ番号。
    let onSelectPage: (Int) -> Void
    let onToggleFavorite: () -> Void
    let onToggleReadLater: () -> Void
    let onSelectMode: (ReaderMode) -> Void
    let onSelectFit: (ReaderFit) -> Void
    let onSelectSpread: (ReaderSpread) -> Void
    let onSelectDirection: (ReaderDirection) -> Void

    @State private var draggingPage: Double?

    private var theme: AstryxTheme { AstryxTheme.shared }

    private var shownPage: Int {
        if let draggingPage = draggingPage {
            return Int(draggingPage.rounded())
        }
        return currentPage
    }

    private var total: Int { max(pageCount, 1) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: theme.space(.sm)) {
            barButton(systemImage: "xmark", label: "閉じる", action: onClose)

            Text(title)
                .font(theme.font(.heading3))
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            spreadMenu
            directionMenu

            barButton(
                systemImage: isFavorite ? "star.fill" : "star",
                label: "お気に入り",
                tint: isFavorite ? theme.accent : theme.textPrimary,
                action: onToggleFavorite
            )
        }
        .padding(.horizontal, theme.space(.sm))
        .padding(.vertical, theme.space(.xxs))
        .background(barBackground)
        .overlay(Rectangle().fill(theme.border).frame(height: 0.5), alignment: .bottom)
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        VStack(spacing: theme.space(.xs)) {
            HStack(spacing: theme.space(.sm)) {
                Text("\(shownPage) / \(total)")
                    .font(theme.font(.label))
                    .foregroundColor(theme.textSecondary)
                    .monospacedDigit()
                    .frame(minWidth: 72, alignment: .leading)

                Spacer(minLength: 0)

                modeMenu
                fitMenu

                barButton(
                    systemImage: isInReadLater ? "bookmark.fill" : "bookmark",
                    label: "後で読む",
                    tint: isInReadLater ? theme.accent : theme.textPrimary,
                    action: onToggleReadLater
                )
            }

            if pageCount > 1 {
                Slider(
                    value: pageBinding,
                    in: 1...Double(pageCount),
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing { draggingPage = nil }
                    }
                )
                .tint(theme.accent)
                .accessibilityLabel("ページ")
            }

            // dots は総ページ数が多いと潰れるので、少ないときだけ出す。
            // ページ番号そのものは上の `n / total` が常に持っている。
            // `AstryxProgressDots.current` は 0 始まりの index（内部で
            // `min(max(current, 0), total - 1)` にして 0..<total と比較する）。
            // `shownPage` は 1 始まりのページ番号なので、そのまま渡すと
            // 常に1つ右のドットが点灯する。
            if pageCount <= 30 {
                AstryxProgressDots(current: shownPage - 1, total: total)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, theme.space(.md))
        .padding(.top, theme.space(.xxs))
        .padding(.bottom, theme.space(.xs))
        .background(barBackground)
        .overlay(Rectangle().fill(theme.border).frame(height: 0.5), alignment: .top)
    }

    private var barBackground: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea()
    }

    // MARK: - 表示モード / 大きさ

    private var modeMenu: some View {
        Menu {
            Picker("表示モード", selection: Binding(
                get: { mode },
                set: { onSelectMode($0) }
            )) {
                ForEach(ReaderMode.allCases, id: \.self) { item in
                    Text(item.label).tag(item)
                }
            }
        } label: {
            menuLabel(mode.symbolName)
        }
        .foregroundColor(theme.textPrimary)
        .accessibilityLabel("表示モード")
    }

    private var fitMenu: some View {
        Menu {
            Picker("ページの大きさ", selection: Binding(
                get: { fit },
                set: { onSelectFit($0) }
            )) {
                ForEach(ReaderFit.allCases, id: \.self) { item in
                    Text(item.label).tag(item)
                }
            }
        } label: {
            menuLabel(fit.symbolName)
        }
        .foregroundColor(theme.textPrimary)
        .accessibilityLabel("ページの大きさ")
    }

    private func menuLabel(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    // MARK: - 見開き / 開き方向

    /// 縦スクロールは 1 列なので、見開きと開き方向は効かない。
    /// 触れないことが分かるように無効表示にする。
    private var spreadMenusDisabled: Bool { mode == .vertical }

    private var spreadMenu: some View {
        Menu {
            Picker("見開き", selection: Binding(
                get: { spread },
                set: { onSelectSpread($0) }
            )) {
                ForEach(ReaderSpread.allCases, id: \.self) { item in
                    Text(item.label).tag(item)
                }
            }
        } label: {
            menuLabel(spread.symbolName)
        }
        .foregroundColor(spreadMenusDisabled ? theme.textSecondary : theme.textPrimary)
        .disabled(spreadMenusDisabled)
        .opacity(spreadMenusDisabled ? 0.35 : 1)
        .accessibilityLabel("見開き")
    }

    private var directionMenu: some View {
        Menu {
            Picker("開き方向", selection: Binding(
                get: { direction },
                set: { onSelectDirection($0) }
            )) {
                ForEach(ReaderDirection.allCases, id: \.self) { item in
                    Text(item.label).tag(item)
                }
            }
        } label: {
            menuLabel(direction.symbolName)
        }
        .foregroundColor(spreadMenusDisabled ? theme.textSecondary : theme.textPrimary)
        .disabled(spreadMenusDisabled)
        .opacity(spreadMenusDisabled ? 0.35 : 1)
        .accessibilityLabel("開き方向")
    }

    private var pageBinding: Binding<Double> {
        Binding(
            get: { draggingPage ?? Double(max(currentPage, 1)) },
            set: { value in
                draggingPage = value
                let page = Int(value.rounded())
                if page != currentPage {
                    onSelectPage(page)
                }
            }
        )
    }

    private func barButton(
        systemImage: String,
        label: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .foregroundColor(tint ?? theme.textPrimary)
        .accessibilityLabel(label)
    }
}
