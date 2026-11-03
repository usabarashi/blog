---
title: "llama.cpp で Qwen3.6 35B-A3B を動かし, メニューバーから管理する"
date: "2026-07-26"
tags:
  - llama.cpp
  - Qwen
  - SwiftBar
  - Nix
  - macOS
---

コーディングエージェントには, 普段はクラウドのモデルを使っています.
ネットワークが不通になったときや, プロバイダで障害が起きたときのバックアップとして, ローカルの LLM 環境を用意しました.
性能はプロバイダが提供するモデルには遠く及ばず, あくまで緊急時のバックアップという位置づけです.

今回使う量子化ファイルは 18 GB 前後あり, 読み込むとその重みがメモリに載ります.
バックアップのためにそれを常駐させると, ふだん使わないあいだもメモリを占有し続けます.
そこで, 必要なときだけ起動するようにしました.

使っているのは llama.cpp の **llama-server** です.
Nix でビルドし, 起動と停止は SwiftBar のメニューバーから行います.

![SwiftBar プラグイン, 起動スクリプト, llama-server の関係](/images/2026-07-26-llamacpp-qwen-swiftbar.svg)

## llama-server を直接動かす

llama-server はモデルの読み込み, 推論, HTTP API, Web UI を 1 つのプロセスで担います.
Web UI が同梱されていることも, llama.cpp を選んだ理由の 1 つです.
エージェントを介さずに, ブラウザから同じモデルと話せます.

[![ggml-org/llama.cpp のリポジトリカード](https://repository-images.githubusercontent.com/612354784/8b9eb0ec-6517-44a9-8a3a-fccddc678e57)](https://github.com/ggml-org/llama.cpp)

OpenAI 互換の `/v1/chat/completions` を提供するので, クライアントはモデルの提供元を意識せずに接続できます.

最初は Ollama で同じモデルを動かしていました.
Ollama では, Modelfile で派生モデルを作り, GPU に載せる層の数を指定していました.
llama-server では同じ指定を `-ngl` で行い, さらに KV キャッシュの型, 投機的デコード, 思考の有無, サンプラも起動引数で指定できます.
調整したい項目がすべて起動引数にあるので, 間に別のランナーを挟まずに指定できます.

`-hf` にリポジトリ名と量子化形式を指定すると, キャッシュに無ければモデルを取得します.
取得したファイルは Hugging Face のキャッシュに残り, 起動のたびにそこから読み込みます.
取得済みのモデルに切り替えるときは, キャッシュから読み込むので再取得は要りません.
ただし, `-hf` は起動時にリポジトリを参照するため, ネットワークが無い状況での起動は保証できません.
確実に起動するには, 取得済みの GGUF を `-m` に渡します.

## Nix でビルドする

ビルドの設定は, nix-config リポジトリの flake にまとめています.

[![usabarashi/nix-config のリポジトリカード](https://opengraph.githubassets.com/1564b0c5ab8728bdb03e89694657d33bd7feba4f7c77de9217b33790275fb353/usabarashi/nix-config)](https://github.com/usabarashi/nix-config)

llama.cpp は nixpkgs のパッケージをそのまま使わず, CPU の動的ディスパッチと BLAS の設定を変え, GPU を要求するテストを 1 つ除外してビルドします.

```nix
llamaCpp = (pkgs.llama-cpp.override {
  cpuArchDynamicDispatch = false;
  blasSupport = true;
}).overrideAttrs (old: {
  # The Nix build runs tests without a GPU.
  disabledTests = (old.disabledTests or [ ]) ++ [ "test-metal-graph-optimize" ];
});
```

テストの除外は, nixpkgs のテスト環境が GPU を持たないことへの対処です.
nixpkgs の checkPhase は `GGML_METAL_DEVICES=0` を設定しますが, この変数はデバイスの個数を表すので, テストのプロセスは Metal のデバイスを 1 つも登録しません.
その状態で GPU を前提とする `test-metal-graph-optimize` を走らせると, デバイスが存在することを前提にした assert に失敗して落ちます.

ビルドした `llama-server` のパスは, 起動スクリプトにビルド時に埋め込みます.
どのバージョンの llama.cpp で動いているかは `flake.lock` で決まります.

## Qwen3.6 35B-A3B の起動引数

Qwen3.6 35B-A3B は **MoE** (mixture of experts) のモデルで, パラメータは 35B ありますが, 1 トークンの処理で活性化するのは約 3B です.
重み全体はメモリに載りますが, 全パラメータを毎トークンの計算に使う通常の dense モデルより, 計算量を抑えられます.

[![unsloth/Qwen3.6-35B-A3B-MTP-GGUF のモデルカード](https://cdn-thumbnails.huggingface.co/social-thumbnails/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF.png)](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF)

起動時のコマンドラインは次のようになります.

```bash
"$LLAMA_BIN" \
  -hf unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-IQ4_NL \
  --alias qwen3.6-35b-a3b \
  -c 65536 \
  --spec-type draft-mtp --spec-draft-n-max 2 \
  --temp 0.6 --top-p 0.85 --top-k 30 --min-p 0.1 \
  -rea off --no-mmproj \
  -ngl 99 --flash-attn on \
  --cache-type-k q4_0 --cache-type-v q4_0 \
  --cache-reuse 0 --cache-ram 0 \
  --slot-save-path ~/.cache/llama-server-slots \
  -b 4096 -ub 1024 \
  --jinja \
  --webui-mcp-proxy \
  --webui-config-file ~/.config/llama-server/webui.json \
  --tools read_file \
  --host 127.0.0.1 --port 18080
```

`-ngl 99` で全層を GPU に載せ, コンテキストは 65536 トークン確保します.
32 GiB の Mac では Metal の working set の上限が 25 GiB 前後になるので, モデルと KV キャッシュに加えて, 推論のバッファと投機的デコードのぶんも見込む必要があります.
手元の構成では, KV キャッシュを q4_0 にして 65k のコンテキストを確保しています.
メモリをモデルと KV キャッシュに回すため, プロンプトキャッシュは切っています.

**MTP** (multi-token prediction) は, モデルに同梱された小さなヘッドで続く数トークンを先に書き, 本体のモデルがまとめて検証する仕組みです.
先読みしたトークンが採用されるほど decode が速くなり, 棄却された分は本体の計算に戻ります.
Qwen3.6 は注意機構と SSM 層を組み合わせたハイブリッド構成のため, 棄却時に SSM の状態を巻き戻す必要があり, llama.cpp に巻き戻しが実装されてから使えるようになりました.
先読みするトークン数は 2 にしています.
llama.cpp の MTP 対応の PR では, unified memory を持つ機材で, 先読みを 2 トークンにすると生成速度が 1.199 倍, 3 トークンにすると 1.153 倍になると報告されています.

`-rea off` は思考を無効にする指定です.
エージェントは 1 つの作業で何度もモデルを呼ぶので, 呼び出しのたびに思考トークンのぶん待ち時間が増えます.
`--no-mmproj` は視覚用の projector を読まない指定で, `--jinja` はモデルに同梱されたチャットテンプレートを使う指定です.
サンプラは温度 0.6, top-p 0.85, top-k 30, min-p 0.1 にしています.

## モデルを切り替える起動スクリプト

以前は launchd の `ProgramArguments` にモデルと引数を書いていました.
モデルを変えるたびに構成を適用し直す必要があったので, モデル名を引数で受け取るスクリプトに移しました.
起動と停止は, SwiftBar から呼ぶ `switch-to.sh` が担います.

SwiftBar は `param1` でモデル名を渡すので, スクリプトはそれに応じて引数を組み立て, `nohup` で `llama-server` を起動します.
`stopped` が渡されたときは, モデルを起動せずにサーバを止めます.

停止はポートを基準にします.
このポートは `llama-server` 専用として運用しているので, 待ち受けているプロセスは通常 `llama-server` だけです.
以下は, 接続中のクライアントを巻き込まないよう, 停止対象を TCP の待ち受けプロセスに限定した例です.
リポジトリの [switch-to.sh](https://github.com/usabarashi/nix-config/blob/main/config/llama-server/switch-to.sh) には, この限定が入っていません.
別のプロセスがこのポートを掴んだ場合は, そのプロセスも止まります.

```bash
PORT=18080

kill_server() {
  local pids
  pids=$(lsof -nP -t -iTCP:$PORT -sTCP:LISTEN 2>/dev/null || true)
  [ -n "$pids" ] || return 0
  kill -TERM $pids 2>/dev/null || true
  for _ in $(seq 1 10); do
    lsof -nP -t -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || return 0
    sleep 1
  done
  pids=$(lsof -nP -t -iTCP:$PORT -sTCP:LISTEN 2>/dev/null || true)
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
}
```

起動は `nohup` で行うので launchd のジョブはありません.
止める対象はポートを基準に決まるので, 起動の経路が変わっても同じ手順で止められます.

モデルを切り替えるときは, スロットのファイルを消します.
スロットにはモデルの状態が入っていて, アーキテクチャが変わると読み直せないためです.
スロットのディレクトリは, 構成を適用するときに作ります.

ログは `~/.cache/llama-server/llama-server.log` に追記します.
起動時に 100 MB を超えていれば `.old` に退避し, 古い方は次の起動で上書きします.

## SwiftBar プラグインの状態判定

プラグインは `~/Library/Application Support/SwiftBar/Plugins/` に置きます.
ファイル名を `llama-server.5s.sh` にしているので, SwiftBar は 5 秒ごとに実行します.
SwiftBar 自体は launchd のユーザーエージェントとして登録し, ログイン時に起動します.

状態は 3 つで, 判定とメニューの内容を対応させています.

| 状態 | 判定 | メニューバー | 項目 |
| --- | --- | --- | --- |
| 稼働 | `/health` が 200 を返す | 塗りつぶした脳のアイコン | メモリ, CPU, ポート, Web UI, モデルの切り替え, 停止 |
| 起動中 | `/health` が 200 でなく, `--port 18080` を持つ `llama-server` がいる | 砂時計 | Web UI, 停止 |
| 停止 | どちらでもない | 線画の脳のアイコン | 起動, Web UI (灰色) |

判定では `/health` を先に見て, プロセスの有無を後に見ます.
起動直後はプロセスが存在していても `/health` がまだ 200 にならないので, この順序にしています.
`/health` が 200 なら, PID の取得が遅れても稼働として扱えます.

起動中かどうかは `pgrep -f` で調べますが, プラグイン自身のファイル名にも `llama-server` が入っています.
そのため, コマンドラインに `--port 18080` まで含まれるものだけを対象にします.
同じバイナリを別のポートで動かしていても, このインスタンスの状態には影響しません.

手元の環境では, 起動直後の最初のリクエストは通常時の 2 から 4 倍の時間がかかります.
Metal の初期化と重みのページインが影響していると考えられます.
そこで, サーバが応答するようになったらウォームアップ用のリクエストを 1 回だけ投げます.
投げたかどうかは PID をキーにしたファイルで記録し, プラグインと起動スクリプトは同じファイルを共有します.
マーカーはリクエストの前に書くので, 失敗しても 5 秒ごとに再送しません.

メニューバーにはアイコンだけを出し, メモリと CPU とポートはドロップダウンに置きます.
稼働中のモデルは切り替えの項目で灰色にします.
起動中も, 待ち受けているプロセスがあれば停止を押せます.
`/health` が 200 にならないまま居座るサーバを, メニューから止められるようにするためです.
ポートを開く前に止まったプロセスは, この方法では止められません.

## 起動スクリプトを store に置く理由

メニューから呼ぶ `switch-to.sh` は, Nix の store に置いています.
SwiftBar は launchd から起動します.
この環境では, launchd 経由で起動した SwiftBar に書類フォルダへのアクセス権がなく, プラグインがリポジトリ内のスクリプトを実行しようとすると `Operation not permitted` で失敗しました.

そこで, 実行するスクリプトは store にコピーします.
store は TCC の保護範囲の外にあり, 誰でも読めるので, launchd から起動したプロセスでも実行できます.

```nix
switchTo = pkgs.runCommandLocal "switch-to.sh" { } ''
  cp ${pkgs.replaceVars ../../config/llama-server/switch-to.sh {
    llamaServer = "${llamaCpp}/bin/llama-server";
  }} "$out"
  chmod +x "$out"
'';

plugin = pkgs.replaceVars ../../config/swiftbar/llama-server.5s.sh {
  switchTo = "${switchTo}";
};
```

プラグインも同じように store に置き, home-manager で `Plugins` ディレクトリにリンクします.
llama-server のパスは起動スクリプトに, 起動スクリプトのパスはプラグインに, それぞれビルド時に埋め込みます.

代償として, プラグインやスクリプトの編集は, 構成を適用するまで反映されません.
動作の確認は適用のあとになります.

## クライアントから接続する

コーディングエージェントには, OpenAI 互換のプロバイダとして `http://127.0.0.1:18080/v1` を登録します.
モデル名は `--alias` に合わせ, コンテキスト長は 65536, 出力は 8192 トークンにします.
`/v1/models` が返す名前と揃えておくと, どのモデルが動いているかをクライアント側から確認できます.

OpenAI 互換のクライアントは API キーを要求することがあります.
この構成では API キー認証を設定していないので, キーを求められたら任意の値を入れます.
思考は起動時に無効にしているので, クライアント側でも reasoning を使わない設定にそろえます.

同じポートの Web UI も使えます.
`--webui-mcp-proxy` は Web UI から MCP サーバへの CORS プロキシ, `--tools read_file` はエージェントにファイルを読ませる組み込みツールです.
`read_file` はサーバを動かしているユーザがアクセスできるファイルを読みます.
この構成では待ち受け先を 127.0.0.1 に限っているので, 別のマシンからは届きません.
どちらも実験的な機能で, 信頼できない環境では有効にしないよう注意されています.

`--webui-config-file` で渡す設定ファイルは起動時に作り直し, システムメッセージにその日の日付と時刻を入れます.
モデルは学習時の日付を現在として扱わないよう, 起動のたびに現在時刻を渡しています.
リポジトリで管理している既定値と, Web UI から保存された設定をマージし, 既定値側を優先します.

別のモデルに切り替えるときも, ポートは変わりません.
モデルごとにコンテキスト長もサンプラも変えられるので, 起動スクリプトの分岐を足せば同じ手順で扱えます.

## References

- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [Qwen3.6-35B-A3B-MTP-GGUF](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF)
- [llama.cpp の MTP 対応](https://github.com/ggml-org/llama.cpp/pull/22673)
- [SwiftBar](https://github.com/swiftbar/SwiftBar)
- [home-manager](https://nix-community.github.io/home-manager/)
- [usabarashi/nix-config](https://github.com/usabarashi/nix-config)
