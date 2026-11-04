---
title: "Alexa で雨雲の接近と気象警報を知らせる"
date: "2026-10-13"
tags:
  - Alexa
  - AWS
  - Lambda
  - Rust
  - Terraform
---

自宅の Alexa 端末で, 雨雲の接近と気象警報を知らせる仕組みを作りました.
気象庁が公開しているデータを 5 分ごとに読み, 条件を満たすと仮想のコンタクトセンサーを開きます.
Alexa の定型アクションが, そのセンサーが開いたときに決まった文言を読み上げます.

実物のコンタクトセンサーは使っていません.
Lambda が 5 つのセンサーを公開し, 雨雲と警報の状態を報告します.

![スケジューラ, Lambda, 気象庁のデータ, DynamoDB, 定型アクションの関係](/images/2026-10-13-alexa-weather-alert-flow.svg)

## 仮想のコンタクトセンサーとして公開する

スマートホームスキルは, 家電を Alexa に登録し, その状態を報告する仕組みです.
公開するのは `Alexa.ContactSensor` の `detectionState` と, `Alexa.EndpointHealth` の `connectivity` です.
`detectionState` は `DETECTED` と `NOT_DETECTED` の 2 値で, 開いているかどうかしか表しません.
それでもこの型を選んだのは, 定型アクションのトリガーにコンタクトセンサーの開閉があるためです.

このスキルが受ける指示は 3 つで, 機器の一覧を返す `Discover`, 状態を返す `ReportState`, アカウントリンクの `AcceptGrant` です.
状態の変化は, スキルからイベントゲートウェイへ `ChangeReport` として送ります.

3 つの指示と 5 分ごとのポーリングは, 1 つの Lambda で処理しています.
読むデータと書く状態が共通するためです.
受け取った JSON に `directive` があればスキルへの指示として, なければポーリングの要求として扱います.

センサーを開いたら 45 秒待ち, そのあと閉じます.
Alexa が状態を問い合わせたときに開いていると答えるためと, 次の通知でまた開けるようにするためです.
閉じ損ねたセンサーは, 次のポーリングの最初に閉じます.
閉じる処理は, 場所の特定やデータの取得より先に実行します.

要求と応答の形は, Amazon が公開しているスマートホームのサンプルで確かめられます.

[![Alexa スマートホームのサンプルのリポジトリカード](https://opengraph.githubassets.com/4b98b3b05d6f94f7d920ea45835ec6b4034cf342a7e1ae6c3215b73db0aa969b/alexa-samples/alexa-smarthome)](https://github.com/alexa-samples/alexa-smarthome)

## 定型文を読み上げる理由

最初は, 定型アクションからカスタムスキルを起動し, 雨量や警報の種類を読み上げる構成にしていました.
利用者向けに定型アクションからスキルを起動するには, スキルにカスタムタスクがあり, そのタスクが認定と公開を済ませている必要があります ([Integrate Your Custom Task with Alexa Routines](https://developer.amazon.com/en-US/docs/alexa/custom-skills/integrate-custom-task-with-alexa-routines.html)).
開発段階のタスクは, 認定前の動作確認にだけ使えます ([Test Your Custom Task with Alexa Routines](https://developer.amazon.com/en-US/docs/alexa/custom-skills/test-custom-task-with-alexa-routines.html)).
公開するつもりがなかったため, 起動時に読み上げ文を返す仕組みは削除しました.

センサーが報告するのは開閉状態だけなので, Alexa は雨量や警報の種類までは読み上げません.
詳しい状態は, Lambda の `status` で確認します.

## センサーとしきい値

| センサー | 表示名 | 開く条件 |
|---|---|---|
| `rain_soon` | 雨雲接近 | 15 分以内に 1 mm/h 以上の雨 |
| `heavy_rain_soon` | 大雨接近 | 15 分以内に 20 mm/h 以上の雨 |
| `warning_lv3` | 気象警報 | 警報（警戒レベル3相当を含む） |
| `warning_lv4` | 危険警報 | 危険警報（警戒レベル4） |
| `warning_lv5` | 特別警報 | 特別警報（警戒レベル5） |

5 つのセンサーの id は固定しています.
id を変えると, 作った定型アクションとの対応が切れるためです.
表示名と説明だけは変えられます.

しきい値と再通知の間隔は, 次のとおりです.

| 設定 | 既定値 | 意味 |
|---|---|---|
| 雨のしきい値 | 1 mm/h | 1〜5 mm/h の階級の下限 |
| 強い雨のしきい値 | 20 mm/h | 20〜30 mm/h の階級の下限 |
| 予報を見る範囲 | 15 分 | 直近の基準時刻から 15 分先まで |
| 抑制する時間 | 90 分 | 開いたあと同じ条件では知らせない |
| 抑制を解除する無降雨時間 | 30 分 | これだけ雨が降らなければ再び知らせる |
| 開いておく時間 | 45 秒 | 閉じるまでの待ち時間 |

夜間に鳴らしたくないときは, `WEATHER_ALERT_QUIET_HOURS` に `23:00-07:00` のように, 通知しない時間帯を日本時間で指定します.
指定した時間帯はセンサーを開きません.
時間帯が終わったあとも条件を満たしていれば知らせます.
定型アクション側ではなくセンサー側で止めることで, 45 秒の待機とイベントの送信も省けます.

## 雨雲接近をナウキャストのタイルから読む

気象庁は, 高解像度降水ナウキャストの地図に使っているタイル画像をそのまま公開しています.
`targetTimes_N2.json` には, 基準時刻と予報時刻の組が並んでいます.
時刻は `YYYYMMDDHHMMSS` の並びで, 5 分刻みです.
最新の基準時刻のフレームのうち, その時刻から 15 分先までのものだけを使います.

自宅の緯度経度を Web メルカトルのタイル座標に直し, そのタイルの 1 ピクセルを読みます.
ズームレベルは 10 で, このタイルで使える最大です.

```text
https://www.jma.go.jp/bosai/jmatile/data/nowc/{basetime}/none/{validtime}/surf/hrpns/10/{x}/{y}.png
```

PNG の色は降水強度の階級を表しています.
配色指針にある 8 つの階級の色を, 各階級の下限値 (mm/h) に対応させます.
いちばん色が薄い階級 (0〜1 mm/h) は 0.1 mm/h として扱うので, しきい値が 1 mm/h の場合は通知の対象になりません.
タイルからは階級より細かい値が分からないため, しきい値は階級の下限値に合わせています.
15 分ぶんのフレームの最大値を取り, しきい値と比べます.

再通知の抑制と解除は, 設定した時間で決まります.
弱い雨の通知を抑制しているあいだに雨が強くなったときは, 抑制を無視して `heavy_rain_soon` を開きます.

## 気象警報を別表3のコードで分類する

警報の情報は, 府県予報区ごとの JSON から読み取ります.
府県予報区のコードは, 郵便番号から場所を特定するときに取得します.
JSON は発表の配列で, `dataTypeCode` が `VPWW55` から `VPWW61` のものだけを見ます.
`class20Items` から自分の市町村の `areaCode` を探し, `kinds` のコードを別表3で分類します.
危険警報は令和8年5月29日の再編で加わった区分です.

| コード | 扱い |
|---|---|
| 02〜09 | 警報（警戒レベル3相当を含む） |
| 43, 48, 49 | 危険警報（警戒レベル4） |
| 32, 33, 35〜39 | 特別警報（警戒レベル5） |
| 00, 10, 12〜27, 29 | 注意報と解除. 対象外 |
| 42, 45〜47 | 名前のない予約領域. 対象外 |
| その他 | 対象外. レベルを推測せず, ログに残す |

`status` が `解除` か `発表警報・注意報はなし` のものは除きます.
同じコードの警報が複数ある場合は, `reportDatetime` が最も新しいものだけを残します.

取得には ETag を使い, 変化がなければ 304 が返ります.
ただし, 有効な警報を知らせ終えるまでは保存済みの ETag を更新しません.
通知しない時間帯やアカウントリンクが済んでいないあいだに 304 が返ると, その警報を通知し損ねるためです.

## 郵便番号から場所を特定する

入力は郵便番号だけです.
リポジトリには入れず, 環境から渡しています.

実行時に 3 つの公開サービスを呼びます.

- zipcloud の検索 API で住所を引きます.
- 国土地理院の住所検索 API で緯度経度を引きます.
- 気象庁の `area.json` で市町村と府県のコードを引きます.

`area.json` の市町村から親をたどり, 府県予報区のコードを取得します.
同じ名前の市町村が 1 つの府県に複数あると, 名前だけでは特定できません.
郡名が付いた住所なら, 郡名を含む名前のうち, いちばん長いものを選びます.
それでも場所を特定できないときは, 緯度経度や区域のコードを直接指定します.

特定した結果は状態に保存し, 郵便番号が変わるまで再利用します.
警報を取得する区域が変わったときは, 保存していた ETag を捨てます.
前の区域の ETag で 304 が返ると, 新しい区域の警報が見えなくなるためです.

## 状態は DynamoDB の 1 項目に置く

リフレッシュトークン, 場所のキャッシュ, センサーの状態, 雨の抑制の記録, 警報の既読, ETag を, DynamoDB の 1 項目に入れています.

```text
pk      = "store"
data    = {...}   # 上記をまとめた JSON
version = 42
```

ポーリングとスキルの呼び出しは同時に走ります.
最後に書いたほうが勝つと, リンクしたばかりのトークンや, 開いたセンサーの記録が消えます.
そこで, `version` が読み取ったときと同じ場合だけ書き込みを成功させます.
条件が合わなければ読み直して再試行し, 5 回試しても成功しなければエラーにします.

リフレッシュトークンの更新は `AcceptGrant` に限定し, ポーリング結果の保存では保存済みの値を残します.
並行して保存された新しいトークンを, 読み取り済みの古い値で上書きしないためです.

`ChangeReport` の送信に失敗したときは, すでに開けたセンサーを閉じ, 抑制と既読を記録しません.
通知に失敗したのに, その後 90 分間抑制されるのを避けるためです.

ただし, 応答が返らず送信の成否が分からない場合は, 届いている可能性があるため, 開いたものとして記録します.
記録の期限を過去の時刻に設定するので, 次のポーリングでセンサーを閉じます.

## 2 組の資格情報を使い分ける

スキルには資格情報が 2 組あります.
アカウントリンク用の Login with Amazon と, イベント送信用の Alexa Skill Messaging です.

アカウントリンクには, Login with Amazon のセキュリティプロファイルの client id を使います.
`amazon.co.jp` の利用者向けには, トークンの URL に `https://api.amazon.co.jp/auth/o2/token` を指定します.

`AcceptGrant` で渡されるコードは, アカウントリンク用ではなく, イベント送信用の client id と secret を使ってトークンに交換します.
交換先は `https://api.amazon.com/auth/o2/token` で, リダイレクト URI は付けません.
イベントを送るには, マニフェストに `alexa::async_event:write` の権限が要ります.
得たリフレッシュトークンは DynamoDB に保存し, ポーリングのたびにアクセストークンを取得します.

## デプロイ

AWS のリソースは Terraform で作ります.
Alexa の日本向けエンドポイントが us-west-2 にあるため, Lambda もそこに置いています.
Lambda のバイナリは, default branch への push で GitHub Actions が差し替えます.

スキルは ASK CLI の `ask deploy` で作ります.
マニフェストには権限, アカウントリンク, 公開情報を定義し, Lambda の ARN と client id はスクリプトで埋め込みます.
開発コンソールで endpoint や権限を設定する作業は, これでなくなります.

[![Alexa Skills Kit のコマンドラインインターフェースのリポジトリカード](https://opengraph.githubassets.com/3df067e0daac53653eecbb910b448f303a5f2d734c42c9be3f612a41865f358a/alexa/ask-cli)](https://github.com/alexa/ask-cli)

残る手作業は, 画面で行う設定と値の受け渡しです.

- Login with Amazon のセキュリティプロファイルを作り, client id をスクリプトに渡します.
- Skill Messaging の client id と secret を, コンソールから Terraform の変数へ入れます.
- 最初のスキルデプロイのあとにスキル id を Terraform の変数へ入れ, 再適用して Lambda の呼び出し権限を作ります.
- スキルの有効化とアカウントリンクを, Alexa アプリで行います.

スキルは開発段階のままで, 認定は申請しません.

現在の状態は, Lambda の `status` で確認します.
応答には, 特定した場所, 15 分先までの最大雨量, 有効な警報のコード, アカウントリンクの有無が含まれます.

```console
$ aws lambda invoke --function-name weather-alert \
    --payload '{"action":"status"}' \
    --cli-binary-format raw-in-base64-out status.json
```

動作は, 雨を待たずに `test` で確かめられます.
センサーを開き, 45 秒後に閉じます.

```console
$ aws lambda invoke --function-name weather-alert \
    --payload '{"action":"test","sensor":"rain_soon"}' \
    --cli-binary-format raw-in-base64-out out.json
```

## 雑感

デプロイは自動化できましたが, 資格情報のまわりは手作業の比重が大きく感じました.
手順に慣れていないこともありました.
すべてを宣言的には管理できないため, Alexa スキルの開発を頻繁に行いたいとは思いません.

## References

- [気象庁 高解像度降水ナウキャスト](https://www.jma.go.jp/bosai/nowc/)
- [気象庁 気象警報・注意報](https://www.jma.go.jp/bosai/warning/)
- [配信資料に関する技術情報 第634号](https://www.data.jma.go.jp/suishin/jyouhou/pdf/634.pdf)
- [気象警報・注意報（Ｒ０６）別表3](https://dmdata.jp/docs/jma/manual/0206-0206_appendix.pdf)
- [気象庁 配色に関する設定指針](https://www.jma.go.jp/jma/kishou/info/colorguide/HPColorGuide_202007.pdf)
- [Alexa Smart Home Skill API: Send Events](https://developer.amazon.com/en-US/docs/alexa/smarthome/send-events.html)
