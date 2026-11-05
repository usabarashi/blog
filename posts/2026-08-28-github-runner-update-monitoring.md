---
title: "Self-hosted GitHub Actions runner の更新を 2 層で監視する"
date: "2026-08-28"
tags:
  - GitHub Actions
  - NixOS
  - Nix
  - Slack
---

GitHub Actions の self-hosted runner は, NixOS ホストでソースからビルドして動かしています.
自動更新は使っていないので, 新しいバージョンへ上げるには flake のリビジョンを更新してデプロイする必要があります.
以下では, flake の入力が指すリビジョンを **pin** と呼びます.

GitHub は, 自動更新を無効にした runner に, 新しいバージョンが出てから 30 日以内の更新を求めています.
期限を過ぎると, その runner にジョブは配信されません.
pin の更新を忘れると, CI が静かに止まります.

[![Self-hosted runners reference](https://docs.github.com/assets/cb-345/images/social-cards/actions.png)](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)

更新忘れと配備のずれを, 週次のワークフローと日次の systemd timer で監視します.

## runner を別の nixpkgs input から取る

runner のパッケージは, ホスト用とは別の nixpkgs input から取っています.
更新の周期が違うので, runner と関係のないパッケージを更新せずに, runner の pin だけを動かせます.

パッケージは nixpkgs がソースからビルドしたものを使います.
GitHub が配布する runner の tarball をこのホスト向けに patchelf で書き換えたところ, .NET のランタイムが起動しませんでした.
CoreCLR の初期化で `Failed to load System.Private.CoreLib.dll` と HRESULT `0x8007000B` が記録されていました.

## 2 つの層に分ける

| 層 | 動く場所 | 周期 | 答える問い |
|---|---|---|---|
| pin の鮮度 | GitHub が用意するランナー | 週次と `flake.lock` の更新時 | input の追従先に新しい runner が入ったか |
| 配備のずれ | ホストの systemd timer | 毎日 | unit の設定がビルド時のバージョンより古くないか |

層を分けたのは, 片方だけでは足りないからです.
pin を新しくしてもデプロイしていなければ, 配備された runner は古いままです.
逆に配備が pin と一致していても, 上流が新しければ期限は進みます.

週次の層は, self-hosted runner ではなく GitHub が用意するランナーで動かします.
runner が古くてジョブを受け取れなくなると, その runner の上で動く監視も一緒に止まるためです.
毎日の層は, ホストの systemd timer で動かします.
runner のサービスとは別の unit なので, runner が止まっていても検査は走ります.

![週次の pin 検査と日次の unit 設定の検査が, それぞれ別の場所で動く構成](/images/2026-08-28-github-runner-update-layers.svg)

## pin が古いかを週次で調べる

週次のワークフローは, runner 用 input の更新前後で, runner のバージョンを比べます.

```yaml
on:
  schedule:
    - cron: '30 14 * * 0'   # 日曜 23:30 JST
  push:
    paths:
      - "<FLAKE_LOCK>"
  workflow_dispatch:
```

lock が更新されたときにも, 同じ検査を走らせます.
山括弧の値は置き換え用のプレースホルダーで, コードは処理の抜粋です.

現在のバージョンは, lock に記録された runner 用 input のリビジョンで評価して取ります.

```sh
nix eval --raw "github:nixos/nixpkgs/<REV>#github-runner.version"
```

候補のバージョンは, 作業ツリーの lock を一時的に更新して取ります.
lock は先にコピーしておき, 終了時に `trap` で元へ戻します.
ワークフローが lock を書き換えて push することはありません.

```sh
nix flake update <RUNNER_INPUT> --flake <FLAKE_DIR>
```

比較には `sort -V` を使います.
文字列として比べると, `2.9.0` と `2.10.0` の大小を取り違えるためです.

```sh
HIGHER=$(printf '%s\n' "$PINNED" "$CANDIDATE" | sort -V | tail -1)
```

候補が現在より低い場合は, 通知せず警告だけを出します.

上流のリリース情報も取得します.
`actions/runner` のリリース一覧をページ単位でたどり, pin に含まれる runner のバージョンより新しいリリースのうち, 最も古いものの日付を取ります.
下書きとプレリリースは除いて数えます.
更新の遅れを過小評価しないよう, 最新ではなく, pin より後に出た最初のリリースから数えます.

状態ごとの扱いは次のとおりです.

| 状態 | 意味 | 対応 |
|---|---|---|
| 候補が現在より新しい | input の追従先に新しい runner が入った | lock を更新する |
| 候補が同じで, 上流に新しいリリースがある | input の追従先には新しい runner がまだ入っていない | 反映を待つ |
| 候補が同じで, 上流にも新しいリリースがない | 最新 | 何もしない |

pin より新しい最初のリリースからの経過日数も, 更新時期の目安として通知に含めます.
期限の判定は GitHub 側にあり, この計算はその判定を再現するものではありません.
セキュリティ上の更新が必要な場合は, 30 日を待たずに配信が止まることがあります.

## unit に設定されたバージョンを毎日確かめる

毎日の検査には, NixOS のモジュールが生成するシェルスクリプトを使います.
スクリプトには, ホストの構成をビルドしたときの runner のバージョンが埋め込まれています.
比べているのはそのバージョンと, unit に設定された起動コマンドのバージョンです.
検査のたびに nix を評価し直す必要はありません.

pin を上げても, 更新した構成をホストへデプロイしていなければ, どちらも古いままなので, この検査では気付けません.
週次の層も pin の鮮度を見るだけなので, pin を上げたあとのデプロイ漏れは, どちらの層でも分かりません.

timer は毎日実行する設定で, 実行時刻には最大 1 時間のランダムな遅延を加えます.
停止中に実行時刻を過ぎた場合は, 起動後に検査を実行します.

```nix
timerConfig = {
  OnCalendar = "daily";
  Persistent = true;
  RandomizedDelaySec = "1h";
};
```

スクリプトはまず, リポジトリごとの runner の unit がすべて `active` かを調べます.
`active` でない unit があれば, その一覧を Slack に送ります.

次に, `ExecStart` から起動コマンドのバージョンを読みます.
各 unit は同じパッケージを使う想定なので, 1 つ目の unit だけを読みます.
この構成では, `ExecStart` に runner のバージョンを含むストアパスが設定されています.
読んでいるのは設定上の起動コマンドで, 実行中のプロセスのバージョンではありません.
検査するのは 1 unit だけなので, 他の unit にだけ残ったずれは検知できません.

```sh
EXEC_START=$(systemctl show "$FIRST_UNIT" -P ExecStart)
```

ストアパスの `github-runner-<X.Y.Z>` からバージョンだけを取り出し, スクリプトに埋め込んだバージョンと比べます.

unit のバージョンがスクリプトに埋め込んだバージョンより古いときだけ, デプロイを促す通知を送ります.
unit のほうが新しい場合は, 更新遅れではないため通知しません.

## 通知が来たときに何をするか

週次の検査で更新候補が見つかったら, pin を上げてデプロイします.
runner のバージョンが変わらなくても, lock を更新したらデプロイします.
nixpkgs 側のパッケージの修正が入っていることがあるためです.
日次の検査でずれが見つかったら, 配備された構成を確認します.
停止の通知が来たら, その unit の状態を調べます.

デプロイのあとは, 各 unit の起動コマンドがデプロイした構成と一致していることを確かめます.
パッケージが変わった場合は, unit が再起動していることも確かめます.

nixpkgs が上流に追いついていないという通知は, input の追従先への反映を待つ合図です.
GitHub がそのバージョンを受け付け続けるかぎり, パッケージ版のままで構いません.
別の配布物やパッケージ定義を使う場合は, ホスト上での動作検証も必要です.
更新期限が近い場合や緊急のセキュリティ更新では, 別の更新方法を検討します.

この監視だけでは, runner が GitHub からジョブを受け取れるかまでは確認できません.
ジョブが queued のまま進まない場合は, そのバージョンが GitHub に受け付けられているかも含めて調べます.

## References

- [Self-hosted runners reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)
- [actions/runner releases](https://github.com/actions/runner/releases)
- [github-runner (nixpkgs)](https://github.com/NixOS/nixpkgs/tree/master/pkgs/by-name/gi/github-runner)
