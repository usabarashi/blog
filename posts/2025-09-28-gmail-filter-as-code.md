---
title: "Gmail のフィルタを gmailctl で管理する"
date: "2025-09-28"
tags:
  - Gmail
  - Jsonnet
  - Nix
---

これまでは, Gmail の設定画面でフィルタを 1 件ずつ作り, 変更の履歴を残していませんでした.
受信するメールの種類が増えると, どのフィルタがどのメールに効いているかを画面から追うことになります.
フィルタとラベルの定義を, バージョン管理できるファイルに移し, **gmailctl** で Gmail に反映するようにしました.

[![mbrt/gmailctl のリポジトリカード](https://opengraph.githubassets.com/676825f4a8c1ecc30d61ef09672cea078d6b05219a5560e6e090d729966b57c3/mbrt/gmailctl)](https://github.com/mbrt/gmailctl)

## gmailctl のコマンド

gmailctl は, ローカルの設定ファイルと Gmail の設定を突き合わせて, 差分を反映するツールです.
使うのは次の 3 つです.

- **download**：Gmail にあるフィルタを設定ファイルの形で書き出す
- **diff**：ローカルの設定と Gmail の設定の差分を表示する
- **apply**：差分を Gmail に反映する

`apply` は, 足りないフィルタとラベルを追加し, ローカルの設定にないフィルタを Gmail から削除します.
フィルタについては, ローカルの設定が正で, Gmail 側はそれに合わせる扱いです.

`diff` で差分を確認してから `apply` を実行する流れは, Terraform の `plan` と `apply` に近い操作感です.
適用する前に, 何が追加され, 何が削除されるかを確認できます.

## 設定ディレクトリをリポジトリに置く

リポジトリの `gmail/` に flake と設定ファイルを置き, `nix develop` で gmailctl を入れています.
gmailctl が設定ファイルを探すディレクトリの既定は `$HOME/.gmailctl` です.
リポジトリの中を指すように, dev shell でラッパーを用意しています.

```nix
gmailctlWrapped = pkgs.writeShellScriptBin "gmailctl" ''
  set -euo pipefail

  exec ${pkgs.gmailctl}/bin/gmailctl --config "$(pwd)" "$@"
'';
```

設定ファイルと認証情報が同じディレクトリに揃い, gmailctl のバージョンは `flake.lock` で固定できます.
`--config` に渡るのはコマンドを実行したときの作業ディレクトリなので, コマンドは `gmail/` の中で実行します.

## OAuth クライアントとトークン

Gmail の設定を操作するには OAuth の認可が要ります.
Google Cloud のプロジェクトで Gmail API を有効にし, OAuth クライアント（種類はデスクトップ アプリ）を作り, クライアントの JSON を `credentials.json` として `gmail/` に置きます.

初回は `gmailctl init --refresh-expired` を実行し, ブラウザで認可します.
認可で得たトークンは同じディレクトリの `token.json` に保存されます.
`credentials.json` と `token.json` は `.gitignore` に入れています.

要求するスコープは `gmail.labels` と `gmail.settings.basic` の 2 つです.
フィルタとラベルの読み書きに必要な範囲で, メールの本文を読む権限は含みません.

同意画面は外部ユーザー種別のまま, 公開状態を Testing にしています.
この状態の更新トークンは発行から 7 日で切れます（[Google のドキュメント](https://developers.google.com/identity/protocols/oauth2#expiration)）.
切れると `invalid_grant` で失敗するので, そのときは `gmailctl init --refresh-expired` を実行し直します.
Testing のあいだは, 認可に使うアカウントをテストユーザーとして登録しておく必要があります.

## 既存のフィルタの取り込み

gmailctl を入れた直後に, `gmailctl download` で既存のフィルタを書き出しました.

```sh
gmailctl download > config.jsonnet
```

`download` は実験的な機能で, 出力も整形されません.
書き出した直後に `gmailctl diff` を実行し, 差分が出ないことを確認してから編集を始めます.
差分が残ったまま編集すると, 取り込みのずれと自分の変更を区別できなくなります.

Gmail から書き出したラベルは, 深さも接頭辞も揃っていないことがあります.
「News」「Shopping/Amazon」「Books/Technical」が混在していると, 同じ分類のラベルが同じ階層に並ばず, 一覧から分類を読み取りにくくなります.
そこで, 分類を決めて, すべてのラベルを「分類/名前」の 2 階層に揃えます.

ラベルは `Assets/銀行` のように `/` で階層を表します.
一覧は設定ファイルの `labels` に書き, ルールの `actions.labels` から名前で参照します.
色は `color` で指定できます.

## ルールの書き方

条件は `from` や `subject` などの項目を並べるほか, `and`, `or`, `not` で組み合わせられます.
送信元が複数あるものは `or` で並べます.
設定オブジェクトの `labels` と `rules` に, 次のように書きます.

```jsonnet
labels: [
  { name: 'Shopping/Order' },
],
rules: [
  {
    filter: {
      or: [
        { from: '@shop.example' },
        { from: '@store.example' },
      ],
    },
    actions: {
      labels: ['Shopping/Order'],
    },
  },
]
```

`from` などで表せない条件は, `query` に Gmail の検索式をそのまま書けます.
次のルールは, 自分宛に届く請求書を拾うために, 送信元, 宛先, 検索語を `and` で組み合わせています.
これは `rules` に追加する要素で, `Assets/Payment` は `labels` に定義しておきます.

```jsonnet
{
  filter: {
    and: [
      { from: 'billing@shop.example' },
      { to: 'you@example.com' },
      { query: 'invoice' },
    ],
  },
  actions: {
    labels: ['Assets/Payment'],
  },
}
```

`gmailctl debug` を使うと, 各ルールを Gmail の検索クエリに変換した結果を確認できます.
上のルールは, `from:billing@shop.example to:you@example.com invoice` という検索になります.
出力には Gmail の検索 URL も付くので, その条件で実際にどのメールが拾われるかをブラウザで確かめられます.

## 変更の反映

変更は, 設定ファイルを編集し, `diff` で内容を確認し, `apply` で反映する順に進めます.

```sh
gmailctl diff
gmailctl apply
```

Gmail の設定画面から直接フィルタを編集すると, その変更は設定ファイルに現れません.
次に `diff` を実行したときに, 身に覚えのない差分として出てきます.
変更は設定ファイル経由に揃え, 適用後に `diff` が空になることを確認します.

ラベルの削除だけは, 既定では行われません.
`apply --remove-labels` を付けたときだけ, ローカルの設定にないラベルが Gmail から削除されます.
そのラベルを参照するルールが残っているあいだは, gmailctl が削除を拒否します.
また, Gmail でラベルを削除すると, そのラベルが付いていたメールからもラベルが外れます.

設定ファイルが読めたことは, すべてのルールが反映されることを意味しません.
ルールのオブジェクトのあいだのカンマを落としても, エラーにならずに 2 つのルールが 1 つにまとめられることがあります.
その場合, 同じ名前のフィールドは後の値で上書きされ, 前のルールは独立したルールとして残りません.
`debug` の出力で, 変更した箇所の前後のルールがそれぞれ残っているかを確認すると, この取りこぼしに気づけます.

既存のルールに送信元を足すのは 1 行の差分です.
適用したあとに `diff` が空になれば, 反映は済んでいます.

## References

- [mbrt/gmailctl](https://github.com/mbrt/gmailctl)
- [Jsonnet](https://jsonnet.org/)
- [Gmail API](https://developers.google.com/workspace/gmail/api/guides)
- [Gmail search operators](https://support.google.com/mail/answer/7190?hl=en)
- [Google Identity: OAuth 2.0](https://developers.google.com/identity/protocols/oauth2#expiration)
