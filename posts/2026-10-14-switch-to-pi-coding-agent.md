---
title: "プライベート環境のコーディングエージェントを Pi に一本化した"
date: "2026-10-14"
tags:
  - Pi
  - Coding Agent
  - MCP
  - Nix
  - macOS
---

仕事では Claude Code を使っています.
プライベート環境では, 比較のために Codex, OpenCode, Grok Build, Antigravity を試していました.
どれも一長一短で, エージェントごとに設定を作る作業に疲れていました.

いまプライベートで使っているモデルは DeepSeek V4.1 Flash で, 安定しています.
頻繁に別のモデルを試すこともなくなりました.
そうなると, エージェントを選ぶ基準は, いろいろなモデルを試せることより, 普段使うモデルと MCP をそのまま扱えるかに移ります.

そのなかで, Pi Coding Agent が複数のプロバイダの LLM を直接扱え, MCP にも対応したことが, 切り替えの大きなきっかけになりました.
プライベート環境では Pi を入れてから同じ日のうちにほかの 4 つを外し, いまは Pi だけを使っています.

[![earendil-works/pi のリポジトリカード](https://opengraph.githubassets.com/1/earendil-works/pi)](https://github.com/earendil-works/pi)

## フロンティアモデルの品質を要所で得る

Pi では, 実行役と相談役を分けてモデルを使っています.
Claude Code の advisor 機能でも, フロンティアモデルの呼び出しを要所だけに抑えていました.
プライベートでもその考え方を取り入れ, 以前は `codex exec` でフロンティアモデルを呼んでいました.
いまは Advisor プラグインに置き換えています.
実行役は OpenCode Go の DeepSeek V4.1 Flash に任せます.
品質を確保するため, 要所でだけ Advisor プラグインから ChatGPT Plus の GPT-6 Astra を呼び出し, レビューを受けます.
プライベート用途では, この 2 つの契約で不足していません.

![DeepSeek V4.1 Flash の実行役と GPT-6 Astra の相談役の関係](/images/2026-10-14-pi-advisor-flow.svg)

## Pi の導入と設定を管理する

Pi に切り替えると, 設定の面倒は 1 か所に収まりました.
skills とサンドボックスは以前から共通化していたので, この構成は Pi だけのものではありません.
移行コストも, その共有部分のおかげで低く済みました.

開発環境は, nix-config リポジトリの Nix flake で管理しています.
Pi のパッケージと設定もここにまとめています.

[![usabarashi/nix-config のリポジトリカード](https://opengraph.githubassets.com/1/usabarashi/nix-config)](https://github.com/usabarashi/nix-config)

この Nix パッケージでは, 配布されている standalone の tarball を `fetchurl` で固定し, アセットごと `libexec` に置いています.
バイナリがアセットを同じディレクトリから探すためです.
更新は `version` と `hash` を書き換えて再ビルドします.

`~/.pi/agent` の設定ファイルは, home-manager の out-of-store symlink でリポジトリに向けています.
編集はそのまま次の起動に反映されます.
変更はリポジトリ側に残るので, Git で差分を確認できます.

## サンドボックスで触れられる範囲を決める

サンドボックスは, Pi に切り替える前から使っていたものです.
本来はクラウド上の使い捨て環境で動かしたいのですが, まだ整備できていません.
ローカルで多くの権限を渡すのは怖いので, macOS の Seatbelt で範囲を絞っています.
モデルの判定に委ねる確率論的なガードレールには依存していません.

Seatbelt では, プロセスが触れられる範囲をプロファイルで決めます.
deny-default (既定で拒否) プロファイルを使っています.

| 種類 | 対象 | アクセス |
|---|---|---|
| ファイル | プロジェクト | 読み書き |
| ファイル | エージェントの状態 | 読み書き |
| ファイル | 一時ディレクトリ | 読み書き |
| ファイル | `/nix/store` | 読み取りのみ |
| 通信 | 外向き | 443 と DNS のみ |
| 通信 | loopback | ローカルの MCP サーバ |
| 通信 | Nix デーモン | UNIX socket |

外向きの 443 通信は許可しているため, 読み取れるデータの外部送信まで防ぐものではありません.

## 資格情報と危険な操作

GitHub の資格情報は, エージェント専用の **fine-grained PAT** にしています.
ラッパーが起動時にパスワードマネージャの CLI から読み, 使い捨てのディレクトリに `gh` の設定として置きます.
権限は読み取り中心で, 書き込みは Pull requests だけです.
個人の `gh` の設定は見えず, パスワードマネージャの CLI も実行できません.
PAT を取得できないときは起動を止めます.

サンドボックスだけでは危険な操作を細かく制御できないので, PATH の先頭に `git` と `nix` の shim を置いています.
`git` は commit や push を拒否し, `nix` はワークスペースの flake と許可したサブコマンドだけに絞ります.
PAT にも Contents の書き込み権限がないので, この PAT を使った GitHub への push はできません.

shim はストアのバイナリを直接実行すれば迂回できます.
事故の範囲を狭めるためのもので, 意図的な脱出まで防ぐものではありません.

## References

- [usabarashi/nix-config](https://github.com/usabarashi/nix-config)
- [Pi](https://pi.dev/)
- [earendil-works/pi](https://github.com/earendil-works/pi)
- [Pi のドキュメント](https://pi.dev/docs)
- [Agent Skills の仕様](https://agentskills.io/specification)
- [Model Context Protocol](https://modelcontextprotocol.io/)
- [home-manager](https://nix-community.github.io/home-manager/)
- [sandbox-exec(1)](https://keith.github.io/xcode-man-pages/sandbox-exec.1.html)
- [GitHub の fine-grained PAT](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
