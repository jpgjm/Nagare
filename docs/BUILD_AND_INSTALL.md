# ビルドとインストール

## 1. リポジトリに置く

ZIP の中の `Nagare_Project/` の**中身**をそのまま GitHub リポジトリのルートにします。

```
.github/workflows/build-ipa.yml
.gitignore
project.yml
README.md
docs/
Source/
Resources/
```

`*.xcodeproj` はコミットしません（ワークフローが XcodeGen で生成します）。

## 2. GitHub Actions でビルド

`main`（または `master`）へ push するか、Actions タブから **Build iOS IPA** を手動実行します。

成果物は 3 つです。

| 成果物 | 中身 |
|---|---|
| `…_ipa` | インストールする IPA |
| `…_xcodebuild-log` | ビルドのログ。**どのステップで失敗しても上がる**（失敗時はこれを添付してください。末尾の `===== [ステップ名] =====` が止まった場所） |
| `…_Repository` | ビルドしたソースのスナップショット |

### 初回ビルドについて

- Swift Package（LibtorrentKit / MPVKit）のバイナリを合計で数百 MB ダウンロードするため、初回は時間がかかります。
- ビルドログの末尾付近に次の行が出ます。動作確認の手がかりになるので、失敗・不具合の報告時は一緒に見てください。
  - `[Nagare] OK: OpenSSL.framework は埋め込み済み`（または補った旨）
  - `[Nagare] OpenSSL シンボルの結び付き:` の下の `nm` の結果
    - `(undefined) external _SSL_CTX_new (from OpenSSL)` … libtorrent は OpenSSL.framework を使っている（想定どおり）
    - `(__TEXT,__text) external _SSL_CTX_new` … MPVKit 側の OpenSSL（静的）に結び付いている（[DESIGN.md](DESIGN.md) の「OpenSSL の重複」を参照）

## 3. SideStore でインストール

1. `…_ipa` の ZIP を展開して `.ipa` を iPad / iPhone に置く
2. SideStore で `.ipa` をインストール
3. 7 日ごとに SideStore で再署名（無料 Personal Team の制約）

- App Extension は無いので App ID は 1 つだけ使います。
- 有料アカウント専用の entitlement（Push / iCloud など）は使っていません。
- Bundle ID は `com.anony.nagare` ですが、SideStore がチーム ID を付けて書き換えます。アプリ内の「設定 → 診断 → Bundle ID（実行時）」で実際の値を確認できます。

## 4. 初回起動時

- **ローカルネットワークの許可**を求められることがあります（NAT-PMP によるポート開放のため）。拒否してもダウンロードはできますが、接続できるピアが減ることがあります。設定で NAT-PMP を切れば聞かれません。

## 5. このバージョンの検証方法

v1.0.0 は初回版です。`Info.plist` のうち installd がキャッシュする項目（`BGTaskSchedulerPermittedIdentifiers` など）は使っていないので、今後の版も特記が無い限り**上書きインストール**で検証できます。
