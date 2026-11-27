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
    let onClose: () -> Void
    /// 1 始まりのページ番号。
    let onSelectPage: (Int) -> Void
    let onToggleFavorite: () -> Void
    let onToggleReadLater: () -> Void

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

            AstryxProgressDots(current: shownPage, total: total)
                .frame(maxWidth: .infinity)
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
