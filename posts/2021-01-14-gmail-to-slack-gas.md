---
title: "GAS で Gmail の通知メールを Slack に転送する"
date: "2021-01-14"
tags:
  - Gmail
  - Slack
  - Google Apps Script
  - TypeScript
  - Cloud Logging
---

監視している機器やサービスのなかには, 障害や状態の変化をメールでしか通知しないものがあります.
メールボックスを常に開くわけにはいかないので, 通知に気づくのが遅れます.
そこで, 条件に合う Gmail の通知メールを Slack のチャンネルに転送する仕組みを作りました.

## GAS とポーリング

[![Google Apps Script の公式ページ](https://lh3.googleusercontent.com/w0vOEA6oQj_rvcnP8SipWw4_gz5e_RH2La5ZEx4rHVvaoL4PSqLDeE5y7uSgAVMHNE6LaSIm_DOQZiWKXHgGYbbzbBKbHBiHGNTDAw=e365-pa-nu-rw-w1024)](https://workspace.google.com/products/apps-script/)

時間主導のトリガーで 1 分ごとに Gmail を検索し, 一致する未読メールを Slack に投稿します.
投稿したスレッドは既読にし, その Message-ID を Cloud Logging に記録します.

![Gmail の検索から Slack への投稿, 既読化, Cloud Logging までの流れ](/images/2021-01-14-gmail-to-slack-flow.svg)

図は, 1 分ごとのトリガーから Slack への投稿, 既読化, Cloud Logging までの流れを示しています.

Gmail の検索と Slack への投稿は Google Apps Script（GAS）で行います.
サーバを用意せず, トリガーだけで動かせます.

GAS は Google の環境で動き, `GmailApp` からメールを検索し, `UrlFetchApp` から Slack に HTTP を送れます.
スクリプトは実行ユーザーの Gmail 権限で動くため, Gmail API の OAuth クライアントやトークンを別に管理する必要がありません.
その代わり, 実行ユーザーが読めるメールが対象になり, 要求するスコープも広くなります.
既読化に `gmail.modify` を使うため, 読み取りだけの `gmail.readonly` より権限は広くなります.

未読メールを検索する**ポーリング**で通知を拾います.
Slack には通常 1 分以内に届きます.
トリガーの起動は Google 側の都合で遅れることがあります.

## Gmail の検索と未読キュー

トリガーは `handler` を呼びます.
`handler` は検索条件で Gmail を検索し, 見つかった**スレッド**（同じ会話としてまとめられたメールの並び）の各メッセージを Slack に投稿します.
投稿が終わったスレッドは既読にします.

`src/main.ts` の抜粋です.

```ts
export const handler = () => {
  const result = GmailApp.search(GMAIL_SEARCH_TARGET).reverse()
  result.forEach((thread) => {
    thread.getMessages().forEach((message) => send(message))
    thread.markRead()
  })
}
```

`GMAIL_SEARCH_TARGET` は次の節, `send` は Slack への投稿の節で説明します.

`GmailApp.search` はメッセージ単位ではなくスレッド単位で検索するため, 検索条件に一致するメッセージが 1 つでもあると, そのスレッドの全メッセージが投稿対象になります.

![未読のスレッドを選び, スレッド内の全メッセージを投稿する流れ](/images/2021-01-14-gmail-to-slack-queue.svg)

図は, スレッド A の A1 と A2, スレッド B の B1 を例にしています.

検索条件には `is:unread` を含めます.
すると, 未読のスレッドだけが次回の検索対象になります.
Slack への投稿が終わったスレッドを既読にすれば, 未読状態が処理済みの印になります.
データベースやカーソルを別に持たなくても, Gmail がキューの状態を保持します.

この仕組みでは, 検索条件と既読化が対になっています.
検索条件から `is:unread` を外すと, 既読のメールも毎回検索され, 同じ投稿が繰り返されます.
既読化を外すと, 同じメールが 1 分ごとに Slack へ流れます.
検索条件を変えるときは, `is:unread` を残しているか確認します.

この実装では, `GmailApp.search` が新しいスレッドから返す前提で, `reverse()` でスレッドを古い順に並べ替えています.
そのまま投稿すると Slack では新しい通知が先に流れるからです.
手元の Gmail ではスレッド内のメッセージも古い順に返るため, スレッド内では時系列に投稿されます.
スレッドをまたぐと, あるスレッドの新しいメッセージが, 別のスレッドの古いメッセージより後に投稿されることがあります.

## Gmail の検索条件

検索条件は Script Properties の `GMAIL_SEARCH_TARGET` に置きます.
コードに書くと, 検索条件を変えるたびにデプロイが必要になります.

検索条件は Gmail の検索ボックスにそのまま貼って確認できます.
監視通知の送信元だけを対象にするなら, 次のようにします.

```text
is:unread from:alerts@example.com
```

件名で絞るなら `subject:` を足します.
検索条件を広げると, 一致したメールの本文がそのまま Slack に流れます.
監視通知の送信元だけに絞るなど, 対象を狭くしておきます.

## Slack への投稿

[![Slack の公式ページ](https://a.slack-edge.com/73a2348/marketing/img/homepage/revamped-24/unfurl/hp-revamp-unfurl.ja-JP.jpg)](https://slack.com/)

Slack へは **Incoming Webhook**（チャンネルに投稿するための URL）に JSON を POST します.
1 チャンネルに投稿するだけなら, Slack アプリの OAuth を設定して `chat.postMessage` を呼ぶより簡単です.

メッセージは `attachments` の 1 要素として組み立て, 件名, 送信者, 本文, Gmail へのリンクを入れます.
主要なフィールドだけを示します.

```ts
const payload = {
  attachments: [{
    fallback: message.getSubject(),
    color: getColorBasedOnTitle(message),
    author_name: message.getFrom(),
    title: message.getSubject(),
    title_link:
      "https://mail.google.com/mail/u/0/#search/rfc822msgid:" +
      message.getHeader("Message-ID"),
    text: message.getPlainBody(),
    ts: Date.parse(
      Utilities.formatDate(message.getDate(), "GMT", "dd MMM yyyy HH:mm:ss z")
    ) / 1000,
  }],
}
```

`color` は Slack のメッセージ左側のバーに反映されます.
値は件名で決めます.
既知の件名を `good` と `warning` に分け, どちらにも一致しなければ `danger` にしています.
`good` や `warning` の一覧に追加し忘れると `danger` になりますが, 異常を見落とすよりは目立つほうがよいと判断しました.
件名は完全一致で判定するため, ファームウェアの更新などで件名が変わると, その通知が `danger` になります.
そのときは一覧を更新します.

`title_link` は, Gmail のスレッド ID ではなく Message-ID を使った検索 URL にしています.
Message-ID はメールを一意に指すため, 転送したメールを Slack から辿れます.
URL の `u/0` は Gmail のアカウント番号なので, 複数アカウントを使い分けている場合は対象に合わせます.

`ts` にはメールの日時を入れています.
投稿時刻を入れると, 過去のメールをまとめて転送したときに, すべて投稿した時刻に揃ってしまいます.

## Cloud Logging への記録

### ログの形式

GAS の実行ログは, エディタの Executions パネルで直近の実行を確認するには便利ですが, 転送したメールを後から検索する用途には向きません.
そこで, 投稿したメールの Message-ID などを Cloud Logging に構造化ログとして書いています.

```ts
const payload = {
  entries: [{
    logName: `projects/${SERVICE_ACCOUNT_KEY.project_id}/logs/${ScriptApp.getScriptId()}`,
    resource: { type: "global" },
    severity: "INFO",
    jsonPayload: {
      serviceName: "google-apps-script",
      message: logMessage,
    },
  }],
}
```

`logName` に Script ID を入れると, 同じ Google Cloud（GCP）プロジェクト内の他の GAS のログと混ざりません.
`jsonPayload` にすると, Message-ID などで検索できます.

### サービスアカウント

書き込みにはサービスアカウントを使います.
GAS のプロジェクト設定で標準の GCP プロジェクトを関連付け, そのプロジェクトにサービスアカウントを作ります.
サービスアカウントには `roles/logging.logWriter` を付け, JSON キーを発行します.
キーの JSON は `SERVICE_ACCOUNT_KEY` にそのまま保存します.
OAuth2 ライブラリ（OAuth2 for Apps Script）が秘密鍵で JWT（JSON Web Token）を署名し, アクセストークンに交換します.

Cloud Logging 用の認可をユーザーの OAuth クライアントで取る方法もあります.
ただし, 同意画面を外部ユーザー種別の Testing のままにすると, 更新トークンが 7 日で切れます.
サービスアカウントの鍵なら, 7 日で切れることはありません.
鍵は長期間有効なので, 漏らさない管理と, 必要ならローテーションが要ります.
ユーザーの OAuth クライアントを公開状態で運用できるなら, サービスアカウントを使う必要はありません.

スコープは `cloud-platform` ですが, サービスアカウントに付ける IAM ロールは `roles/logging.logWriter` だけにします.
スコープが広くても, 実際に許可される操作はロールで絞られます.

## 設定値

検索条件, Webhook URL, サービスアカウントキーは **Script Properties**（GAS のプロジェクトに保存できるキーと値の組）に置きます.
コードに書くと, 秘密情報がリポジトリに入ります.
Script Properties なら, 画面から値を変えるだけで次の実行から反映されます.

| プロパティ | 用途 |
| --- | --- |
| `GMAIL_SEARCH_TARGET` | 転送対象の Gmail 検索条件 |
| `SLACK_INCOMING_WEB_HOOK_URL` | Slack の Incoming Webhook URL |
| `SERVICE_ACCOUNT_KEY` | Cloud Logging 用サービスアカウントの JSON キー |

コードは実行のたびに 3 つとも読み, 欠けていれば例外を投げます.
設定漏れのまま動いて通知が届かない状態になるより, 実行を失敗させたほうが早く気づけます.

Script Properties は GAS プロジェクトの編集者から見えるため, 編集権限を絞ります.

## ビルドとデプロイ

GAS のエディタは JavaScript を実行します.
型のあるコードを書き, 依存を npm で管理するために, TypeScript で書いて esbuild で 1 ファイルにまとめています.

GAS の V8 ランタイムはモダンな JavaScript を実行できますが, ES モジュールは使えません.
トリガーから見えるグローバル関数にする必要があるため, IIFE（即時実行関数式）にバンドルし, 末尾で export をグローバルにコピーします.

```js
const buildOptions = {
  entryPoints: ["src/main.ts"],
  bundle: true,
  outfile: "dist/main.js",
  format: "iife",
  globalName: "GasTemporaryExports",
  footer: {
    js: "for (const key in GasTemporaryExports) { " +
        "if (Object.prototype.hasOwnProperty.call(GasTemporaryExports, key)) { " +
        "this[key] = GasTemporaryExports[key]; } }",
  },
  define: { global: "globalThis" },
}
```

`globalName` でバンドル結果を一時的なオブジェクトに受け, `footer` でそのプロパティをグローバルに移します.
これで `handler` が GAS のグローバル関数として見えます.

GAS には Node の `global` がないため, ソース中の `global` を `define` で `globalThis` に置き換えます.
ソースでは `global.handler = handler` と書いています.

`src/appsscript.json` には, OAuth2 ライブラリの依存と実行に必要なスコープを書いています.
ビルドで `dist/` にコピーします.
`clasp clone` の後, `.clasp.json` の `rootDir` を `./dist` に設定します.
`clasp push` はビルド結果だけをアップロードします.
`dist/` と `.clasp.json` は Git の管理外です.
`.clasp.json` には Script ID が入り, 環境ごとに異なるためです.

デプロイの手順は次のとおりです.

```console
nix develop
npm install
npx clasp login
npx clasp clone <SCRIPT_ID>
npm run build
npx clasp push
```

初回だけ `clasp clone` で既存のプロジェクトを取得します.
`clasp pull` は `dist/` に書き込むため, TypeScript のソースは更新されません.
GAS の画面で変更した場合は, その内容を `src/main.ts` に反映します.
ローカルで編集したときは, そのままビルドして push します.

## References

- [Gmail の検索演算子](https://support.google.com/mail/answer/7190?hl=ja)
- [RFC 5322: Message-ID](https://www.rfc-editor.org/rfc/rfc5322#section-3.6.4)
- [Slack Incoming Webhooks](https://api.slack.com/messaging/webhooks)
- [Slack の attachments](https://api.slack.com/reference/messaging/attachments)
- [Cloud Logging へのログの書き込み](https://cloud.google.com/logging/docs/reference/v2/rest/v2/entries/write)
- [OAuth2 for Apps Script](https://github.com/googleworkspace/apps-script-oauth2)
- [clasp](https://github.com/google/clasp)
- [esbuild](https://esbuild.github.io/)
