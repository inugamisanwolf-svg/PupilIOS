# ASTRYX — PupilIOS のデザイン層

PupilIOS のデザインシステムは **Meta Open Source の Astryx** を二段構えで使っている。

| 段 | 何をしているか | 場所 |
|---|---|---|
| (A) トークン移植 | `@astryxdesign/theme-neutral` の CSS custom property の**実値**を Swift に写像し、SwiftUI の全部品がそれだけを使う | `Sources/DesignSystem/AstryxTheme.swift` / `AstryxComponents.swift` |
| (B) 本物の Astryx 描画 | 本物の React 19 + `@astryxdesign/core` コンポーネントを esbuild で単一バンドルし、`WKWebView` でオフライン描画（設定面・About 面） | `design/` → `Resources/astryx/` → `Sources/DesignSystem/AstryxWebView.swift` |

- Astryx: <https://github.com/meta/astryx> / <https://astryx.atmeta.com> — **MIT**
- 取得版（実測 2026-11-27、registry.npmjs.org）: `@astryxdesign/core@0.7.17`, `@astryxdesign/theme-neutral@0.7.17`
- 併せて固定したもの: `react@19.3.1`, `react-dom@19.3.1`, `@stylexjs/stylex@0.19.2`, `esbuild@0.28.2`

---

## 1. 何をどこから取ったか

| 成果物 | 取得元 | 使うファイル |
|---|---|---|
| リセット CSS | `@astryxdesign/core/reset.css`（exports は `./src/reset.css` を指す） | `Resources/astryx/astryx.css` |
| コンポーネント CSS | `@astryxdesign/core/astryx.css`（= `dist/astryx.css`, StyleX プリコンパイル済み・全コンポーネント） | 同上 |
| テーマトークン | `@astryxdesign/theme-neutral/theme.css`（= `dist/theme.css`, `@scope` + `light-dark()`） | 同上 |
| フォント | `@astryxdesign/theme-neutral/fonts.css` + `fonts/*.woff2`（Figtree, SIL OFL 1.1） | 同上（**data URI で埋め込み**） |
| React コンポーネント | `@astryxdesign/core/{Card,Stack,Text,Badge,Button,Switch,Divider,theme}` サブパス import | `design/src/main.jsx` |

`astryx.css` は上記 3 本 + 自前の `design/src/pupil.css` を**この順で結合**したもの。ビルド時に `url()` を全部 `data:` URI に置換し、`url(http…)` / `@import` が残っていたらビルドが**失敗する**ようにしてある（外部 CDN 参照ゼロの担保）。

---

## 2. トークン対応表（CSS 実値 → Swift）

出典は `@astryxdesign/theme-neutral@0.7.17/dist/theme.css`。Astryx の色は `light-dark(明, 暗)` のペアで定義されており、PupilIOS は **dark 列（第 2 引数）だけ**を使う（CONTRACT §1: `AstryxTheme.colorScheme` は常に `.dark`）。

### 2.1 色

| Swift (`AstryxTheme`) | CSS custom property | dark 実値 | 出典（theme.css 行） |
|---|---|---|---|
| `background` | `--color-background-body` | `#1B1B1B` | 196 |
| `surface` | `--color-background-surface` | `#262626` | 195 |
| `card` | `--color-background-card` | `#1B1B1B` | 197 |
| `surfaceRaised` | `--color-background-gray` | `#303030` | 278 |
| `textPrimary` | `--color-text-primary` | `#FFFFFF` | 206 |
| `textSecondary` | `--color-text-secondary` | `#9E9E9E` | 207 |
| `border` | `--color-border` | `#FFFFFF` α `0x1A`（= 10.2%） | 237 |
| `accent` | `--color-accent` | `#F1F1F1` | 200 |
| `onAccent` | `--color-on-accent` | `#111111` | 212 |
| `danger` | `--color-error` | `#FF705D` | 233 |
| `accentMuted`（追加） | `--color-accent-muted` | `#474747` | 201 |
| `success`（追加） | `--color-success` | `#64AF4C` | 231 |

**補足（実測で確認した重要な事実）**: neutral dark では `--color-background-card` が `--color-background-body` と**同じ `#1B1B1B`**。つまり Astryx のカードは「塗りで浮かせる」のではなく **1px の `--color-border` だけで区切る**設計。PupilIOS の `AstryxCard` もそのまま踏襲している（`Resources/astryx` を Chrome で描画し、カード内部とページ背景がともに `rgb(27,27,27)` であることをピクセルサンプリングで確認）。

### 2.2 余白（`--spacing-*`）

`AstryxTheme.space(_:)` の戻り値。1rem = 16pt 換算。出典は `@astryxdesign/core@0.7.17/dist/astryx.css` の `:root { --spacing-0…--spacing-12 }`（4px グリッド）。

| `AstryxSpace` | CSS | pt |
|---|---|---|
| `.xxs` | `--spacing-1` (0.25rem) | 4 |
| `.xs` | `--spacing-2` (0.5rem) | 8 |
| `.sm` | `--spacing-3` (0.75rem) | 12 |
| `.md` | `--spacing-4` (1rem) | 16 |
| `.lg` | `--spacing-5` (1.25rem) | 20 |
| `.xl` | `--spacing-6` (1.5rem) | 24 |
| `.xxl` | `--spacing-8` (2rem) | 32 |

### 2.3 角丸（`--radius-*`）

| Swift | CSS | theme-neutral 実値 | core 既定 | 出典 |
|---|---|---|---|---|
| `radiusSmall` | `--radius-inner` | **6px** (0.375rem) | 4px | theme.css 283（theme が上書き） |
| `radiusMedium` | `--radius-element` | **10px** (0.625rem) | 8px | theme.css 284 |
| `radiusLarge` | `--radius-container` | **12px** (0.75rem) | 12px | theme.css 285 |
| `radiusFull`（追加） | `--radius-full` | 9999px | 同 | theme.css 288 |

`Card` は `--radius-container` を使う（`core/src/Card/Card.tsx` の `'--_card-radius': radiusVars['--radius-container']`）。

### 2.4 書体（`--text-*` / `--font-size-*`）

| `AstryxFontRole` | CSS | 実値 | Swift |
|---|---|---|---|
| `.display` | `--text-display-2-size` = `--font-size-4xl` | 2.1875rem = 35px / weight normal | `.system(size: 35, weight: .regular)` |
| `.heading1` | `--text-heading-1-*` = `--font-size-2xl` | 1.5rem = 24px / semibold | `.system(size: 24, weight: .semibold)` |
| `.heading2` | `--text-heading-2-*` = `--font-size-xl` | 1.25rem = 20px / semibold | `.system(size: 20, weight: .semibold)` |
| `.heading3` | `--text-heading-3-*` = `--font-size-lg` | 1.0625rem = 17px / **bold**（theme が semibold→bold に上書き, theme.css 119） | `.system(size: 17, weight: .bold)` |
| `.body` | `--text-body-*` = `--font-size-base` | 0.875rem = 14px / normal | `.system(size: 14, weight: .regular)` |
| `.label` | `--text-label-*` | base + medium(500) | `.system(size: 14, weight: .medium)` |
| `.caption` | `--text-supporting-*` = `--font-size-sm` | 0.75rem = 12px / normal | `.system(size: 12, weight: .regular)` |

フォントファミリは CSS 側 `--font-family-body: Figtree, -apple-system, …`（theme.css 173-174）。iOS ネイティブ側は Figtree を同梱せず **SF（`.system`）** に落としている（§5 の差分参照）。

---

## 3. Swift 部品 ↔ Astryx コンポーネント

| Swift | Astryx（core） | 実装メモ |
|---|---|---|
| `AstryxCard<Content>(padding: .md)` | `Card` | `--color-background-card` 塗り + `--color-border` 1px + `--radius-container` |
| `AstryxBadge(_:tint:)` | `Badge` | `tint` をピル塗りに使い、文字色は輝度から自動決定（`AstryxContrast`）。`tint` に暗色（`surfaceRaised`）を渡しても読める |
| `AstryxChip(_:selected:action:)` | `Badge`/`Token` 系の選択チップ | 選択時 `--color-accent` 塗り + `--color-on-accent` 文字 |
| `AstryxButtonStyle` → `.buttonStyle(.astryx)` | `Button`（variant: primary / secondary / ghost / destructive） | `.astryx` は Astryx の既定 variant = **secondary**。`AstryxButtonStyle(.primary)` 等と `ButtonStyle` extension の `static var astryx / astryxPrimary / astryxGhost / astryxDestructive` を提供。高さは `--size-element-md` = 32pt |
| `AstryxSectionHeader(_:)` | `Heading`（level 3 相当） | `--text-heading-3` = 17pt bold |
| `AstryxDivider()` | `Divider` | `--color-border` 1px |
| `AstryxProgressDots(current:total:)` | `Pagination` 系の代替（リーダー用） | 12 ページ超は現在ページ周辺 12 個の窓表示 |
| `AstryxWebView(surface:payload:onEvent:)` | `Theme` + `Card/Stack/Heading/Text/Badge/Button/Switch/Divider` | 本物の React。§4 |

`Sources/DesignSystem` は凍結 API（`docs/CONTRACT.md` §1）のシグネチャをそのまま実装している。追加したのは `AstryxTheme.card / accentMuted / success / radiusFull / elementHeight` と `AstryxButtonStyle` の variant・`AstryxContrast`（いずれも追加のみ、既存名は不変）。

---

## 4. 本物の Astryx で描いている面（WKWebView）

`Resources/astryx/pupil-astryx.html` が `./astryx.css` と `./astryx.js` を相対参照する（この 3 ファイルは必ず同一ディレクトリに配置される）。

| 面 | クエリ | 中身 |
|---|---|---|
| 設定 | `?surface=settings` | `Heading` / `Card` / `Switch`（日本語タイトル・タグ翻訳）/ `Button`（件数ステッパー・言語・並び順・テーマ）/ `Badge` / `Divider` |
| About | `?surface=about` | アプリ名・GPLv3・移植元 codeberg.org/pupil/Pupil・Astryx MIT・同梱版数 |

`Theme` には `@astryxdesign/theme-neutral` の `neutralTheme` を `mode="dark"` で渡しているので、`<html>` に `data-astryx-theme="neutral" data-theme="dark"` が同期される（実測: レンダリング後 DOM で確認）。

### ブリッジ（CONTRACT §1 の凍結仕様）

```
JS → Swift : window.webkit.messageHandlers.pupil.postMessage({ name, payload })
Swift → JS : window.pupilUpdate(JSON文字列)      // 設定値マージ
             window.PupilAstryx.mount("settings"|"about")  // 面の切り替え
```

| イベント名（凍結） | payload | 発生 |
|---|---|---|
| `ready` | `{ surface, core }` | 面のマウント時 |
| `setting` | `{ key, value }` | トグル/ボタン操作（`value` は必ず文字列。真偽は `"true"`/`"false"`） |
| `openurl` | `{ url }` | 外部リンク（`SFSafariViewController` 等で開く想定） |

Swift から渡す payload キー（`AstryxWebView(payload:)`）:
`appName, appVersion, japaneseTitles, tagTranslation, tagTranslationLanguages, perPage, theme, browseSort, browseLanguage, languages("id=label,…"), sortModes("raw=label,…")`。
`languages` / `sortModes` は設定面のチップとして実描画されるので、Swift 側の `Settings.languages` / `SortMode.label` を平坦化して渡せば表示が一致する。

### 実測での確認（2026-11-27、本機 Chrome 125+/ローカル HTTP）

- `?surface=settings` / `?surface=about` の両面で DOM に `astryx-card` / `astryx-stack` / `astryx-heading` / `astryx-text` / `astryx-badge` / `astryx-switch` が出る
- `body` 背景 `rgb(27,27,27)`、カード内部も `rgb(27,27,27)`（§2.1 の補足）
- `window.pupilUpdate` は function。呼ぶと `Switch` の状態と `Badge` が即時反映
- チップ操作で `{name:"setting", payload:{key:"browseLanguage", value:"en"}}` が `postMessage` に到達
- 真の 390px 幅で `document.scrollWidth == innerWidth`（横 overflow なし）
- バンドル内に外部 URL 参照なし（ビルド時に検証）。`astryx.js` 697 KB / `astryx.css` 448 KB（Figtree 8 面を data URI で内包）

---

## 5. 差分・未対応（正直なところ）

1. **Figtree はネイティブ側で使っていない**。SwiftUI は `.system`（SF / Hiragino）に写像する。Web 面だけ Figtree が当たる。CJK は Figtree に無いので、どちらでも和文は OS フォント。
2. **Dynamic Type 未対応**。Astryx の `--font-size-*` は `--_dynamic-type-*` 倍率で伸縮するが、Swift 側は固定 pt。`Font.custom(_:size:relativeTo:)` 相当の可変対応は今回入れていない（[推測] ではなく未実装）。
3. **iOS 16.0–16.3 の WKWebView は `@scope` と `light-dark()` を持たない**。theme-neutral のトークン宣言が落ちるため、`design/src/pupil.css` に**同一値の `:root` シム**を置いてある（値は theme.css の dark 列そのまま、コメントに CSS 行番号を併記）。iOS 16.4+ / 17.5+ では `light-dark()` が有効になるが、`:root` シムの値と等価なので見た目は変わらない。**16.0–16.3 実機での見た目は未検証**。
4. `AstryxProgressDots` は 12 ページ超で窓表示（数千ページのギャラリー対策）。Astryx の `Pagination` そのものではない。
5. `AstryxBadge` は視認性のため 1px の `--color-border` を足している（Astryx `Badge` の variant 定義そのままではない）。
6. ローカルに `swiftc` が無いため、Swift 側は**型の机上検証のみ**。CI（build-ci）のコンパイル結果が最終判定。

---

## 6. 再ビルド手順

```powershell
cd design
npm install            # 初回のみ（CI では実行しない。生成物をコミットする）
npm run build          # -> ../Resources/astryx/astryx.js / astryx.css
```

- `design/node_modules` は**コミットしない**（`.gitignore`。build-ci 管轄）。
- 生成物 `Resources/astryx/astryx.js` / `astryx.css` と手書きの `pupil-astryx.html` は**コミットする**。
- `Resources/astryx/pupil-astryx.html` は静的ファイル（ビルドでは生成しない）。`astryx.js` / `astryx.css` を相対参照するので、3 ファイルは同じディレクトリに置くこと。
- Astryx を上げるときは `design/package.json` の版を上げ → `npm install` → `npm run build` → 本書の §2 の実値を**読み直して** Swift トークンを更新する（推測で埋めない）。

`design/build.mjs` がやること:

1. `@astryxdesign/core/{reset.css,astryx.css}` + `@astryxdesign/theme-neutral/{fonts.css,theme.css}` + `design/src/pupil.css` を結合
2. `fonts.css` の `url(./fonts/*.woff2)` を `data:font/woff2;base64,…` に置換
3. 外部参照（`url(http…)` / `@import`）が残っていれば**エラーで停止**
4. `design/src/main.jsx` を esbuild で単一 IIFE に（`format: iife`, `target: safari15`, `jsx: automatic`, `NODE_ENV=production`）→ `astryx.js`。版数は `define` で注入

---

## 7. ライセンス

| 対象 | ライセンス |
|---|---|
| PupilIOS 本体 | **GPLv3**（Android アプリ [Pupil](https://codeberg.org/pupil/Pupil) の移植） |
| Astryx (`@astryxdesign/core`, `@astryxdesign/theme-neutral`) | **MIT** — Copyright (c) Meta Platforms, Inc. and affiliates. <https://github.com/meta/astryx> |
| React / React DOM | MIT |
| `@stylexjs/stylex` | MIT |
| Figtree フォント | SIL Open Font License 1.1（`@astryxdesign/theme-neutral/fonts/figtree.LICENSE.txt`） |

`Resources/astryx/astryx.js` / `astryx.css` の先頭には上記の帰属表示バナーを埋め込んでいる（生成物なので直接編集しない）。
