---
title: "SSH 鍵を Secure Enclave に置き, GitHub への認証とコミット署名を Secretive にまとめる"
date: "2026-05-08"
tags:
  - macOS
  - Nix
  - Git
  - SSH
  - Coding Agent
---

SSH の認証には, ファイルに保存した秘密鍵を使っていました.
コーディングエージェントも同じユーザ権限で動く場合, そのファイルにアクセスできる可能性があります.
自分の知らないうちに鍵を使われるのは避けたいので, **Secretive** を導入し, 鍵の利用時に認証を要求するように設定しました.

[![Secretive のリポジトリカード](https://repository-images.githubusercontent.com/241524703/0d0181ba-2467-46c3-9eb3-399334198b91)](https://github.com/maxgoedjen/secretive)

## Secure Enclave で防げることと, 利用時の認証

同じユーザ権限で動くプログラムなら, コーディングエージェントに限らず秘密鍵を読み取れる可能性があります.
パスフレーズで保護していなければ, そのまま認証や署名に使われる可能性があります.
パーミッションを絞っても, 秘密鍵そのものの複製は防げません.

Secure Enclave は, 鍵素材を外に出さずに署名を返す領域です.
秘密鍵は Secure Enclave の外へ書き出せないため, エクスポートもバックアップもできません.
Secretive は, Secure Enclave の SSH 鍵を管理し, SSH の署名要求に応じて署名を返す macOS のアプリです.
ただし, 同じユーザで動くコーディングエージェントなどのプログラムは, 秘密鍵を取り出せなくても Secretive に署名を要求できます.
意図しない鍵の利用を防ぐには, 秘密鍵を取り出せなくするだけでなく, Secretive で鍵の利用時に認証を要求する設定も必要です.
認証は要求元が人間か AI かを判別しないため, 意図しない要求は承認しないようにします.

## Secretive を認証と署名の共通エージェントにする

**SSH エージェント**は, クライアントからの要求に応じて署名を返すプログラムです.
ssh と Git は, Secretive の SSH エージェントを通して Secure Enclave 内の鍵を使います.

Secretive には SecretAgent が同梱されていて, セットアップするとログイン項目として登録されます.
SecretAgent はログイン中の GUI セッションで動きます.
ログインしていない状態では署名できません.
このエージェントが `~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh` で待ち受けます.
クライアントはこの socket に接続し, 鍵の一覧と署名をやり取りします.

![git と ssh が Secretive の socket を通って Secure Enclave の鍵で署名し, GitHub が登録済みの公開鍵で検証する](/images/2026-05-08-secretive-agent-path.svg)

ssh は `IdentityAgent` で接続先のエージェントを決められます.
一方, Git の署名に使う `ssh-keygen -Y sign` は ssh の設定を読まず, 環境変数 `SSH_AUTH_SOCK` からエージェントを探します.
そのため, 設定ファイルと環境変数の両方で同じ socket を指すようにします.

## 鍵と設定ファイルを準備する

Secretive は Nix で導入します.

```nix
home.packages = [ pkgs.secretive ];
```

Home Manager の設定を適用し, Secretive を起動して初期設定を済ませます.
鍵の生成は Secretive で行い, 公開鍵ファイルは手で置きます.

| 対象 | 管理 |
|---|---|
| `pkgs.secretive` の導入 | Nix |
| SSH エージェントの接続先 | Nix |
| 認証と署名に使う公開鍵のパス | Nix |
| 署名形式と検証用ファイルのパス | Nix |
| 鍵の生成 | Secretive |
| 公開鍵ファイルの中身 | 手作業 |
| 検証用ファイル (`allowed_signers`) の中身 | 手作業 |
| GitHub への公開鍵の登録 | 手作業 |

Secure Enclave が作る鍵は P-256 です.
Secure Enclave には既存の秘密鍵を取り込めないため, 新しい鍵を作ります.

1. Secretive で鍵を作ります.
2. 鍵の利用時に認証を要求する設定を有効にします.
3. Secretive が書き出した公開鍵を `~/.ssh/github.pub` と, Home Manager の `config.xdg.configHome` 配下の `git/signing-key.pub` に置きます.
   `config.xdg.configHome` が既定値なら, 後者は `~/.config/git/signing-key.pub` です.

## GitHub への SSH 認証を設定する

Home Manager では, SSH の設定を次のように書きます.

```nix
let
  secretiveSocket = "${config.home.homeDirectory}/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh";
  githubAuthKeyPath = "${config.home.homeDirectory}/.ssh/github.pub";
in
{
  home.sessionVariables.SSH_AUTH_SOCK = secretiveSocket;

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      "*" = {
        extraOptions = {
          IdentityAgent = secretiveSocket;
        };
      };

      "github.com" = {
        identityFile = githubAuthKeyPath;
        identitiesOnly = true;
        user = "git";
      };
    };
  };
}
```

`identityFile` には秘密鍵ではなく, Secretive が書き出した公開鍵を置いたパスを指定します.
ssh はこの公開鍵に対応する鍵を選び, エージェントに署名を要求します.
`identitiesOnly` を有効にすると, エージェントが持つほかの鍵を提示しません.
GitHub は認証の試行が多すぎると接続を切るので, 提示する鍵は絞ります.

`user` は `git` に固定しました.
`github.com:owner/repo` のような省略形のリモートではユーザ名が省略されるため, ローカルのユーザ名が使われてしまうからです.

この公開鍵は, GitHub のアカウントに認証鍵として登録します.

## コミットとタグへの署名を設定する

続いて, Secretive の鍵をコミットやタグへの署名にも使います.

### 署名を付ける

署名の形式は `gpg.format` で選びます.
`ssh` を指定すると, Git は GPG ではなく SSH の鍵で署名します.
署名鍵にも, 秘密鍵ではなく公開鍵のパスを指定します.
ローカルでの署名検証に使う `allowed_signers` のパスも指定します.
内容は次節で説明します.

```nix
let
  signingKeyPath = "${config.xdg.configHome}/git/signing-key.pub";
  allowedSignersPath = "${config.xdg.configHome}/git/allowed_signers";
in
{
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "you";
        email = "you@example.com";
        signingKey = signingKeyPath;
      };

      commit.gpgSign = true;
      tag.gpgSign = true;

      gpg = {
        format = "ssh";
        ssh.allowedSignersFile = allowedSignersPath;
      };
    };
  };
}
```

### 署名を検証する

GitHub でコミット署名を検証するには, 公開鍵をアカウントに署名鍵として登録します.
認証用の鍵とは別の種類として登録する必要があります.
同じ公開鍵を両方に登録することもできます.
コミッターのメールアドレスには, 署名鍵を登録した GitHub アカウントの検証済みメールアドレスを使います.
個人のメールアドレスを公開したくない場合は, [GitHub の noreply アドレスを使う](/posts/github-noreply-email.html)方法があります.

`allowed_signers` は, ローカルでの署名検証に使うファイルです.
設定例の `gpg.ssh.allowedSignersFile` がこのファイルを指します.
`allowed_signers` には principal と署名用の公開鍵を書きます.
**principal** は署名者を識別する名前で, メールアドレスを書くのが一般的です.

```text
you@example.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBB...
```

`allowed_signers` がないと, 署名が付いていてもローカルでは検証できません.
`git log --show-signature` を実行すると, このファイルに書かれた principal と公開鍵で検証されます.

## 移行と鍵の再生成

ファイルに保存していた鍵から移行する場合は, 新しい鍵で GitHub に接続できることを確認してから, GitHub に登録した古い認証鍵を削除します.
署名鍵を登録していた場合は, 新しい鍵でコミットに署名します.
GitHub で検証されることを確認してから, 古い署名鍵を削除します.
古い秘密鍵ファイルは, ほかの接続先でも不要になったことを確認してから削除します.

鍵を作り直すときは, 新しい公開鍵を GitHub に認証鍵と署名鍵として登録します.
公開鍵を同じパスに置けば, Nix の設定は変えずに済みます.
`allowed_signers` には新しい公開鍵を追加します.
過去の署名もローカルで検証する場合は, 古い公開鍵も残します.

## おわりに

GitHub への認証とコミット署名を Secretive にまとめ, 秘密鍵をファイルとして持たなくなりました.
SSH と Git の設定は Nix で管理し, 秘密鍵は Secure Enclave に保持します.

## References

- [Secretive](https://github.com/maxgoedjen/secretive)
- [Secretive の FAQ](https://github.com/maxgoedjen/secretive/blob/main/FAQ.md)
- [GitHub でのコミット署名の検証](https://docs.github.com/ja/authentication/managing-commit-signature-verification/about-commit-signature-verification)
- [コミットに個人のメールアドレスを使わない](/posts/github-noreply-email.html)
- [git-config の gpg.ssh.allowedSignersFile](https://git-scm.com/docs/git-config#Documentation/git-config.txt-gpgsshallowedSignersFile)
- [ssh-keygen の SIGNING](https://man.openbsd.org/ssh-keygen#SIGNING)
