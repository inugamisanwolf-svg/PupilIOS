import SwiftUI

/// テーマ編集画面を開いている間だけ立つフラグ。
///
/// `RootView` はテーマが変わったら `TabView` を作り直す（`ThemeStore.revision` を
/// `.id` に渡す）ことで全画面の色を反映するが、作り直すと `SettingsView` の
/// `NavigationStack` も一緒に巻き戻る。`ThemeEditorView` は色を 1 タップごとに
/// `ThemeStore` へ保存する（＝`revision` がその場で増える）ので、そのまま
/// 作り直すと編集画面が毎回閉じてしまい、色を詰められない。
///
/// そこで編集中は作り直しを見送り、閉じたときにまとめて 1 回だけ反映する。
@MainActor
final class ThemeEditSession: ObservableObject {
    static let shared = ThemeEditSession()

    @Published private(set) var isEditing: Bool = false

    private init() {}

    func beginEditing() {
        if !isEditing { isEditing = true }
    }

    func endEditing() {
        if isEditing { isEditing = false }
    }
}
