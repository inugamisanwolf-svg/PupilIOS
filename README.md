# PupilIOS

**Pupil（Android 版）の iOS 移植** — hitomi.la のギャラリーを閲覧するためのネイティブ
SwiftUI クライアントです。Mac なしで GitHub Actions 上でビルドし、署名なし IPA を
Sideloadly 等で iPhone にインストールする構成を前提にしています。

- ターゲット: iOS 16.0 以上 / iPhone のみ
- 実装: SwiftUI（Swift 5 言語モード）、外部 Swift パッケージ依存なし
- ライセンス: **GPLv3**（移植元 Pupil を継承） / デザインシステム部分に MIT（Astryx）

---

## 機能

| 画面 | 内容 |
|---|---|
| ブラウズ | 人気 / 新着 / 期間別などのソート切替、言語フィルタ、3 列グリッド、無限スクロール、引っ張って更新 |
| 検索 | 検索履歴チップ、入力中のタグサジェスト（`namespace:tag` 形式と `-tag` 除外に対応）、結果グリッド |
| 詳細 | 表紙・タイトル（日本語タイトル切替に追従）・artist / group / parody / tag チップ、言語別バージョン切替、関連ギャラリー、「読む（前回ページから再開）」、お気に入り / 後で読む / 共有 |
| リーダー | 全画面・横スワイプのページ送り、ピンチ / ダブルタップズーム、タップでクローム表示切替、ページスライダーと `n / total`、読了位置の保存、前後 2 ページのプリフェッチ |
| お気に入り / 履歴 | ID 一覧を並列取得してグリッド表示、空状態メッセージ、履歴クリア |
| 設定 | 日本語タイトル表示、タグ翻訳言語（es / id / ko / zh）、1 ページあたり件数、テーマ、ブラウズ既定値、Astryx 製の設定パネル（WKWebView・オフライン）、About（GPLv3 表記と移植元リンク） |

技術的な特徴:

- `HitomiClient`（actor）が hitomi.la のプロトコル（galleriesindex / nozomi / gg.js /
  tag index）を実装。画像 URL は gg.js のサブドメイン解決を内部で行います。
- 画像取得は必ず `RemoteImage`（Referer / UA 付き）経由。`AsyncImage` は 403 になるため使いません。
- タグ翻訳はバンドル同梱の `Resources/tags/*.json`（オフライン）。
- デザインシステムは Meta の Astryx のテーマトークンを SwiftUI に移植したもの＋
  本物の Astryx（React）を WKWebView で描画する面（`Resources/astryx/`、完全オフライン）。

---

## ビルド

### 1. GitHub Actions（推奨・Mac 不要）

`.github/workflows/ios-build.yml` が `macos-15` ランナーで以下を実行します。

1. `brew install xcodegen`
2. `xcodegen generate --spec project.yml`
3. `xcodebuild -sdk iphoneos -configuration Release ... CODE_SIGNING_ALLOWED=NO`（署名なし）
4. `Payload/PupilIOS.app` を zip して `PupilIOS-unsigned.ipa`
5. artifact `PupilIOS-unsigned-ipa` としてアップロード（ビルドログは `build-log`）

起動方法:

- GitHub の **Actions → ios-build → Run workflow**、または
- `main` への push（自動）、または
- ローカルのドライバ:

```powershell
# ワークフローを dispatch → 完了待ち → 失敗なら error: 行を抽出、
# 成功なら artifact を dist/ に展開する
python scripts/ci.py run

# 個別操作
python scripts/ci.py status
python scripts/ci.py logs --run-id <RUN_ID>
python scripts/ci.py artifact --run-id <RUN_ID>
```

`scripts/ci.py` は Python 3.11 標準ライブラリのみで動きます。GitHub トークンは
Windows 資格情報マネージャ（`git credential fill`）から読み、画面にもログにも出しません。
トークンには `repo` と `workflow` スコープが必要です。

### 2. ローカル（macOS がある場合）

```bash
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild -project PupilIOS.xcodeproj -scheme PupilIOS \
  -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build

mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/PupilIOS.app Payload/
zip -qry PupilIOS-unsigned.ipa Payload
```

Windows / Linux からビルドする場合、`swiftc` が無い環境ではローカルコンパイル確認は
できません。CI を唯一のコンパイル検証手段にしてください。

---

## IPA の入手とインストール

1. Actions の該当 run から artifact **`PupilIOS-unsigned-ipa`** をダウンロード
   （要ログイン。API から落とす場合は `python scripts/ci.py artifact` → `dist/PupilIOS-unsigned.ipa`）。
2. artifact は zip なので展開し、中の `PupilIOS-unsigned.ipa` を取り出す。
3. PC に [Sideloadly](https://sideloadly.io/)（Windows / macOS）を入れ、iPhone を USB 接続。
4. `PupilIOS-unsigned.ipa` を Sideloadly にドラッグし、Apple ID を入力して Start。
   署名は Sideloadly 側で行われます（このリポジトリの IPA は**署名なし**です）。
5. iPhone 側で **設定 → 一般 → VPN とデバイス管理** から開発者プロファイルを信頼。
   iOS 16 以降は **設定 → プライバシーとセキュリティ → デベロッパモード** を ON にして再起動。

無料の Apple ID の場合:

- 署名の有効期限は **7 日**。切れたら同じ手順で入れ直し（データは保持されません）。
- 同時にインストールできる自作アプリは 3 個まで、App ID は 10 個/週まで。

有料の Apple Developer Program（$99/年）の場合:

- 証明書の有効期間は **1 年**。adhoc / development プロファイルで長期運用できます。
- 7 日ごとの再署名から解放されます。

AltStore / SideStore を使うと、同じ Wi-Fi 内で 7 日ごとの自動再署名ができます。

---

## 実機で使うまで

このリポジトリが配るのは **`PupilIOS-unsigned.ipa`（署名なし）** です。署名は入れ替える
必要があるので、次の 3 択から選びます。どの方法でも**同じ IPA をそのまま渡すだけ**で、
変換や再パッケージは不要です。

| 方法 | PC 必須 | 再署名の頻度 | 向いている人 |
|---|---|---|---|
| **Sideloadly** | 初回のみ（USB） | 無料 Apple ID なら 7 日ごとに手動で入れ直し | まず動かしたい / 単発で試したい |
| **AltStore** | あり（AltServer 常駐） | 7 日ごとに自動（同じ Wi-Fi 上で） | 常用したいが有料証明書は使いたくない |
| **SideStore** | 初回のみ + 常時接続の相手端末 | 7 日ごとに自動（Wi-Fi / モバイル） | PC なしで常用したい |

共通の前提:

- **iOS 16.0 以上 / iPhone のみ**（iPad・Mac Catalyst は非対応）
- 無料 Apple ID の場合、同時に保持できる自作アプリは 3 個まで・App ID は 10 個/週まで
- 有料 Apple Developer Program（$99/年）なら証明書は 1 年有効で、7 日ごとの再署名から解放される

初回起動時の注意:

- 追加の権限要求（写真・位置情報・カメラ等）は**出ません**。通信は **HTTPS のみ**で、
  ローカルネットワーク許可も不要です。
- 起動直後のブラウズ画面が空のときは、下引っ張り更新を 1 回。hitomi.la 側の応答が
  遅い場合があります。
- 署名が切れると起動時に「開発元を信頼できません」系のダイアログで落ちます。再署名して
  入れ直してください（アプリ内データは引き継がれません）。

## 既知の制限

- **署名なし IPA** です。インストールには必ず再署名（Sideloadly / AltStore / MobAI 等）が必要。
- 無料 Apple ID では 7 日で失効し、アプリ内データは引き継げません。
- App Store には出せません（年齢制限コンテンツを扱うアプリのため）。
- 画像は hitomi.la から直接取得します（Referer / UA 必須）。ネットワーク側で
  Referer が落とされると画像が 403 になります。
- ネットワーク到達性は hitomi.la 側の状況に依存します。プロキシ / VPN 併用時は gg.js の
  サブドメイン解決もその経路に乗ります。
- タグ翻訳は同梱の 4 言語（es / id / ko / zh）のみ。新しい言語は `Resources/tags/` に
  JSON を足せば `TagTranslations.availableLanguages` に現れます。
- リーダーのズームは `UIScrollView` ベース。ダブルタップズームの倍率は固定（2.5x）。
- **リーダーでピンチ操作とページ送りを同時に行う操作は実機未検証**（`TabView(.page)` と
  `UIScrollView` のジェスチャ競合は、端末と指の速度によって挙動が変わりうる）。
- **iOS 16.0–16.3 の WKWebView では Astryx 面にトークンシムが必要**（新しめの CSS
  custom property 解決の差異を吸収する層を噛ませて表示）。16.4 以降は素のままで表示される。
- **ダウンロード（オフライン保存）機能は未移植**。移植元 Pupil の DL 機能は本移植の
  スコープ外で、閲覧はすべてオンライン取得。
- iPad / Mac(Catalyst) は未対応（`TARGETED_DEVICE_FAMILY = 1`、iPhone のみ）。
- iOS 16 未満は非対応（`NavigationStack` 等を使用）。
- CI は macOS ランナーの無料枠を使うため、ビルド 1 回あたり 5〜8 分かかります。

---

## リポジトリ構成

```
project.yml                  XcodeGen のプロジェクト定義
Resources/Info.plist         Info.plist（GENERATE_INFOPLIST_FILE=NO）
Resources/Assets.xcassets/   AppIcon（scripts/make_icon.py で生成）
Resources/tags/*.json        タグ翻訳データ（オフライン）
Resources/astryx/            WKWebView 用の Astryx バンドル（事前ビルド済み・外部 CDN 不可）
Sources/Hitomi/              プロトコル層（HitomiClient / モデル / タグ翻訳）
Sources/Store/               Settings / Library（UserDefaults 永続化）
Sources/DesignSystem/        Astryx 由来の SwiftUI デザインシステム
Sources/UI/                  画面（Browse / Search / Detail / Reader / Library / Root）
Sources/App/                 エントリポイント
scripts/ci.py                Actions 起動・監視・ログ／artifact 回収
scripts/make_icon.py         AppIcon PNG 生成（Pillow）
.github/workflows/           ios-build ワークフロー
docs/CONTRACT.md             凍結 API・担当分担・画面要件のコントラクト
```

`PupilIOS.xcodeproj` は生成物なのでコミットしません（`.gitignore` 済み）。

---

## ライセンス

- **本アプリ本体: GNU General Public License v3.0**
  移植元 [Pupil](https://github.com/kyanchiu-dev/Pupil)（Android / Kotlin）の GPLv3 を継承します。
  再配布・改変する場合は同じく GPLv3 でソースを公開してください。
- **Astryx（`Sources/DesignSystem/`, `Resources/astryx/`, `design/`）: MIT License**
  Astryx は Meta のデザインシステムです。MIT 部分はその条件に従います。

アプリ内の About 画面にも GPLv3 の表記と移植元へのリンクを表示します。
本アプリは hitomi.la および権利者とは無関係のサードパーティ製クライアントです。
