# プロトコル自己検証（実 API との突き合わせ）

`_probe/verify.py` は `Sources/Hitomi/*.swift` の URL 組み立て・パースを Python で
1:1 に書き直し、**その出力をそのまま実 hitomi に投げて** 200/206 と中身を確かめる。
Swift 側の実装を変えたらこのスクリプトも同じ関数を直す（関数名を Swift 側と対応させてある）。

```
python _probe/verify.py     # 実行してこのファイルを再生成
```

実行環境: Python 3.11 / curl 8.22 / Windows。`swiftc` は無いのでコンパイル確認は CI のみ。

## 実測で確定したこと

| 項目 | 実測結果 |
|---|---|
| `gg.js` の形 | `var o = 1;` / `o = 0; break;` / `case N:` ×700+ / `b: '1795770002/'`（末尾スラッシュ込み） |
| 画像ページ URL | `w{1+m(g)}.<host>/<b><s(hash)>/<hash>.webp` → **200** |
| サムネ URL (`tn`) | `{a..z}{tn}.<host>/webpbigtn/<x>/<xx>/<hash>.webp` → **200**（`webpsmalltn` も 200） |
| nozomi | `Range` は**閉区間**。`bytes=0-95` で 96 バイト = 24 id。`bytes=0-96` だと 97 バイト来る |
| `Content-Range` | `bytes 0-15/4990152` 形式。**/4 が件数** |
| nozomi の窓取得 | offset=10/count=8 → `bytes=40-71` で生レンジ取得と完全一致 |
| b-tree ノード | ルートは 464 バイトちょうど、17 個の子アドレス、キーは 4 バイトの SHA-256 先頭 |
| b-tree テキスト検索 | 単語タグ（glasses/stockings/nakadashi/ahegao/tomgirl/kemonomimi）は全件解決。データ長 = `count*4+4` で一致 |
| 多語タグ | `big breasts` / `school uniform` 等は b-tree に実体が無い（0〜1 件）。**`namespace:tag` の nozomi 経由が正**（`n/tag/female:big%20breasts-all.nozomi` は 206） |
| 提案 JSON | `[["big breasts", 477114, "female"], ...]`。パスは **1文字1セグメント**（`/global/b/i/g.json`） |
| 提案の日本語 | `tagindex` は英語タグ名のみ → 日本語クエリは **404**（=サジェスト無しであってエラーではない） |
| `languages[].galleryid` | **JSON 数値**（`{"galleryid": 3901548, ...}`）。Kotlin は `String` 宣言。素の `String?` デコードだと gallery 全体が失敗する |
| `japanese_title` | `null` のギャラリーが普通にある（Optional 必須） |
| `tags[].female` / `male` | 文字列 `"1"` / `""`（bool ではない） |
| `haswebp` | キー自体が無いギャラリーがある（Optional 必須） |

## 移植で直した食い違い（Kotlin / 元コードとの差分）

1. **`Range<Int>` の off-by-one** — `Range` は上限が exclusive なのに、そのまま
   `bytes=lower-upper` に渡していたので 1 バイト多く要求していた（nozomi 24 件取得で 97 バイト）。
   `upperBound - 1` にして閉区間へ変換。Kotlin は `(start*4)..((start+count)*4 - 1)` で閉区間。
2. **パスの percent-encode** — Kotlin は ktor が `female:big breasts` の空白を `%20` に
   してくれるが、Foundation の `URL(string:)` は空白入りで **nil** を返す。`HitomiPath.segment`
   で 1 セグメントずつ encode する（`_probe` で `%20` 版が 206 を返すことを確認）。
3. **`Content-Range` が無いときの total** — `offset + count` としていたのは誤り。
   サーバがレンジを無視して全体を返した場合の実データ長（`offset + ids.count`）に直した。
4. **`languages[].galleryid` が数値** — `FlexibleString` で数値/文字列どちらも受ける。
   そのままだと多言語ギャラリーの詳細画面が丸ごと落ちる。
5. **`SearchQuery` の `indirect` 漏れ**（CI 実測）— 再帰 enum なので必須。
6. **`Array.reversed()` の型** — `context.readLater.reversed()` は `[Int]` ではなく
   `ReversedCollection<[Int]>` を返すので `[Int]` を返す関数では型エラー。`Array(...)` で包む。
7. **検索テキストの一本化** — `SearchQuery.text` は `QueryLanguage.text(of:)` に委譲し、
   履歴は `QueryLanguage.canonicalHistoryText(_:)` を通した正規形（`female:big_breasts`）で保存。
8. **`gg.js` のパース失敗を握りつぶさない** — 失敗したまま `fetchedAt` を更新すると
   壊れたサブドメインを 60 秒使い続ける。`load` を throwing にした。
9. **`suggestions` の 404** — 日本語クエリ等では 404 が正常。空配列を返す（例外を投げない）。

## 未検証リスク

- **コンパイルは未検証**（このマシンに swiftc が無い）。CI の build-ci が確認する。
- 画像の実バイト列取得（`imageData`）は `_probe` では status/サイズのみ確認。デコードは未検証。
- iOS の `URLSession` が `Range` ヘッダをそのまま送ることは未検証（curl でしか確認していない）。
  `URLSession` が `Content-Range` を透過的に処理する場合、`offset` がずれる可能性は残る。
- pagination の上限（`nozomi` 全件読み）は実機メモリで未検証。


## 実行結果（2026-11-27 18:11:30）

97/97 checks passed

| 結果 | セクション | チェック | 詳細 |
|---|---|---|---|
| PASS | gg | gg.js fetched | `22904 bytes` |
| PASS | gg | load: mDefault is one digit | `mDefault=1` |
| PASS | gg | load: case count > 0 | `2112 cases -> o=[0]` |
| PASS | gg | load: b ends with '/' | `b='1795770002/'` |
| PASS | gg | load: b is 'digits/' | `b='1795770002/'` |
| PASS | gg | s(): reorders the last three digits | `s=786` |
| PASS | gg | realFullPath(): xx/x/hash | `3/12/0000000000000000000000000000000000000000000000000000000000000123` |
| PASS | nozomi | window(index-all) returns 4 ids | `[4360531, 4360499, 4360495, 4360494]` |
| PASS | nozomi | Content-Range total divides by 4 | `total=1247538` |
| PASS | gallery | galleries/4360531.js fetched | `` |
| PASS | models | id is a string | `'4360531'` |
| PASS | models | title is a string | `` |
| PASS | models | japanese_title is string or null | `'Artist: エリック'` |
| PASS | models | files non-empty | `62 files` |
| PASS | models | files[0].hash present | `` |
| PASS | models | files[0].name present | `` |
| PASS | models | files[0].width present | `` |
| PASS | models | files[0].height present | `` |
| PASS | models | files[0].width/height are ints | `` |
| PASS | models | haswebp absent or int | `'<missing>'` |
| PASS | models | languages present (single language gallery) | `empty -> []` |
| PASS | models | tags[0].female/male type | `female='1' male=''` |
| PASS | models | tags[0].tag is a string | `` |
| PASS | models | scene_indexes type | `list` |
| PASS | models | related type | `list` |
| PASS | url | webpbigtn answers 200 | `200 https://btn.gold-usergeneratedcontent.net/webpbigtn/1/47/e535ca4b4f1de44202562e2e3c35383a636fe9ba5a4ddc0744d3e582118c1471.webp` |
| PASS | url | webpbigtn host is <sub>.gold-usergeneratedcontent.net | `https://btn.gold-usergeneratedcontent.net/webpbigtn/1/47/e535ca4b4f1de44202562e2e3c35383a636fe9ba5a4ddc0744d3e582118c1471.webp` |
| PASS | url | webpsmalltn answers 200 | `200 https://btn.gold-usergeneratedcontent.net/webpsmalltn/1/47/e535ca4b4f1de44202562e2e3c35383a636fe9ba5a4ddc0744d3e582118c1471.webp` |
| PASS | url | webpsmalltn host is <sub>.gold-usergeneratedcontent.net | `https://btn.gold-usergeneratedcontent.net/webpsmalltn/1/47/e535ca4b4f1de44202562e2e3c35383a636fe9ba5a4ddc0744d3e582118c1471.webp` |
| PASS | url | webp page answers 200 | `200 https://w2.gold-usergeneratedcontent.net/1795770002/327/e535ca4b4f1de44202562e2e3c35383a636fe9ba5a4ddc0744d3e582118c1471.webp` |
| PASS | url | webp page host is <sub>.gold-usergeneratedcontent.net | `https://w2.gold-usergeneratedcontent.net/1795770002/327/e535ca4b4f1de44202562e2e3c35383a636fe9ba5a4ddc0744d3e582118c1471.webp` |
| PASS | models | gallery 2785234 has languages[] | `3 entries` |
| PASS | models | languages[].galleryid is a number in the live payload | `type=int value=3901548` |
| PASS | models | languages[].galleryid needs a lenient read | `FlexibleString covers int/string` |
| PASS | models | gap: a plain String? decode would fail this gallery | `documented divergence from the Kotlin model` |
| PASS | models | languages[].name present | `'english'` |
| PASS | models | languages[].language_localname present | `` |
| PASS | models | japanese_title is null on some galleries | `9/12 sample galleries` |
| PASS | nozomi | dateAdded/all/index | `206 bytes 0-3/4990152` |
| PASS | nozomi | datePublished/all/index | `206 bytes 0-3/4990152` |
| PASS | nozomi | popularToday/all/index | `206 bytes 0-3/674288` |
| PASS | nozomi | popularWeek/all/index | `206 bytes 0-3/3865828` |
| PASS | nozomi | popularMonth/all/index | `206 bytes 0-3/4719580` |
| PASS | nozomi | popularYear/all/index | `206 bytes 0-3/4989232` |
| PASS | nozomi | dateAdded/all/index | `206 bytes 0-3/2292260` |
| PASS | nozomi | dateAdded/tag/female:big breasts | `206 bytes 0-3/1908456` |
| PASS | nozomi | popularWeek/tag/female:big breasts | `206 bytes 0-3/1596100` |
| PASS | nozomi | dateAdded/artist/fukudahda | `206 bytes 0-3/2120` |
| PASS | nozomi | popularWeek/series/genshin impact | `206 bytes 0-3/53200` |
| PASS | nozomi | 0-95 -> 96 bytes / 24 ids | `96 bytes, 24 ids` |
| PASS | nozomi | 0-96 would ask for 97 bytes (the old bug) | `97 bytes, 24 ids` |
| PASS | nozomi | window(offset=10,count=8) matches a raw range | `[4360486, 4360484, 4360483, 4360482, 4360479, 4360476, 4360474, 4360472]` |
| PASS | nozomi | window returns the file total, not offset+count | `total=1247538` |
| PASS | nozomi | popularWeek != dateAdded head | `[2785234, 4347238, 4351905, 4349892] vs [4360531, 4360499, 4360495, 4360494]` |
| PASS | btree | galleriesindex version fetched | `'1795769647'` |
| PASS | btree | root node decodes | `15 keys, 15 datas, 17 subnodes` |
| PASS | btree | root has B+1 subnode slots | `` |
| PASS | btree | root request is exactly max_node_size bytes | `464 bytes` |
| PASS | btree | keys are <= 32 bytes each | `` |
| PASS | btree | compare(): prefix <= 0 (shorter length wins) | `` |
| PASS | btree | compare(): first differing byte decides | `` |
| PASS | btree | text search "nakadashi" | `offset=427278028 len=1148736 ids=287183 (1148736/1148736 bytes) galleries/4360494.js -> 200` |
| PASS | btree | text search "big breasts" | `offset=1671732016 len=8 ids=1 (8/8 bytes) galleries/2783561.js -> 200` |
| PASS | btree | text search "1girl" | `offset=1658322540 len=8 ids=1 (8/8 bytes) galleries/2738654.js -> 200` |
| PASS | btree | unknown term resolves to nothing | `None` |
| PASS | btree | every single-word tag resolves to a big id list | `{'glasses': 143944, 'stockings': 233174, 'nakadashi': 287183, 'ahegao': 147449, 'tomgirl': 41458, 'kemonomimi': 77800}` |
| PASS | btree | multi-word tags are not served by the b-tree (use namespace:tag) | `{'big breasts': 1, 'sole female': 0, 'school uniform': 0, 'very long hair': 0}` |
| PASS | btree | hashTerm is case sensitive (Kotlin lowercases the query first) | `Glasses -> none, glasses -> ids` |
| PASS | suggest | global:"big" | `10 entries https://tagindex.hitomi.la/global/b/i/g.json first=['big breasts', 477114, 'female']` |
| PASS | suggest | global:"big" -> [tag, count, namespace] | `sample=['big breasts', 477114, 'female']` |
| PASS | suggest | female:"big breasts" | `1 entries https://tagindex.hitomi.la/female/b/i/g/_/b/r/e/a/s/t/s.json first=['big breasts', 477114, 'female']` |
| PASS | suggest | female:"big breasts" -> [tag, count, namespace] | `sample=['big breasts', 477114, 'female']` |
| PASS | suggest | global:"nakadashi" | `2 entries https://tagindex.hitomi.la/global/n/a/k/a/d/a/s/h/i.json first=['nakadashi', 270776, 'female']` |
| PASS | suggest | global:"nakadashi" -> [tag, count, namespace] | `sample=['nakadashi', 270776, 'female']` |
| PASS | suggest | japanese term is percent-encoded | `https://tagindex.hitomi.la/global/%E5%B7%A8/%E4%B9%B3.json` |
| PASS | suggest | japanese term answers 404 (tag index is english-only) | `404 text/html; charset=UTF-8 556` |
| PASS | suggest | empty term -> /global.json | `https://tagindex.hitomi.la/global.json` |
| PASS | suggest | space -> '_' | `https://tagindex.hitomi.la/global/b/i/g/_/b/r/e/a/s/t/s.json` |
| PASS | suggest | slash -> 'slash' | `https://tagindex.hitomi.la/global/a/slash/b.json` |
| PASS | suggest | dot -> 'dot' | `https://tagindex.hitomi.la/global/a/dot/b.json` |
| PASS | query | fromQuery("female:big breasts") | `('tag', 'female:big breasts', 'all')` |
| PASS | query | fromQuery("male:sole male") | `('tag', 'male:sole male', 'all')` |
| PASS | query | fromQuery("language:japanese") | `('all', 'index', 'japanese')` |
| PASS | query | fromQuery("artist:fukudahda") | `('artist', 'fukudahda', 'all')` |
| PASS | query | fromQuery("group:nekono matsuri") | `('group', 'nekono matsuri', 'all')` |
| PASS | query | female: tag nozomi resolves | `206 https://ltn.gold-usergeneratedcontent.net/n/tag/female:big%20breasts-all.nozomi` |
| PASS | query | space is %20 in the path, not a raw space | `https://ltn.gold-usergeneratedcontent.net/n/tag/female:big%20breasts-all.nozomi` |
| PASS | query | language: resolves to the index file | `206 https://ltn.gold-usergeneratedcontent.net/n/index-japanese.nozomi` |
| PASS | sources | HitomiEndpoint.domain matches | `swift='ltn.gold-usergeneratedcontent.net' probe='ltn.gold-usergeneratedcontent.net'` |
| PASS | sources | HitomiEndpoint.tagIndexDomain matches | `swift='tagindex.hitomi.la'` |
| PASS | sources | HitomiEndpoint.imageHost matches | `swift='gold-usergeneratedcontent.net'` |
| PASS | sources | HitomiEndpoint.nozomiExtension matches | `swift='.nozomi'` |
| PASS | sources | HitomiEndpoint.maxNodeSize matches | `swift=464` |
| PASS | sources | HitomiEndpoint.bTreeOrder matches | `swift=16` |
| PASS | sources | HitomiEndpoint.referer matches | `https://hitomi.la/` |
| PASS | sources | HitomiEndpoint.userAgent matches | `Mozilla/5.0 (Windows NT 10.0; Win64; x64` |
| PASS | sources | protocol/store layer does not reference the design system | `clean` |
