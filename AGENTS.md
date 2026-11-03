# AGENTS

## Build and preview

A `cabal run site -- watch` process (or `nix run . -- watch`) is kept running while the site is being edited.
It rebuilds `_site/` on save and serves it at http://localhost:8000/, so no manual build is needed while it runs.
Stop the watcher before running `build` or `rebuild`: both write `_cache/`, and running one alongside the watcher fails with a store decoding error such as `Data.Binary.Get.runGet at position 0: not enough bytes`.
With no watcher running, `build` and `rebuild` work as usual.
Check the generated HTML under `_site/` when a change needs verifying.

## Personal information

`posts/` and `pages/` are published, so do not copy the author's private configuration details into the prose or code samples: email addresses, the banks and paid services the author uses, devices, or their own label names.
Illustrate with reserved names such as `you@example.com`, `@shop.example`, or `Assets/銀行`, and present examples as general practice rather than as a description of the author's own setup.
Naming a product the article is about (Gmail, Terraform) is not a personal detail.

## Article prose

Japanese drafts in `posts/` and `pages/` follow the `japanese-tech-writing` skill.

- Write the prose in ですます調 (「〜します」「〜です」), matching the published articles. Do not use the だ/である style.
- Avoid contrived, roundabout phrasing. Design decisions are fine when stated plainly; do not stage them with setup or narrate the effort behind them.
  - Bad: 「API の機能だけでは, タイムラインのフィルタは作れません. セッションをどこに置き, どの単位で作り, 複数の判定をどう順序づけるかを決める必要がありました.」
  - Good: 「セッションは offscreen document に置きます. service worker はアイドル状態になると停止するためです.」

## Figures and tables

Use a figure or a table where it carries the structure better than prose: comparing configurations, listing options and their roles, or showing how traffic moves between components. The prose explains why the structure is that way and does not restate the table.

Figures follow `diagrams/README.md`; tables use Pandoc pipe tables.
