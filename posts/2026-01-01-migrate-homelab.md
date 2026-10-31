---
title: "Homelab の実行基盤を Docker Compose から NixOS に移行した"
date: "2026-01-01"
tags:
  - Homelab
  - Debian
  - Docker
  - NixOS
---

プライベートで運用しているサーバ群を, 以下では **Homelab** と呼びます.
2025年12月の最終週に, その Homelab の実行基盤を Debian 上の Docker Compose から NixOS ホストに移しました.

![移行前後の筐体サイズ比較](/images/2026-01-01-homelab-size.svg)

この記事には, 移行時点の構成だけでなく, その後に追加したログ転送や監視, CI の構成も含みます.

## 移行の動機と踏み切れた理由

動機は3つあります.

1つは Linux カーネルの更新です.
このホストはサーバとして動かしていて, モニターもキーボードも日頃は繋いでいません.
そのため, 更新して何か起きたときの調査には手間がかかり, カーネルの更新はリスクとコストの大きい作業になっていました.
その作業を後回しにしたまま, カーネルは長年据え置きになっていました.

もう1つは動画のエンコードです.
移行前は, ffmpeg による H.264 への変換を CPU で回していました.
変換は CPU を長く占有するので, 複数の変換が重なるとホストに残る余力は小さくなります.
同じ処理を専用のエンジンに任せて, ホスト全体を軽くしたいと考えていました.

3つ目は筐体の制約です.
当時は, PCI Express のカードを挿せる筐体しか選択肢がありませんでした.
カードを挿す前提だと, 筐体にはスロットと設置場所の余裕が要ります.
同じ用途を USB2 の外部機器で代替できるようになり, この制約は解けました.

この3つに加えて, macOS で Nix flakes を長く使ってきたので, そろそろ NixOS も使ってみたくなりました.

## 移行前の構成

ホストは HP ProLiant MicroServer N54L でした.
2013 年の BIOS を積んだ世代の筐体です.
ファームウェアは UEFI ではなく BIOS です.

| 項目 | 製品と構成 |
|---|---|
| 筐体 | HP ProLiant MicroServer N54L（SKU F1F35A） |
| CPU | AMD Turion II Neo N54L（2 コア, 2.2 GHz） |
| メモリ | DDR3-1333 ECC 4GB（2 スロットのうち 1 スロット） |
| ストレージ | HDD 4 台, SSD 1 台 |
| ネットワーク | Broadcom BCM5723 GbE |
| 拡張スロット | PCIe Gen2 x16 を 1 基, Gen2 x1 を 1 基 |
| ファームウェア | BIOS（O41, 2013 年） |

動画のエンコードや暗号化をハードウェアで処理する仕組みは無く, どちらも CPU の汎用コアで処理していました.

移行前から, サービス側の構成は IaC（Infrastructure as Code）としてリポジトリで管理していました.
Compose ファイル, Dockerfile, Docker コンテナに mount する設定ファイルが対象です.
ただし反映は手作業で, Debian に SSH で入ってファイルを編集し, `docker-compose` でコンテナを上げ直していました.
Debian そのものも手作業でインストールしていたので, コードとして管理していたのはサービス側のファイルだけです.

![移行前のクライアント, サーバ, GitHub の関係](/images/2026-01-01-homelab-before.svg)

このホストで, 3つのファイルに分かれた Compose 構成を `docker-compose` で立ち上げていました.
BIOS では, 通電時に自動で起動するように設定していました（`State After G3`）.
各サービスには `restart: always` を付けていたので, 電源が戻ればホストもコンテナも自動で立ち上がる構成でした.
3つの Compose ファイルを以下の順序で指定し, 1つの構成として読み込んでいました.

```sh
docker-compose \
  -f docker-compose.network.yml \
  -f docker-compose.infrastructure.yml \
  -f docker-compose.application.yml \
  up -d
```

イメージはホストでビルドし, ソースからコンパイルするものもありました.

実行時の設定ファイルはホスト側の `docker/volumes/<コンテナ名>/` に置いて git で管理し, コンテナに bind mount していました.
認証情報は `docker/.env` に置き, Compose ファイルで参照してコンテナに渡していました.

## 移行後の構成

新しいホストは Beelink ME mini です.
ファームウェアは UEFI で, Secure Boot を使えます.

| 項目 | 製品と構成 |
|---|---|
| 筐体 | Beelink ME mini |
| CPU | Intel N150（4 コア, 最大 3.6 GHz） |
| メモリ | LPDDR5 16GB |
| ストレージ | M.2 NVMe SSD 6 台 |
| ネットワーク | 2.5GbE 2 ポート |
| 拡張スロット | なし |
| ファームウェア | UEFI（Secure Boot） |

動画のエンコードには iGPU の Quick Sync Video を使っています.
CPU は AES の暗号処理を高速化する AES-NI に対応しており, 対応するソフトウェアではこれらを使って処理を速くできます.

NixOS を入れ, OS とサービスの構成は 1 つの flake に書いています.
データ, Secure Boot の鍵登録, TPM2 へのバインドは Nix の外で扱っています.

実行基盤として変えたのは, インストールと起動, ランタイムの隔離, デプロイの方式です.
以下では, この3つに続けて秘密情報と監視も扱います.

## インストールと起動

ディスクは `disko` の記述からパーティションを作るようにしました.
ESP を作り, 残りの領域を LUKS2 で暗号化しています.
その内側に LVM のボリュームグループ `vg-main` を置き, ルートファイルシステムには ext4 を使っています.
以下は `disko.devices` 内の LUKS と LVM の接続部分の抜粋です.
デバイスパスは例示用で, 実機のパスに置き換える必要があります.
ESP, パーティションサイズ, 論理ボリュームの定義は省略しています.

```nix
disk.root = {
  type = "disk";
  device = lib.mkDefault "/dev/disk/by-id/nvme-<MODEL>_<SERIAL>";
  content.type = "gpt";
  content.partitions.luksRoot.content = {
    type = "luks";
    name = "cryptroot";
    settings.allowDiscards = true;
    content = { type = "lvm_pv"; vg = "vg-main"; };
  };
};
```

インストールには `nixos-anywhere` を使います.
対象ホストをライブ USB の NixOS インストール環境で起動しておく方法と, 既存の Linux から kexec でインストール環境へ移る方法があります.
kexec が使えるかどうかは, Secure Boot や実行中のカーネルの制約にも依存します.
TPM2 による自動解錠も設定しました.
initrd で Clevis が TPM2 を使って LUKS を自動解錠し, 自動解錠に失敗した場合はパスフレーズの入力に切り替わります.
Secure Boot は `lanzaboote` で有効にし, 鍵は `sbctl` で管理しています.
カーネルと initrd は ESP に配置され, 起動時に lanzaboote の仕組みで検証されます.

このホストは, 通電時に自動で起動する設定にしています.
TPM2 の自動解錠と組にすると, 通常は電源を入れ直すだけでパスフレーズなしに起動します.
ホストを丸ごと持ち出された場合も, PCR 7 などの解錠条件が変わらなければ自動解錠されます.
これはディスクの解錠の話で, ログイン認証を飛ばすものではありません.
セットアップ手順では, TPM2 のバインド先に PCR 7 を指定しています.
この設定では, 解錠時の PCR 7 の値がバインド時と一致しないと自動解錠できません.
ただし Secure Boot は起動時の署名を検証する仕組みで, ホストの持ち出し自体を防ぐものではありません.
そのため, このホストでは設置場所を管理できることを前提に, 無人での再起動を優先しています.

`/boot` は UUID ではなくパーティションラベルでマウントするようにしました.
`disko` がファイルシステムを作り直すと `hardware-configuration.nix` の UUID が古くなるためです.

## 実行ランタイムと隔離

移行前は, systemd が dockerd を起動し, その dockerd が Docker コンテナを動かしていました.
コンテナのなかには, ホストのネットワークを共有するものと, `privileged` で動かすものがありました.
前者はネットワーク名前空間を分離せず, 後者はホストのデバイスへの広いアクセスに加えて, Linux capabilities なども付与していました.

移行後は, サービスごとにホストの systemd ユニットを用意しています.
systemd が直接プロセスを起こすので, dockerd のような常駐デーモンは挟まりません.
ユニットには, サービスに応じて `ProtectSystem = "strict"`, `NoNewPrivileges`, `PrivateTmp`, `@system-service` のシステムコールフィルタなどを設定しています.
デバイスへのアクセスは `privileged` ではなく, udev ルールでグループに渡すようにしました.
定期実行は cron ではなく systemd のタイマーに置き換えました.

NixOS のコンテナも systemd が起動します.
systemd-nspawn で独立したユーザー空間と PID 名前空間を作り, その中で別の systemd がサービスを管理します.
名前空間を分けたままにしたいものだけ, この形にしています.

## デプロイ方式

![移行後のクライアント, サーバ, GitHub の関係](/images/2026-01-01-homelab-after.svg)

`docker compose build` は無くなりました.
サービスごとの Dockerfile も無く, システム全体を flake が記述しています.
更新は `deploy-rs` の `--remote-build` で, ホスト自身に新しいシステムをビルドさせて切り替えます.
ホストは x86_64, 作業機は aarch64 なので, 作業機側ではビルドしません.

```sh
deploy --remote-build 'path:.#<HOST>'
```

`<HOST>` は flake に定義したデプロイ対象の名前に置き換えます.

起動メニューに残っている前の世代を選ぶと, システム構成を戻せます.
ただし, サービスのデータや更新時のマイグレーションまで戻るわけではありません.
起動メニューに載せる世代数は, `boot.loader.systemd-boot.configurationLimit` で最大3世代にしています.
カーネルと initrd が ESP に配置されるので, 世代が増えると ESP を圧迫します.

バイナリキャッシュにあるものは取得し, キャッシュにないものだけをホストでビルドします.

## 秘密情報の管理

![秘密情報の復号から参照までの流れ](/images/2026-01-01-homelab-secrets.svg)

`docker/.env` は `agenix` に置き換えました.
age ファイルは別のプライベートな flake input にあり, agenix の各秘密情報の定義で `owner = "root"`, `mode = "0400"` を指定します.
復号されたファイルは `/run/agenix` に置かれ, ユニットは `EnvironmentFile` から読みます.
CI はプライベートリポジトリに触れずに評価できるよう, input を `secrets-dummy` に差し替えます.

## ログの保存と障害通知

![journald から Cloud Logging, Slack までの流れ](/images/2026-01-01-homelab-logs.svg)

Docker コンテナのログは `json-file` と `max-size: 3m` でコンテナごとに切っていました.
NixOS では journald で全体に上限をかけています.
journald の設定では, 保存容量を500MB, 1ファイルのサイズを50MB, 保持期間を14日に制限しています.
これらはローテーションや古いファイルの削除で適用されるため, 実際の使用量や保存期間が設定値を超える場合もあります.
容量の制限に達すると, 14日に満たないログでも削除されることがあります.

移行のあと, journald を入口にした転送と通知を足しました.
ホストの OTel Collector が journald を Google Cloud Logging に送ります.
Google Cloud への認証には SPIRE の JWT-SVID と Workload Identity Federation を使い, ログ転送用のサービスアカウント鍵ファイルは置いていません.
Cloud Logging 側に `severity>=ERROR` を拾うアラートポリシーを置き, Slack の**障害通知チャンネル**に通知します.
ハードウェアの異常も同じ経路です.
SMART, rasdaemon, 温度の検知は journald に出すだけで, 通知条件は Terraform で管理しています.

## 外形監視

![Datadog による監視から Slack 通知までの流れ](/images/2026-01-01-homelab-monitoring.svg)

Datadog を入れてからは, ホストの死活はそこで見ています.
外部から HTTP で叩く合成監視ではなく, Datadog Agent の報告が止まったことを捉えます.
`system.net.bytes_sent` が 10 分届かなければ, 同じ障害通知チャンネルに通知します.

報告が途絶えたことだけでは, ホストの停止, ネットワークの切断, Agent の停止を区別できません.
これとは別に, Agent が動いていてもエクスポーターから収集できなくなる場合に備え, 収集状態も監視しています.
ホストのエージェントが node-exporter と smartctl-exporter をスクレイプし, その OpenMetrics のヘルスをサービスチェックにしています.
サービスチェックが2回連続で失敗したら通知し, エクスポーターへの接続失敗などを検知します.

ハードウェアの状態も同じ障害通知チャンネルに集めています.
NVMe の温度, `critical_warning`, メディアエラー, 寿命の消費率, CPU 温度, ディスクと inode の使用率です.
しきい値は, 交換や増設を決める手前で鳴らしています.

## 残課題

デプロイは, いまも作業機から `deploy --remote-build` を実行しています.
`path:.` でローカルのディレクトリを入力にしているため, 未コミットの変更も, Git が追跡していないファイルも入力に含まれ得ます.
コミット ID だけではデプロイした構成を特定できないため, マージ済みのコミットを入力にする自動デプロイにしたいと考えています.
CI はホストの self-hosted runner で動いているので, ビルドを任せる場所はもうあります.
反映したコミットをホスト側で確かめられるところまでをセットにしたいところです.
