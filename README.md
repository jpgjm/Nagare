# Nagare

アニメをトレントからストリーミング再生する iOS / iPadOS アプリです。
[Shiru](https://github.com/RockinChaos/Shiru)（Svelte / Electron / Capacitor 製）の設計と拡張機能の仕組みを元に、SwiftUI で書き直しています。

- **作品を探す**: AniList をログインなしで検索し、作品と話数を選ぶ
- **トレントを探す**: Shiru 互換の拡張機能（ユーザーが追加するソース）で検索
- **その場で再生**: libtorrent で必要な部分から順に取得し、mpv で再生（MKV / ASS 字幕 / HEVC など）
- **ログ**: 重要度付きのログをアプリ内で閲覧・書き出し

| 項目 | 値 |
|---|---|
| バージョン | 1.0.4 (5) |
| 対応 OS | iOS / iPadOS 26.0 以上（iPhone / iPad） |
| ビルド | GitHub Actions（Mac 不要）+ XcodeGen |
| 配布 | SideStore（無料 Personal Team） |

拡張機能（トレントのソース）は同梱していません。

## ドキュメント

- [docs/BUILD_AND_INSTALL.md](docs/BUILD_AND_INSTALL.md) — ビルドとインストール
- [docs/TESTING.md](docs/TESTING.md) — 動作確認の手順
- [docs/DESIGN.md](docs/DESIGN.md) — 構成・Shiru との対応・既知の制限
- [docs/LICENSES.md](docs/LICENSES.md) — ライセンス
- [docs/CHANGELOG.md](docs/CHANGELOG.md) — 変更履歴

## ライセンス

GPL-3.0-or-later（Shiru の派生物のため）。全文は [docs/LICENSE-GPL-3.0.txt](docs/LICENSE-GPL-3.0.txt)。
