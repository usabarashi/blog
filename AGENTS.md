# AGENTS

## Build and preview

A `cabal run site -- watch` process (or `nix run . -- watch`) is kept running while the site is being edited.
It rebuilds `_site/` on save and serves it at http://localhost:8000/, so do not run `build` or `rebuild` by hand.
Both write `_cache/`, and running one while the watcher is up fails with a store decoding error such as `Data.Binary.Get.runGet at position 0: not enough bytes`.
Check the generated HTML under `_site/` when a change needs verifying.

## Personal information

`posts/` and `pages/` are published, so keep personal details out of the prose and code samples: email addresses, bank and service names, subscriptions, device inventory, and the author's own label names.
Illustrate with reserved names such as `you@example.com`, `@shop.example`, or `Assets/銀行`, and present examples as general practice rather than as a description of the author's own configuration.

## Article prose

Japanese drafts in `posts/` and `pages/` follow the `japanese-tech-writing` skill.

- Avoid contrived, roundabout phrasing. Design decisions are fine when stated plainly; do not stage them with setup or narrate the effort behind them.
  - Bad: 「API の機能だけでは, タイムラインのフィルタは作れません. セッションをどこに置き, どの単位で作り, 複数の判定をどう順序づけるかを決める必要がありました.」
  - Good: 「セッションは offscreen document に置きます. service worker はアイドル状態になると停止するためです.」
