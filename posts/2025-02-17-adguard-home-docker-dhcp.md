---
title: "AdGuard Home の広告ブロック DNS を DHCP で端末に設定する"
date: "2025-02-17"
tags:
  - Homelab
  - Docker
  - Debian
  - AdGuard Home
  - DNS
  - DHCP
---

DNS で広告とトラッカーのドメインをブロックしています.
各端末にこの DNS サーバを使わせるために, DHCP で DNS サーバのアドレスを配っています.

[![AdguardTeam/AdGuardHome のリポジトリカード](https://opengraph.githubassets.com/1/AdguardTeam/AdGuardHome)](https://github.com/AdguardTeam/AdGuardHome)

## DNS で広告を止める

端末ごとにブロッカーを入れると, 設定は端末の数だけ増えます.
アプリを追加できない機器では, この方法は使えません.
DNS を 1 か所に集めれば, LAN の端末に同じフィルタをかけられます.
AdGuard Home には公開されているフィルタリストを 2 本登録し, セーフサーチとブロック対象のサービスも DNS 側で指定しました.
上流 DNS サーバへの問い合わせは DoH にして, LAN の外に出る通信を暗号化しています.
LAN 内のホスト名も AdGuard Home で管理し, 固定の IP アドレスを返す書き換えを設定しています.

```yaml
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  upstream_dns:
    - https://dns10.quad9.net/dns-query
  bootstrap_dns:
    - 9.9.9.10
filtering:
  filtering_enabled: true
  safe_search:
    enabled: true
  rewrites:
    - domain: app.home.example
      answer: <HOST_IP>
```

`dns` と `filtering` の各項目は, AdGuard Home の[設定リファレンス](https://adguard-dns.io/kb/adguard-home/configuration/)にあります.

AdGuard Home はコンテナで動かし, UDP と TCP の 53 番で待ち受けます.
通常の問い合わせは UDP で, 応答が大きいときなどに TCP が使われます.

## DHCP で DNS サーバのアドレスを配る

各端末に DNS サーバを使わせるには, 1 台ずつ設定するより DHCP で配るほうが確実です.
LAN に繋ぐと, 使う DNS サーバが自動で決まります.
DHCP のオプション 6 では, クライアントに配る DNS サーバのアドレスを指定します.
これまでは, dnsmasq が DHCP だけを担当し, DNS 機能は無効にしていました.

```text
port=0
dhcp-range=set:lan,<POOL_START>,<POOL_END>,255.255.255.0,24h
dhcp-option=tag:lan,option:router,<LAN_GATEWAY>
dhcp-option=tag:lan,option:dns-server,<HOST_IP>
dhcp-option=tag:lan,option:domain-name,home.example
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
dhcp-authoritative
```

dnsmasq がクライアントに配っていたのは, 次の 3 つの値です.

| オプション | 値 | 役割 |
|---|---|---|
| 3(ルーター) | `<LAN_GATEWAY>` | 既定ゲートウェイ |
| 6(DNS サーバ) | `<HOST_IP>` | AdGuard Home を動かすホスト |
| 15(ドメイン名) | home.example | クライアントに配るドメイン |

オプション 6 に指定していたのは, AdGuard Home のコンテナのアドレスではなく, ホストの LAN 側のアドレスでした.
ホストの 53 番ポートで受けた問い合わせをコンテナへ転送していたので, クライアントから見た DNS サーバはホストになります.
DHCP サーバ自身にも固定のアドレスが必要で, 設定はホストのアドレスとインターフェースに依存します.

DHCP の担当を AdGuard Home に移したあとも, 配る DNS サーバのアドレスは変えていません.

```yaml
dhcp:
  enabled: true
  interface_name: br0
  local_domain_name: home.example
  dhcpv4:
    gateway_ip: <LAN_GATEWAY>
    subnet_mask: 255.255.255.0
    range_start: <POOL_START>
    range_end: <POOL_END>
    lease_duration: 86400
    options:
      - 6 ips <HOST_IP>
      - 15 text home.example
```

`dhcp` 以下の項目と `clients` の設定は[設定リファレンス](https://adguard-dns.io/kb/adguard-home/configuration/)にあります.
`options` の `6 ips` や `15 text` の書式は [DHCP サーバ](https://adguard-dns.io/kb/adguard-home/dhcp/)にあります.

最初は公開 DNS サーバのアドレスも並べていましたが, クライアントはどちらのサーバにも問い合わせます.
問い合わせが公開 DNS サーバに送られるとフィルタを通らないため, 広告が消えない端末が出ました.
いまはオプション 6 に AdGuard Home のアドレスだけを指定し, VPN の DNS 設定でも別のサーバは指定していません.

オプション 15 で配るドメインは, `local_domain_name` の値と揃えました.
DHCP の要求でクライアントが送ってくるホスト名は, このドメインで解決できます.
`local_domain_name` の既定値は `lan` で, ここでは LAN のドメインを指定しました.
`clients.runtime_sources.dhcp` を有効にすると, クエリログや統計に出すクライアント名もリースから取得できます.
端末ごとにフィルタや上流を変えるときは, 端末の IP アドレスや MAC アドレスを識別子にします.

## DHCP を動かすためにホストのネットワークを使う

DHCP は UDP を使い, サーバは 67 番, クライアントは 68 番で待ち受けます.
IP アドレスをまだ持たないクライアントは, DHCP サーバのアドレスも知りません.
そのため, クライアントは LAN 内の機器に一斉に届くブロードキャストで, 255.255.255.255 宛に要求を送ります.
サーバはクライアントの MAC アドレス宛かブロードキャストで応答し, このやり取りはサーバとクライアントが同じブロードキャストドメインにいないと成立しません.

Docker のブリッジネットワークは LAN とは別の L2 セグメントなので, LAN 内のブロードキャストはそこへ届きません.
`ports:` によるポート公開では, ホストのアドレス宛のユニキャスト通信をコンテナへ転送します.
UDP のブロードキャストは転送されません.

DNS だけを提供する場合と, DHCP も提供する場合で, コンテナのネットワークは次のように変わります.

| 項目 | DNS だけ | DNS と DHCP |
|---|---|---|
| ネットワーク | ブリッジ | ホスト |
| 53 番(UDP/TCP) | ホストから公開 | コンテナが直接使う |
| 67 番(UDP) | 使わない | コンテナが直接使う |
| 管理画面 | コンテナ名で転送 | ホストのアドレス:8080(TCP) |
| コンテナ名による名前解決 | 可能 | 不可 |

LAN 側の NIC をブリッジに接続し, コンテナも同じブリッジに繋ぐ方法や, DHCP リレーを置く方法はあります.
リレーは, 別のセグメントにある DHCP サーバへブロードキャストを転送する仕組みで, LAN 側の機器に設定が必要です.
この LAN ではどちらの方法も使っていないため, コンテナを `network_mode: "host"` で動かしています.
この構成では, `NET_ADMIN` も付与しています.

AdGuard Home のドキュメントも, DHCP を使うコンテナには host ネットワークを指定するよう求めています.
この場合, `-p` によるポートの対応づけは要りません.

```yaml
  dns:
    network_mode: "host"
    cap_add:
      - NET_ADMIN
    expose:
      - 53/tcp
      - 53/udp
      - 67/udp
      - 8080/tcp
```

host モードではポートの対応づけがないため, `expose:` の一覧はどのポートを使うかを示すメモになります.

ホストのネットワークで動かすと, 経路は次のようになります.

![LAN のクライアントから AdGuard Home と上流 DNS までの経路](/images/2025-02-17-adguard-home-docker-dhcp-paths.svg)

dnsmasq は 67 番を使っていたので, そのままでは同じ LAN に DHCP サーバが 2 台並び, 配るアドレスもリースの記録も食い違います.
そのため, AdGuard Home への移行と同時に dnsmasq のサービスを削除しました.
dnsmasq は DNS 機能を無効にしていたので, 53 番ポートは空いていました.

`interface_name` には, ホストの LAN 側のインターフェース名を書きます.
このホストでは NIC がブリッジ `br0` に接続され, IP アドレスも `br0` に設定されていました.
インターフェース名が変われば DHCP は止まるので, NIC を替えたときはここも直します.

## ホスト側で必要になった設定

ホストの 80 番ポートは nginx のコンテナが使っているため, 管理画面のポートを 8080 番に変更しました.
nginx の転送先もホストのアドレスに変えています.

```nginx
server {
  listen 80;
  server_name adguard.home.example;
  location / {
    proxy_pass http://<HOST_IP>:8080;
  }
}
```

AdGuard Home は 0.0.0.0 で待ち受けるため, ホストのすべての IPv4 アドレスで応答します.
53 番ポートを LAN の外に公開しないよう, ルータ側の設定も必要です.
ホストのファイアウォールのルールは, DNS と DHCP の通信にも適用されます.
VPN のクライアントにも LAN の DNS を使わせていたので, VPN のサブネットから UDP と TCP の 53 番を許可しました.

```sh
sudo iptables -A INPUT -s <VPN_SUBNET> -p tcp --dport 53 -j ACCEPT
sudo iptables -A INPUT -s <VPN_SUBNET> -p udp --dport 53 -j ACCEPT
```

ホスト自身が使う DNS サーバは, AdGuard Home とは別に用意しておきます.
ホストもこの DNS だけを使っていると, コンテナが起動していない間は復旧作業が進みません.
ブートストラップ DNS サーバは IP アドレスで指定しました.
LAN の DNS を使うと, AdGuard Home が停止したときに上流 DNS サーバのホスト名も解決できなくなります.

## 設定ファイルの保存先と管理

Compose ファイルと AdGuard Home の設定は, 同じリポジトリで管理しています.
設定はコンテナの `/opt/adguardhome/conf` に, 管理画面のデータは `/opt/adguardhome/work` に置き, `work/data` はリポジトリに入れません.
管理画面で設定を変更すると `AdGuardHome.yaml` にも書き込まれるため, リポジトリの差分として確認できます.
起動中に設定ファイルを直接編集しても, その変更は読み込まれません.
管理画面で保存したときや, プロセスが終了するときに, 実行中の設定でファイルが上書きされます.
設定ファイルを直接編集するときは, コンテナを止めてから書き換え, 再起動します.
`docker compose up -d` は Compose の定義が変わらなければコンテナを再作成しないため, 設定ファイルだけを変えたときは `docker compose restart` を使います.
管理画面のユーザー名とパスワードのハッシュも, この YAML に入ります.

## References

- [AdGuard Home: DHCP server](https://adguard-dns.io/kb/adguard-home/dhcp/)
- [AdGuard Home: Docker](https://adguard-dns.io/kb/adguard-home/docker/)
- [AdGuard Home: Configuration](https://adguard-dns.io/kb/adguard-home/configuration/)
- [RFC 2131: Dynamic Host Configuration Protocol](https://datatracker.ietf.org/doc/html/rfc2131)
