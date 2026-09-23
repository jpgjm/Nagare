# 構成と設計

## 方針

Shiru は UI が Svelte、トレントが Node.js 上の WebTorrent、Android 版は Capacitor + nodejs-mobile という構成で、iOS 版はありません。
iOS では Node.js をアプリ内で動かせず、WebTorrent（ブラウザ版）は WebRTC のピアにしかつながらないため、そのまま移植しても一般的なトレントを再生できません。
そこで Nagare は **SwiftUI でネイティブに書き直し**、段階的に機能を増やします。

| 役割 | Shiru | Nagare |
|---|---|---|
| UI | Svelte 4 | SwiftUI |
| トレント | WebTorrent（Node.js） | libtorrent 2.1（LibtorrentKit） |
| ストリーミング | WebTorrent 内蔵 HTTP サーバ | 自前のループバック HTTP サーバ（Network.framework） |
| プレイヤー | `<video>` / 外部プレイヤー | mpv（MPVKit, Metal + MoltenVK） |
| 拡張機能の実行 | Web Worker（Comlink） | 隠し WKWebView |
| 拡張の fetch | ブラウザ（Android は CapacitorHttp） | ネイティブ（URLSession）へ中継 |
| 作品情報 | AniList（ログインあり） | AniList（ログインなし・検索のみ） |

## 初版（1.0.0）の範囲

- AniList をログインなしで検索 → 作品と話数を選ぶ
- 有効な拡張機能すべてでトレントを検索 → 結果を 1 つ選ぶ
- その場でストリーミング再生（シーク・字幕／音声トラック切替・速度・OP/ED スキップ）
- 重要度付きログの閲覧・書き出し

AniList 連携（ログイン・リスト管理・視聴進捗の記録）は次の段階で入れます。

## ソース構成

```
Source/
  App/          起動・タブ・画面遷移（PlaybackCoordinator）・再生準備画面
  AniList/      AniList GraphQL、ani.zip の対応表
  Search/       作品検索・詳細・トレント検索結果・拡張へのクエリ組み立て（QueryBuilder）
  Extensions/   拡張機能の追加・保存・読み込み、WKWebView ランタイム
  Torrent/      libtorrent セッション、ストリーミング（StreamSource / StreamServer）、一覧画面
  Player/       mpv のラッパ（MPVCore）とプレイヤー画面
  Background/   無音再生によるバックグラウンド継続
  Settings/     設定・動作確認・診断
  Logging/      ログ（AppLog / qlog）とログ画面
  Common/       JSON 値、書式、実行時情報、設定キー
Resources/Bundle/
  extension-host.html   拡張機能ランタイム（JS）
  cacert-2026-08-13.pem libtorrent の HTTPS トラッカー用 CA バンドル（Mozilla, curl.se 配布）
  Assets.xcassets       アプリアイコン
```

## 再生までの流れ

1. **QueryBuilder** が AniList の作品情報と ani.zip の対応表から Shiru と同じ形の `TorrentQuery` を作る（`titles`・`episode`・`anidbAid`・`anidbEid`・`tvdbAid` など）
2. **ExtensionHost**（隠し WKWebView）で各拡張の `single()`（必要なら `batch()`・`movie()`）を呼ぶ。拡張内の `fetch` はネイティブへ中継されるので CORS の制約を受けない
3. 結果を infohash で重複除去して一覧にする
4. 選んだ結果を **TorrentEngine** が libtorrent に追加。`.torrent` の URL ならネイティブで取得し、失敗したら infohash から magnet を作って DHT で探す
5. メタデータ取得後、動画ファイルが 1 つならそれを、複数なら話数に合うものを自動で選ぶ（決まらなければ一覧から選ぶ）
6. **StreamServer**（127.0.0.1 のみで待ち受け）が `http://127.0.0.1:<port>/stream/<ID>/<ファイル名>` を提供。Range 要求を受けると **StreamSource** が該当ピースの到着を待ってから返す。読み位置が飛ぶと libtorrent のストリーミング窓（優先ピース）を読み位置へ移す
7. mpv がその URL を再生する（`network-timeout=0` でピース待ちでも切らない）

## 拡張機能

Shiru の拡張機能（`export default new class extends AbstractSource { single / batch / movie / validate }`）をそのまま読み込みます。

- マニフェストの形式・`gh:` / `npm:` の解決（esm.sh 経由）・`update` / `main` の相対パス解決・設定項目（text / toggle / dropdown / multiselect）は Shiru と同じ規則
- `import` の相対指定（`./x`、`/x`）は取得元 URL を基準に絶対 URL へ書き換えてから Blob URL で `import()` する
- リポジトリ一覧（`main` だけのエントリの配列）を追加すると、エントリごとに「追加」できる
- 保存先: `Application Support/Nagare/extensions.json`、コードのキャッシュ: `Caches/Nagare/ExtensionCode/`

### Shiru と同じ動きにしている点（拡張機能の結果を再生するため）

- **既定トラッカーの付加**: Shiru はすべてのトレントに既定のトラッカー一覧（`common/modules/util.js` の `trackers`）を付けて追加します。TsukiHime はトラッカー無しの magnet、SeaDex は infohash だけを返すので、これが無いと DHT だけでピアを探すことになります。Nagare は magnet に同じ一覧のうち libtorrent で使えるもの（udp / http / https、wss は除く）を付けます。
- **infohash だけのリンク**: 40 桁の 16 進数（または 32 桁の base32）なら magnet に変換します。
- **IndexedDB**: nekoBT / TsukiHime はモジュールの先頭で IndexedDB を開きます。WKWebView で使えなかった場合はメモリ上の代替に切り替えます（キャッシュがアプリ終了で消えるだけで、検索には影響しません）。
- **statusText**: 拡張の `fetch` の応答は英語の定型句を返します（端末の言語の文言を渡すと WebKit の `Response` が例外を出し、すべての通信が失敗するため）。
- **バッチ内の話の選択**: `S01E05`・`E05`・` - 05`・`[05]`・`第5話` などの強い一致を先に、単独の数字を次に試します。ノンクレ OP/ED・PV・特典は候補から外します。話数で決まらなければ ani.zip の通し番号でも試します。

## 保存場所

| 内容 | 場所 |
|---|---|
| ダウンロードしたファイル | `Documents/Torrents/<infohash>/`（「ファイル」アプリから見える） |
| ログ | `Documents/Logs/nagare-<日付>.log` |
| 拡張機能の登録と設定 | `Application Support/Nagare/extensions.json` |
| 設定 | `UserDefaults` |

## 既知の制限（1.0.1）

- **トレント一覧はアプリ終了で消えます**（再開用データを保存していません）。ファイルは残り、同じトレントを開き直すとファイルを検査してから続きを取得します。
- **拡張機能に `anitomyscript` を渡していません**。これを使う拡張は失敗することがあります（Spithskia/Shiru-Extensions の 7 件は使っていません）。
- 検索結果の**ピア数を自前で問い合わせていません**（拡張が返した値をそのまま表示）。
- 話数の対応付け（AniList と AniDB の話数がずれる場合）は、ゼロ話の補正を省いた簡易版です。
- ダウンロード済みファイルの一覧・ローカルファイルの再生、ピクチャ・イン・ピクチャ、AniList ログインは未対応です。
- LSD と UPnP は無効です（マルチキャストには無料アカウントで使えない entitlement が必要なため）。
- ローカルファイル（`file:` / `extension:`）の拡張機能ソースは未対応です。

### OpenSSL の重複

LibtorrentKit は OpenSSL 3.6（動的フレームワーク）を、MPVKit は OpenSSL 3.3（静的ライブラリ）をそれぞれ含みます。
リンク時に libtorrent 側の OpenSSL 参照がどちらに結び付くかはリンク順で決まるため、ビルドログ（`[Nagare] OpenSSL シンボルの結び付き`）とアプリの「設定 → 診断」に結果を出しています。
libtorrent が OpenSSL を使うのは HTTPS トラッカーなどに限られ、infohash の計算には使いません。HTTPS トラッカーへの接続でだけ問題が出る場合はこれが原因の候補です。
