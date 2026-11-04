---
title: "LAN のサービスを Zero Trust にする"
date: "2026-06-07"
tags:
  - Homelab
  - nginx
  - OAuth
  - Google
  - NixOS
  - Zero Trust
---

個人用のサービスを nginx の vhost に分け, `*.example.com` の名前を付けています.
サービスに届くのは LAN と tailnet の内側からだけです.
インターネット側には公開していません.
TLS はワイルドカード証明書で終端しています.

これまで, サービスを使えるかどうかは, ネットワークの内側から来たかどうかで決まっていました.
LAN か tailnet の内側にいれば, そこにいる誰でも同じようにサービスを使えました.
ネットワークの内側にいることだけでアクセスを許可する構成は, 接続元ではなく利用者で判断する **Zero Trust** の考え方に沿っていませんでした.

ネットワークの内側なら通すという前提を見直すきっかけになったのは, opencode の vhost を追加したことでした.
opencode のサーバはブラウザから任意のコードを実行できるので, ネットワークの内側からのアクセスを無条件に通すわけにはいきません.
内側の端末が 1 台侵害されれば, その端末から実行環境をそのまま使えてしまいます.
サービスごとに専用のアカウントを作って守ることもできますが, IaC の管理外でアカウントを手作業で作る運用は避けたいと考えました.
opencode 自身にも `OPENCODE_SERVER_PASSWORD` によるパスワード認証はありますが, その値を配布する運用が必要になります.
そこで nginx の `auth_request` から **oauth2-proxy** を呼び, ブラウザで画面を開く際に, Google アカウントで利用者を認証するようにしました.
oauth2-proxy は, OIDC のプロバイダを使ったログインをアプリの手前に足すソフトウェアです.
Google の認証を経た利用者にセッションクッキーを発行し, 以後のリクエストではそのクッキーでセッションを確認します.

ここで確かめるのは, ブラウザで画面を開くときの利用者だけです.
開いたあとの権限は, 各サービスに任せています.

[![oauth2-proxy のリポジトリカード](https://repository-images.githubusercontent.com/105262714/eeb5b100-faff-11e9-9b0b-a97d43094103)](https://github.com/oauth2-proxy/oauth2-proxy)

## 誰を通すか

通すアカウントのメールアドレスを, oauth2-proxy の許可リストに個別に指定しています.
使っているアカウントには, 誰でもメールアドレスを取得できるドメインのものも含まれています.
そのドメインを丸ごと許可することはできないためです.

opencode のパスワード認証も有効にすれば二重に守れますが, パスワードの配布や更新の手間が増えるため, 認証は nginx 側だけにしています.

## 認証をまとめて 1 か所に置く

nginx はすでに TLS の終端と vhost ごとの振り分けを担っているので, 認証もそこに置けばサービス側には何も足さずに済みます.
認証を挟んだサービスについては, ホストのファイアウォールでポートを開けていません.
LAN や tailnet からこれらのサービスにアクセスするには, ポート 443 で待ち受ける nginx を経由する必要があります.
上流は loopback か, コンテナ専用の veth で待ち受けています.
手前で止めれば, その先には届きません.

oauth2-proxy は 1 つだけ起動し, `127.0.0.1:4180` で受けます.
このポートに LAN や tailnet から直接届く経路はありません.
この oauth2-proxy がすべての vhost の認証を担当するので, 設定は 1 か所に収まります.

oauth2-proxy を入口に置いて中継させるのではなく, nginx から認証だけを問い合わせる構成にしました.
既存の `location` の `proxyPass` と `extraConfig` はそのままで, 認証の 2 行を足すだけです.
タイムアウトや WebSocket, buffering, 上流の IP 制限といった設定も, 各 vhost のものがそのまま効きます.

```nix
oauth2Gate = ''
  auth_request /oauth2/auth;
  error_page 401 = @oauth2_signin;
'';

gateLocations = gatedPaths: locations:
  if !oauth2Enabled then
    locations
  else
    (lib.mapAttrs (
      path: loc:
      if builtins.elem path gatedPaths then
        loc // { extraConfig = (loc.extraConfig or "") + "\n" + oauth2Gate; }
      else
        loc
    ) locations)
    // oauth2Endpoints;
```

ログインの入口 (`/oauth2/`) を認証の対象から外すため, この構成では保護する location にだけ `auth_request` を設定しています.
ヘルパーは, 渡した path にだけ認証を足し, それ以外の location は触りません.
`oauth2Endpoints` は, ログインの入口とサブリクエストの受け口を各 vhost に足すためのものです.

## 未認証のときに何が起きるか

![未認証のブラウザが Google のログインを経て上流に届くまで](/images/2026-06-07-nginx-google-sso-flow.svg)

未認証のリクエストでは, サブリクエストが 401 を返します.
`error_page 401 = @oauth2_signin` で named location に内部リダイレクトします.
`@oauth2_signin` が 302 を返し, ブラウザを `/oauth2/start` へ飛ばします.
`/oauth2/start` は oauth2-proxy が受けて, Google の認証画面へリダイレクトします.
ブラウザが `/oauth2/callback` に戻り, oauth2-proxy で認証と許可リストの確認に成功すると, セッションクッキーが発行されます.
その後, ブラウザは元の URL に戻ります.
有効なセッションがあるリクエストでは, サブリクエストが 2xx を返し, nginx が上流へ流します.

戻り先は `$scheme://$host$request_uri` で組み立てています.
ログインしたあとに元のホストへ戻すためです.
1 つの oauth2-proxy が複数のホストを受け持つので, どのホストから来たかはリクエストごとに変わります.
ログイン後の戻り先は, 親ドメインのホストに限って許可しています (`whitelist-domain`).

`/oauth2/auth` は `internal` にして外部からの直接アクセスを禁止し, この構成では `auth_request` のサブリクエストから呼びます.
`@oauth2_signin` は named location で, この構成では `error_page` の内部リダイレクト先です.
サブリクエストには元のリクエストのボディを送りません (`proxy_pass_request_body off`).

## Host ヘッダを重ねると 400 になる

この構成では, NixOS の nginx モジュールの `recommendedProxySettings` により, `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-Server` が各 proxy に付きます.
この include は `extraConfig` と同じ location に出るので, `Host` を `proxy_set_header` で足すと `Host` の行が 2 つになります.
`Host` が 2 行あると, Go の HTTP サーバは 400 を返します.
oauth2-proxy は Go 製なので, `/oauth2/` もサブリクエストも 400 になり, ログインの画面まで進めません.

oauth2-proxy へのプロキシには `Host` も `X-Forwarded-*` も書いていません.
コールバックの URL を作るのに使う `X-Forwarded-Host` も, `recommendedProxySettings` が付けるものをそのまま使います.

## 資格情報の置き場所

client ID は secret ではありません.
ブラウザとのやり取りでそのまま見えるので, Nix の設定に書いています.
client secret と cookie secret は sops に入れ, 実行時に 1 つの env ファイルへ書き出しています.
平文の secret は `/nix/store` に入りません.
このファイルは `services.oauth2-proxy.keyFile` に渡し, systemd の `EnvironmentFile` として root が読みます.

```nix
sops.templates."oauth2-proxy.env" = {
  content = ''
    OAUTH2_PROXY_CLIENT_SECRET=${config.sops.placeholder.oauth2-proxy-client-secret}
    OAUTH2_PROXY_COOKIE_SECRET=${config.sops.placeholder.oauth2-proxy-cookie-secret}
  '';
  mode = "0400";
  owner = "root";
  group = "root";
  restartUnits = [ "oauth2-proxy.service" ];
};

services.oauth2-proxy = {
  enable = true;
  provider = "google";
  inherit (cfg) clientID;
  keyFile = config.sops.templates."oauth2-proxy.env".path;
};
```

`OAUTH2_PROXY_` で始まる環境変数は, 設定ファイルの値より優先されます.
cookie secret は `openssl rand -base64 32` で作り, sops で暗号化してリポジトリに保存しました.

## Google 側で必要な作業

OAuth クライアントは Web application で作り, 認証を挟むホストごとに `https://opencode.example.com/oauth2/callback` のような URL を登録します.
クライアントは 1 つで足りますが, リダイレクト先はホストを増やすたびにコンソールで足すことになります.
同意画面は Testing のままで, 通すアカウントは Google 側の一覧にも登録しています.
scope は `openid`, `email`, `profile` だけです.
oauth2-proxy が読むのはアカウントの情報だけなので, これ以上は要りません.
同意画面と OAuth クライアントは, IAP 向けのものを除いて Terraform では管理できないため, この部分だけは手作業として残ります.

## おわりに

ネットワークの内側にいることに加えて, 誰が開いたかを確かめるようになりました.
認証を挟むサービスは, location に 2 行を足すだけで増やせます.

## References

- [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/)
- [nginx の auth_request モジュール](https://nginx.org/en/docs/http/ngx_http_auth_request_module.html)
- [Google Identity の OAuth 2.0](https://developers.google.com/identity/protocols/oauth2/web-server)
- [sops-nix](https://github.com/Mic92/sops-nix)
