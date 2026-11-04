---
title: "情報収集 bot の検索結果を Gemini でフィルタリングする"
date: "2026-03-27"
tags:
  - X
  - Gemini
  - Slack
---

X (旧 Twitter) の検索結果を Slack に流す bot を Homelab の NixOS ホストで動かしています.
20 分おきにタイマーで起動し, 1 回分の検索と通知をして終了します.

集めた投稿には, 検索語を含むだけの雑談や宣伝も混ざります.
特定のアカウントの投稿や, 特定の語を含む投稿は, **無視リスト**で落としています.
文字列で落とせるものはこれで消えますが, 内容が条件に合うかどうかは, 単純な文字列の一致だけでは判断しきれません.

そこで, 無視リストを通った投稿を Gemini にまとめて渡し, 残す条件を自然文で書いて判定させる段を足しました.
条件に合わない投稿は Slack に流しません.
判定は 1 回の実行につき 1 リクエストにまとめ, 失敗したときは無視リストを通った投稿をすべて流します.

![検索結果が無視リストと Gemini の判定を通り, 残った投稿だけが Slack に流れる流れ](/images/2026-03-27-twitter-bot-gemini-filter.svg)

## 文字列で落とせるもの

無視リストの項目は, `@` で始まるものとそうでないもので扱いが変わります.
`@name` は投稿者の screen_name と完全に一致するかを見ます.
それ以外の項目は, 投稿者の表示名か本文に含まれるかを見ます.
本文に含まれる語で落とすので, 別の話題でその語が出てくる投稿も一緒に落ちます.

特定のアカウントや語の一致で除外できるものは, この段で足ります.
文字列の一致だけでは判断しきれない投稿を, 次の段で判定します.

## まとめて 1 リクエストで判定する

無視リストを通った投稿がある場合は, まとめて 1 リクエストで判定します.
対象がなければ API は呼びません.
投稿ごとに呼ぶと, 実行のたびに投稿の数だけリクエストを送ることになります.

プロンプトには, 残す条件と投稿の一覧を入れて, 判定を配列で返すよう指示します.
投稿は `[0] @screen_name: 本文` の形で並べます.
番号を振るのは, 応答の判定を入力の投稿に対応づけるためです.

```text
You are a tweet filter. Apply the following rule to each tweet and decide whether it should be kept or excluded.

Filter rule: <残す条件>

Tweets:
[0] @<screen_name>: <本文>
[1] @<screen_name>: <本文>

Respond with a JSON array. Each element must have "index" (integer) and "keep" (boolean). Include every tweet index in the response.
```

[![Gemini API の構造化出力のドキュメント](https://ai.google.dev/static/site-assets/images/share-ais-513315318.png)](https://ai.google.dev/gemini-api/docs/structured-output)

応答の形は, リクエストの `generationConfig` で指定します.
`responseMimeType` に `application/json` を渡し, `responseSchema` に index と keep を持つオブジェクトの配列を書きます.

```json
{
  "generationConfig": {
    "responseMimeType": "application/json",
    "responseSchema": {
      "type": "ARRAY",
      "items": {
        "type": "OBJECT",
        "properties": {
          "index": { "type": "INTEGER" },
          "keep": { "type": "BOOLEAN" }
        },
        "required": ["index", "keep"]
      }
    }
  }
}
```

応答は `candidates[0].content.parts` の各要素の `text` をつなげて 1 つの文字列にしてから, JSON として読みます.
`parts` が複数に分かれて返ることがあるためです.

スキーマを指定しても, 入力した投稿と判定が一対一に対応するとは限りません.
そこで, 読み取ったあとに, 重複を除いた index の数が投稿の数と一致することと, `0` から投稿数の 1 つ手前までの index がすべて含まれることを確かめます.
足りない index があれば失敗として扱います.
検証を通った応答では, index から引いた真偽値で残すかどうかを決めます.
検証後はすべての index がそろうはずですが, 参照時に見つからなければ投稿を残すようにしています.

## 判定に失敗したときは全件を通す

判定の段で失敗したら, 無視リストを通った投稿をそのまま Slack に流します.
HTTP のエラー, JSON の読み取り失敗, 空の応答, 件数の不一致のどれでも同じです.
本来なら落とす投稿も, その回は Slack に届きます.
判定に失敗したときに通知を止めると, API の不調が続くあいだ, 投稿が届かないままになります.
ノイズが増えることより, 届かない時間を作らないことを選んでいます.
この振る舞いを **fail open** と呼んでいます.

## References

- [Structured output](https://ai.google.dev/gemini-api/docs/structured-output)
- [systemd.timer](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)
