---
title: "HCP Terraform の drift を毎日 plan で検出する"
date: "2026-04-13"
tags:
  - Terraform
  - GitHub Actions
  - Slack
  - IaC
---

インフラの構成は 1 つのリポジトリにまとめていて, クラウドのリソースはその中の Terraform で管理しています.
Terraform のディレクトリは, それぞれが 1 つのワークスペースとして HCP Terraform に登録されています.
plan と apply は IaC のマージを起点に走ります.
管理画面や CLI から直接変更されたリソースは, そのワークスペースのコードを次に触るまで差分として現れません.
DNS のレコードを書き換えるような変更は, コードを読んでも気付けません.

コードに書いた構成と, 実際のクラウドの状態のずれを **drift** と呼びます.
drift の検出は, HCP Terraform では **Health assessments** という機能で提供されています.
Standard と Premium のプランが対象で, Free プランでは使えません.
そこで, HCP Terraform の組織にあるすべてのワークスペースに毎日 plan だけを実行し, 差分が出たものを Slack に通知する GitHub Actions のワークフローを追加しました.

[![HCP Terraform の Health assessments のドキュメント](https://developer.hashicorp.com/og-image/terraform.jpg)](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/health)

## HCP Terraform に plan を実行させる

drift を検出するには, コードと実際のリソースを比べる plan を回します.
ワークスペースの実行は remote execution か agent のモードで HCP Terraform が行い, プロバイダの認証情報もそちらにあります.
plan をランナーの上で実行する構成では, ランナーからクラウドへ認証する経路を別に用意することになります.
plan は HCP Terraform に実行させ, GitHub Actions は結果を集めて通知するだけにしました.

HCP Terraform の **plan-only run** は, apply できない plan だけの run です.
API のドキュメントでは "a speculative, plan-only run that Terraform cannot apply" と説明されています.
state は書き換わらず, 正常終了した run は `planned_and_finished` になります.

## 定期実行のワークフロー

毎日 1 回と, 手元から実行するときのために 2 つのトリガーを置いています.

```yaml
name: Terraform Cloud Drift Detection

permissions:
  contents: read

on:
  schedule:
    - cron: '0 3 * * *' # JST 12:00
  workflow_dispatch:

concurrency:
  group: terraform-cloud-drift-detection
  cancel-in-progress: true
```

権限は `contents: read` だけにし, チェックアウトでは `persist-credentials: false` を指定します.
このジョブはリポジトリの中身を読んで API を呼ぶだけで, push はしません.

ジョブは Node.js 25 以上を用意し, `.github/scripts/` に置いた TypeScript を直接実行します.
型注釈だけで書いた TypeScript は, Node.js が型を除いてそのまま実行できます.
`enum` や `namespace` のような, 型以外の変換が要る構文は使っていません.
ビルドの手順も `tsc` の実行もなく, チェックアウトしたファイルをそのまま動かします.

[![Node.js の「Running TypeScript Natively」のページ](https://nodejs.org/en/next-data/og/announcement/Node.js%20%E2%80%94%20Run%20JavaScript%20Everywhere)](https://nodejs.org/en/learn/typescript/run-natively)

## ワークスペースを順に plan する

スクリプトは, 組織にあるすべてのワークスペースを取得し, 1 つずつ plan-only run を作り, 終わるまで待って結果を集めます.

![GitHub Actions から HCP Terraform の API を呼び, 問題があるときだけ Slack に送る流れ](/images/2026-04-13-tfc-drift-detection-flow.svg)

ワークスペースの一覧はページ単位で返るので, `meta.pagination` の総ページ数を読みながら最後までたどります.

```ts
const query = new URLSearchParams({
  "page[number]": String(pageNumber),
  "page[size]": "100",
});

const res = await client.request<TfcListResponse<TfcWorkspaceResource>>(
  `/organizations/${encodeURIComponent(organizationName)}/workspaces?${query.toString()}`
);
```

run の作成は 1 リクエストです.
`plan-only` を立てると, その run は apply できなくなります.
`message` は run の一覧に残るので, 定期実行から作られたものだと分かるようにしています.

```ts
const res = await client.request<TfcRunCreateResponse>("/runs", {
  method: "POST",
  body: JSON.stringify({
    data: {
      type: "runs",
      attributes: {
        "plan-only": true,
        message: "Scheduled drift detection",
      },
      relationships: {
        workspace: { data: { type: "workspaces", id: workspaceId } },
      },
    },
  }),
});
```

作成した run は, 終わりの状態になるまで 10 秒ごとに問い合わせます.
plan の結果は `?include=plan` で同じ応答に含めます.
1 回の問い合わせには 30 秒の上限を置き, run 全体の待ち時間にも上限を置いています.

```ts
const TERMINAL_STATUSES = new Set([
  "planned_and_finished",
  "errored",
  "canceled",
  "force_canceled",
  "discarded",
  "policy_soft_failed",
  "policy_hard_failed",
  "unreachable",
]);
```

`planned_and_finished` は plan-only run の正常終了です.
`policy_soft_failed` は Sentinel の soft fail で, plan-only run ではこれも終わりの状態になります.
上限を超えた run は `timed_out` として扱います.

待ち時間の上限は, 通常のワークスペースで 10 分, agent で動くワークスペースでは 15 分です.
run が agent に渡って plan が始まるまでに時間がかかるためです.

ワークスペースは並列ではなく順に処理しています.
同時実行数の上限を超えると, 後続の run は待ち状態になります.

## 何を drift とみなすか

run が `planned_and_finished` で終わったら, 差分の有無と内訳を読みます.
差分の有無は run の `has-changes` で判定し, 追加, 変更, 削除の件数は plan の `resource-additions`, `resource-changes`, `resource-destructions` から読みます.
ここで drift と呼ぶのは, plan に差分が出たという事実だけです.
手作業で変えられたのか, apply できなかった変更が残っているのかは区別しません.

| run の結果 | 扱い | Slack |
|---|---|---|
| `planned_and_finished` で差分なし | 問題なし | 通知しない |
| `planned_and_finished` で差分あり | drift | 通知する. 件数も載せる |
| `errored` や `timed_out` | 検出できていない | 通知する |

すべてのワークスペースで plan が正常に終わり, 差分がなければ通知しません.
drift があっても run は正常に終わっているので, ワークフローは失敗にしません.
毎日「異常なし」を流すと, そのうち通知自体が読まれなくなります.

## Slack に送る

スクリプトは, 投稿するメッセージをファイルに書き, `GITHUB_OUTPUT` に `should_post` を出力します.
ワークフローは, その値が `true` のときだけ Slack のアクションを実行します.

```yaml
      - name: Send to Slack
        if: steps.drift-detection.outputs.should_post == 'true'
        uses: slackapi/slack-github-action@af78098f536edbc4de71162a307590698245be95 # v3.0.1
        with:
          method: chat.postMessage
          token: ${{ secrets.SLACK_BOT_TOKEN }}
          payload-file-path: "/tmp/slack/payload.json"
          payload-templated: false
          retries: 5
```

## 運用

この通知を見るようになって, コードを触っていないワークスペースの変化に気付けるようになりました.
動かし始めた直後に, あるワークスペースで drift が見つかりました.
コードにない変更だったので, クラウド側の設定をコードに取り込むか, 戻すかを決めました.

この処理には, 対象のワークスペースで run を作れるトークンが要ります.
GitHub Secrets に置き, 環境変数でスクリプトに渡しています.

plan を毎日回すこと自体は, ワークフローと 1 つのスクリプトで足ります.
ワークスペースを増やしても, スクリプトが毎回一覧を取り直すので, このジョブに設定を足す必要はありません.

## References

- [Health assessments](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/health)
- [Run states and stages](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/run/states)
- [Runs API](https://developer.hashicorp.com/terraform/cloud-docs/api-docs/run)
- [Plans API](https://developer.hashicorp.com/terraform/cloud-docs/api-docs/plans)
- [Workspaces API](https://developer.hashicorp.com/terraform/cloud-docs/api-docs/workspaces)
- [slackapi/slack-github-action](https://github.com/slackapi/slack-github-action)
