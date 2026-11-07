---
title: "Google Password Manager から 1Password Families へ移行した"
date: "2026-08-11"
tags:
  - 1Password
  - Google
  - Security
  - macOS
---

パスワードは Google Password Manager に保存していました.
Chrome の自動入力がそのまま使え, 無料で使えるためです.
1Password Families を使えることを知り, ログイン情報以外もまとめて管理するために, パスワードを 1Password に移しました.

移行は, Google Password Manager から書き出した CSV を 1Password に読み込んで行いました.
CSV にはパスワードが平文で並ぶため, 同期やバックアップの対象外の場所で扱い, 読み込みと確認が済んだら削除します.
パスキーと, 認証アプリに登録した 2 要素認証の設定は, この CSV では移せません.

[![1Password Families の製品ページ](https://images.ctfassets.net/2h488pz7kgfv/6J5gyruO6TFICB9EoqhJ43/84655eeec31d3e7d0dc1d79d69254323/consumer-homepage-opengraph.jpg)](https://1password.com/families/)

## Google Password Manager で足りていた範囲

Google Password Manager では, パスワードを Google アカウントに保存できます.
アカウントに保存したパスワードは, Chrome の設定画面や passwords.google.com で管理でき, 同じアカウントを使うほかの端末でも利用できます.
Google Password Manager はパスキーの保存にも対応しています.

Google Password Manager にもメモ欄はありますが, ログイン情報に付随するものです.
1Password なら, ソフトウェアのライセンスや契約情報のメモを独立した項目として保存できます.

## 1Password Families のアカウント

**1Password Families** は, 家族で使うためのプランです.
個人用の Families アカウントを作りました.

そのアカウントには, **Private の保管庫**と, 家族で使う**共有の保管庫**があります.
共有の保管庫は使っていません.

アカウントの作成時に, パスワードとは別に **Secret Key** が生成されます.
新しい端末でサインインするには, アカウントのパスワードと Secret Key の両方が要ります.
Secret Key は **緊急キット**に記載されるので, 移行の前に印刷し, パスワードとは別の場所に保管します.
アカウントのパスワードも, 1Password の中だけに保存しないようにします.
1Password アカウントの 2 要素認証を有効にする場合は, 1Password にアクセスできない状態でも認証アプリなどを使えるようにしておきます.

## Watchtower

1Password の **Watchtower** では, 既知の漏えいデータに含まれるパスワードや, 弱いパスワード, 使い回しているパスワードを確認できます.
Google Password Manager の「パスワード チェックアップ」でも, 同様の確認ができます.
移行した直後に一度確認し, 指摘された項目はパスワードを変更します.

## 1Password のブラウザ拡張機能

[![1Password のブラウザ拡張機能](https://images.ctfassets.net/2h488pz7kgfv/4G0Jp3YPCatBnrwomMvOMC/345ac51aff4f82ddf0025281942b75e6/downloads-browser-extension-open-graph-graphic-1200x630.jpg)](https://1password.com/downloads/browser-extension)

1Password のブラウザ拡張機能とデスクトップアプリの連携を有効にします.
Touch ID 対応の Mac では, アプリで Touch ID によるロック解除も有効にすると, 拡張機能のロック解除にも使えます.
ただし, アカウントのパスワードの入力が必要になる場合もあります.

## 1Password CLI

[![1Password CLI のドキュメント](https://ab-634991b8.mintlify.site/_mintlify/api/og/v2?division=CLI&title=1Password+CLI&theme=0e8ac3e29b6f66038c473d59&signature=8ea40665311c54bacdb1bcae269d9e0e33cbbd4c44a05a4ddf7c101e8f9b3727)](https://developer.1password.com/docs/cli/)

1Password の CLI である **op** を使うと, 保存したパスワードをスクリプトから参照できます.
デスクトップアプリの設定で「Integrate with 1Password CLI」を有効にすると, op の認証を Touch ID で行えます.
秘密情報は op:// の参照で渡し, 値をスクリプトや設定ファイルに書きません.

```console
$ export EXAMPLE_TOKEN='op://Private/example/credential'
$ op run -- ./deploy.sh
```

環境変数に op:// の参照を書いておくと, op run が値を差し替えてコマンドを実行します.
op read は値を標準出力に出すため, 端末の表示やログへの露出に注意します.

direnv を使う場合は, .envrc から op read を呼び出して値を環境変数に設定できます.
nix-direnv と組み合わせると, 許可済みのディレクトリに入ったときに devShell と秘密情報を読み込めます.
必要に応じて 1Password の認証を求められます.
値を設定ファイルに保存せずに済みますが, 環境変数や実行ログから漏れないように注意が必要です.

```text
use flake
EXAMPLE_TOKEN="$(op read 'op://Private/example/credential')" || return 1
export EXAMPLE_TOKEN
```

## 1Password for SSH & Git

[![1Password for SSH & Git のドキュメント](https://ab-634991b8.mintlify.site/_mintlify/api/og/v2?division=SSH+%26+Git&title=1Password+for+SSH+%26+Git&theme=0e8ac3e29b6f66038c473d59&signature=bd4ee039d7109cef30b6f1d150391804bbaffb5f50a383896c4a6f17cfa87822)](https://developer.1password.com/docs/ssh/)

SSH 鍵は, 1Password の SSH エージェントでも使えます.
使う SSH 鍵は, あらかじめ 1Password で作成するか, 既存の鍵をインポートします.
1Password の SSH エージェントに切り替える場合は, デスクトップアプリで「Use the SSH agent」を有効にし, SSH クライアントが使う認証エージェントを 1Password の socket に指定します.
macOS では, ~/.ssh/config の `IdentityAgent` を次のように変更します.

```text
Host *
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
```

秘密鍵を通常のファイルとして保存する必要はありません.
鍵の利用時には, 必要に応じて Touch ID などで承認します.
Git 側で署名の設定をすると, コミット署名にも使えます.

SSH 鍵は [Secretive](/posts/secretive-ssh-signing.html) で Secure Enclave に置いています.
Secretive も SSH エージェントとして動き, 鍵の利用時に認証を要求します.
1Password の SSH エージェントとの違いは, 鍵をどこに置き, どこまで持ち出せるかです.

| 項目 | Secretive | 1Password |
|---|---|---|
| 鍵の保存先 | Secure Enclave | 1Password の保管庫 |
| 生成できる鍵 | P-256 | Ed25519, RSA |
| 同じ秘密鍵を複数端末に保存 | できない | できる |
| 秘密鍵のエクスポート | できない | できる |
| 利用時の承認 | Touch ID など | Touch ID など |

SSH の認証は Secretive のままにし, 1Password にはログイン情報を置いています.
1Password の SSH エージェントにまとめれば, 鍵の管理も 1 か所になります.
Mac を買い替えると Secretive の鍵は作り直しになり, 接続先に公開鍵を登録し直す必要があります.
そのタイミングで, 1Password で新しい鍵を作り, SSH エージェントを切り替えるか検討します.

## References

- [1Password Families](https://1password.com/families/)
- [緊急キット (1Password Support)](https://support.1password.com/emergency-kit/)
- [Watchtower (1Password Support)](https://support.1password.com/watchtower/)
- [パスキー (1Password Support)](https://support.1password.com/passkeys/)
- [1Password のブラウザ拡張機能](https://1password.com/downloads/browser-extension)
- [1Password CLI](https://developer.1password.com/docs/cli/)
- [1Password の SSH エージェント](https://developer.1password.com/docs/ssh/)
- [Secretive で SSH 鍵を Secure Enclave に置く](/posts/secretive-ssh-signing.html)
- [Secretive の FAQ](https://github.com/maxgoedjen/secretive/blob/main/FAQ.md)
- [Google Password Manager](https://passwords.google.com/)
- [Chrome でパスワードを管理する (Google Chrome ヘルプ)](https://support.google.com/chrome/answer/95606)
- [パスワード チェックアップ](https://passwords.google.com/checkup)
