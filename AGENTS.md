# AGENTS

## Article prose

Japanese drafts in `posts/` and `pages/` follow the `japanese-tech-writing` skill.

- Avoid contrived, roundabout phrasing. Design decisions are fine when stated plainly; do not stage them with setup or narrate the effort behind them.
  - Bad: 「API の機能だけでは, タイムラインのフィルタは作れません. セッションをどこに置き, どの単位で作り, 複数の判定をどう順序づけるかを決める必要がありました.」
  - Good: 「セッションは offscreen document に置きます. service worker はアイドル状態になると停止するためです.」
