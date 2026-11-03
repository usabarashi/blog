---
title: "Gemini Nano で X のタイムラインフィルタを作った"
date: "2026-01-02"
tags:
  - Chrome
  - Gemini Nano
  - PureScript
  - WebExtensions
---

X（旧 Twitter）のタイムラインから攻撃的なポストを取り除きたいと考えました.
キーワードや固定ルールだけでは文脈を踏まえた判定が難しいため, Chrome に組み込まれた Gemini Nano を端末内で動かす Chrome 拡張を作りました.
条件に合うポストはそのまま表示し, 合わないポストは内容を隠してプレースホルダーに置き換えます.

[![usabarashi/tweet-filter-with-gemini-nano のリポジトリカード](/images/2026-01-02-tweet-filter-gemini-nano-repo-card.png)](https://github.com/usabarashi/tweet-filter-with-gemini-nano)

## フィルタの動作

設定画面で, 表示したいポストの条件を書きます.
既定値は `technical content, programming and development, AI/ML research` です.

この実装は攻撃性の専用分類器ではありません.
表示したい条件への一致を判定するため, 既定の条件では攻撃的な技術ポストも表示される可能性があります.

推論は端末内で完結します.
ただし, モデルのダウンロードと画像の取得にはネットワークを使います.
この拡張は, ポスト本文や判定結果を外部のサーバへ送りません.

## Gemini Nano の API

[![The Prompt API（Gemini Nano）の公式ドキュメント](https://developer.chrome.com/static/docs/ai/prompt-api/images/cover.png)](https://developer.chrome.com/docs/ai/prompt-api)

Chrome の Gemini Nano は, `LanguageModel` というグローバルオブジェクトから使います.
この拡張の manifest では, `minimum_chrome_version` を `131` にしていますが, この指定だけで Prompt API を使えるとは限りません.
評価には `LanguageModel` を使える環境が必要です.

`LanguageModel.availability` で利用可否を確認します.
画像を扱えるかの確認では, `expectedInputs` にテキストと画像を指定します. `expectedOutputs` には出力の種類としてテキストを指定し, 出力言語も指定します.
現行 API の戻り値は `available`, `downloadable`, `downloading`, `unavailable` の 4 つです.
この実装の分岐では, `after-download` も受け付けます.

`LanguageModel.create` でセッションを作ります.
ここでも `expectedInputs` と `expectedOutputs` を指定します.
この実装では `temperature: 0.1`, `topK: 1` を指定しています.
セッションは `clone` で複製でき, `destroy` で破棄できます.
`inputUsage` と `inputQuota` で, セッションの入力使用量と上限をトークン数で確認できます.

`prompt` にテキストや画像を渡すと応答が返ります.
`prompt` のオプションの `signal` に `AbortSignal` を渡すと, 処理の中断を要求できます.

## 評価の順序

次の 4 段階を短絡評価します.
条件に一致した時点でポストを表示し, 残りの段階は評価しません.
不一致なら次の段階へ進み, 実行した段階がすべて不一致なら隠します.
条件判定で例外が出た場合も, ポストを表示し, 残りの段階は評価しません.
テキストが空の段階と画像がない段階は飛ばし, どの段階も実行できなければポストを表示します.

| # | 対象 | プロンプトに渡す内容 |
|---|---|---|
| 1 | 本文 | ポスト本文 |
| 2 | 引用元の本文 | `[Quoting @user: ...]` の形にした本文 |
| 3 | 引用元の画像 | 画像から生成した説明文 |
| 4 | ポスト本体の画像 | 画像から生成した説明文 |

プロンプトに条件と対象のテキストを埋め込み, `show` という真偽値 1 つだけを返すように指示します.

```text
Evaluate if this tweet matches the following criteria:
"<filter criteria>"

Tweet text: "<tweet text>"

Return JSON only with one boolean field named show.
Do not include any other keys or explanation.
```

応答を小文字に揃え, 最後に現れる `"show"` の後ろの `:` が `true` か `false` かを見ます.
どちらでもなければポストを表示します.

引用元の作者名には `@` を付けます（すでに `@` で始まる場合は重ねません）.

画像は, モデルで 1〜2 文の説明に変換し, その説明文を条件判定のプロンプトに渡します.
対象は `pbs.twimg.com/media/` を含む URL だけで, `name=large` に正規化します.
ポスト本体の画像は, 正規化した URL の重複を除きます.
取得や説明の生成に失敗した画像は, 条件判定の対象から除きます. 説明を 1 つも得られない段階は実行しません.
画像は 1 枚ずつ取得して説明します.
各画像段階では, その段階の説明文をまとめて 1 回の条件判定に渡します.

## 処理の組み立て

この評価を実行するために, 拡張は 4 種類のグローバル環境で動きます.
それぞれグローバルオブジェクト, 使える API, 寿命が違います.

| グローバル環境 | 役割 |
|---|---|
| **content script** | X の DOM を監視し, ポストを抽出し, 判定結果に応じて表示を変える |
| **service worker** | content script と offscreen document のメッセージを中継し, 評価結果をキャッシュする |
| **offscreen document** | Gemini Nano のセッションを保持し, 評価キューを実行する |
| **options page** | フィルタ条件, 出力言語, モデルのダウンロードを扱う |

::: {.scroll-figure}
![ポストの判定の流れ](/images/2026-01-02-tweet-filter-gemini-nano-flow.svg)
:::

図は正常時の処理を示しています. 失敗とタイムアウトの分岐は省き, 4 つの評価段階を 1 つにまとめています.

service worker はアイドル状態になると停止することがあるため, セッションと評価キューは offscreen document に置きます.
offscreen document は Window のグローバル環境を持ち, 対応環境では `LanguageModel` を利用できます.

この実装では, `expectedInputs` にテキストと画像を指定して `LanguageModel.availability` を呼び出します.
戻り値が `available` か `after-download` なら, テキストと画像を入力できるセッションを作ります.
それ以外の値が返った場合や作成に失敗した場合は, テキスト専用セッションの作成を試みます.
テキスト専用セッションも作れなければ, ポストを表示します.
テキスト専用セッションでは画像の段階を飛ばします.
同じセッションで `prompt` を繰り返すと, 会話履歴が蓄積し, `inputUsage` が増えます.
ポスト間でこの状態を引き継がないよう, ポスト 1 件の評価ごとにセッションを `clone` し, 評価後に複製したセッションを `destroy` します.
複製元のセッションは `prompt` に使いません.

service worker はキャッシュを参照し, 結果がなければ評価要求を offscreen document に転送します.
content script は評価の応答を待ち, 100 ミリ秒空けて次のポストを依頼します.
offscreen document はキューに入った評価を順に実行します.

content script は, キュー待ちを含めて評価の応答を最大 15 秒待ちます. タイムアウトした場合はポストを表示します.
このタイムアウトでは offscreen document の評価はキャンセルしません. service worker が評価結果を受け取った場合は, キャッシュに保存します.
プロンプトは 1 回ごとに 10 秒, 画像の取得は 1 枚ごとに 5 秒で待つのをやめ, 失敗として扱います.

## 評価結果のキャッシュ

service worker は評価結果を `chrome.storage.session` にキャッシュします.
この拡張のキャッシュは, 同じプロファイルのタブ間で共有されます.
`chrome.storage.session` のデータはメモリ上に保持され, ブラウザを閉じると消えます.

キャッシュはポスト ID をキーにした最大 500 件の LRU です.
読み取り時にも LRU の順序を更新するため, キャッシュ操作が並行すると更新が競合する可能性があります.
そこで, 更新を伴うキャッシュ操作をロックで直列化しています.

キャッシュへの書き込みは, content script に応答を返す前に `await` します.
書き込みの完了を確かめてから応答し, service worker の停止で未完了の書き込みが失われるリスクを減らすためです.

設定を変えるとキャッシュを消し, offscreen document のセッションを作り直します.
フィルタを無効にしたときは, offscreen document を閉じてキャッシュも消します.

リポストやページ遷移で同じポストが再び現れたときは, キャッシュがあればモデルによる再評価を省きます.

## References

- [usabarashi/tweet-filter-with-gemini-nano](https://github.com/usabarashi/tweet-filter-with-gemini-nano)
- [Built-in AI](https://developer.chrome.com/docs/ai/built-in)
- [The Prompt API](https://developer.chrome.com/docs/ai/prompt-api)
- [chrome.offscreen](https://developer.chrome.com/docs/extensions/reference/api/offscreen)
- [chrome.storage](https://developer.chrome.com/docs/extensions/reference/api/storage)
