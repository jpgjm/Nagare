# ライセンス

## Nagare

GPL-3.0-or-later。全文は [LICENSE-GPL-3.0.txt](LICENSE-GPL-3.0.txt)。

Nagare は [Shiru](https://github.com/RockinChaos/Shiru)（GPL-3.0-or-later）の次の部分を Swift / JavaScript に移植しており、その派生物です。

- 拡張機能マニフェストの検証・URL 解決・コード取得（`common/modules/extensions/manager.js`）
- 拡張機能の実行（`common/modules/extensions/worker.js`）
- 拡張機能へ渡すクエリの組み立て（`common/modules/extensions/handler.js`、`common/modules/anime/anidbmapping.js` 相当）
- 検索用タイトルの生成（`createTitles`）、最大話数の計算（`getMediaMaxEp`）

## 使用しているライブラリ

| ライブラリ | ライセンス | 備考 |
|---|---|---|
| [LibtorrentKit](https://github.com/WhoSayIn/LibtorrentKit) 0.5.2 | BSD-3-Clause | libtorrent（BSD-3-Clause）、Boost（BSL-1.0）、OpenSSL（Apache-2.0、krzyzanowskim/OpenSSL 配布の xcframework）を含む |
| [MPVKit](https://github.com/mpvkit/MPVKit) 1.0.0（LGPL 版） | LGPL | mpv、FFmpeg、libass、libplacebo、MoltenVK ほか。各ライブラリの条件は MPVKit のリポジトリを参照 |
| Mozilla CA 証明書バンドル（curl.se 配布、2026-08-13） | MPL-2.0 | libtorrent の HTTPS 接続用 |

## 外部サービス

- [AniList](https://anilist.co) GraphQL API（作品情報）
- [ani.zip](https://api.ani.zip) API（AniDB / TVDB などとの対応表）
- [esm.sh](https://esm.sh)（`gh:` / `npm:` 形式の拡張機能の取得）

## テスト用コンテンツ

「設定 → 動作確認 → テスト再生」は Blender Foundation の *Sintel*（© Blender Foundation, CC BY 3.0, https://durian.blender.org）を webtorrent.io が配布しているトレントで再生します。
