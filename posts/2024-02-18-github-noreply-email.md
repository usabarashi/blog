---
title: "コミットに個人のメールアドレスを使わない"
date: "2024-02-18"
tags:
  - Git
  - GitHub
  - Nix
---

コミットには, 作者とコミッターのメールアドレスが記録されます.
個人のメールアドレスをそのまま使うと, リポジトリを見た人に公開されます.
GitHub は noreply アドレスを発行しているため, コミットにはそれを使うようにしました.

[![GitHub のコミットメール設定](https://docs.github.com/assets/cb-345/images/social-cards/account-and-profile.png)](https://docs.github.com/ja/account-and-profile/how-tos/email-preferences/setting-your-commit-email-address)

## GitHub が発行する noreply アドレス

GitHub のメール設定で「Keep my email addresses private」を有効にすると, noreply アドレスが発行されます.
形式は `<ID>+<username>@users.noreply.github.com` です.
アカウントが古い場合は `username@users.noreply.github.com` の形式になることがあります.
設定画面に表示されるアドレスをそのまま使います.

このアドレスは GitHub アカウントに紐づくため, コミットはアカウントに紐づきます.

## Git の設定を変える

設定画面に表示された noreply アドレスを, Git のコミット用メールアドレスに設定します.
Home Manager の git モジュールでは, `userEmail` を設定します.

```nix
programs.git = {
  enable = true;
  userName = "you";
  userEmail = "12345678+you@users.noreply.github.com";
};
```

`git config` で設定する場合も同じです.

```console
$ git config --global user.email "12345678+you@users.noreply.github.com"
```

この設定は, 新しく作成するコミットのメールアドレスの既定値になります.
既存のコミットのメールアドレスは変わりません.
cherry-pick などで author を引き継ぐ場合も, 元のメールアドレスが残ります.
公開済みのメールアドレスは, 履歴を書き換えても clone や fork などに残る可能性があります.

## References

- [GitHub でコミットのメールアドレスを設定する](https://docs.github.com/ja/account-and-profile/how-tos/email-preferences/setting-your-commit-email-address)
