# Diagrams

Figures used in posts. Every rendered SVG is committed under `assets/images/`, so that building the site never needs a browser.
File names carry the post date as a prefix, the same way posts do, so an asset can be traced back to the article that uses it.

| Source | Output | Used by |
|---|---|---|
| `2026-01-01-homelab-before.mmd` (Mermaid) | `assets/images/2026-01-01-homelab-before.svg` | `posts/2026-01-01-migrate-homelab.md` |
| `2026-01-01-homelab-after.mmd` (Mermaid) | `assets/images/2026-01-01-homelab-after.svg` | `posts/2026-01-01-migrate-homelab.md` |
| `2026-01-01-homelab-secrets.mmd` (Mermaid) | `assets/images/2026-01-01-homelab-secrets.svg` | `posts/2026-01-01-migrate-homelab.md` |
| `2026-01-01-homelab-logs.mmd` (Mermaid) | `assets/images/2026-01-01-homelab-logs.svg` | `posts/2026-01-01-migrate-homelab.md` |
| `2026-02-22-terraform-provider-apc-agents.mmd` (Mermaid) | `assets/images/2026-02-22-terraform-provider-apc-agents.svg` | `posts/2026-02-22-terraform-provider-apc.md` |
| `2026-02-22-terraform-provider-apc-mail-relay.mmd` (Mermaid) | `assets/images/2026-02-22-terraform-provider-apc-mail-relay.svg` | `posts/2026-02-22-terraform-provider-apc.md` |
| `2026-02-22-terraform-provider-apc-credentials.mmd` (Mermaid) | `assets/images/2026-02-22-terraform-provider-apc-credentials.svg` | `posts/2026-02-22-terraform-provider-apc.md` |
| `2026-02-22-terraform-provider-apc-session.mmd` (Mermaid) | `assets/images/2026-02-22-terraform-provider-apc-session.svg` | `posts/2026-02-22-terraform-provider-apc.md` |
| `2026-01-01-homelab-monitoring.mmd` (Mermaid) | `assets/images/2026-01-01-homelab-monitoring.svg` | `posts/2026-01-01-migrate-homelab.md` |
| none (hand-written SVG) | `assets/images/2026-01-01-homelab-size.svg` | `posts/2026-01-01-migrate-homelab.md` |
| none (hand-written SVG) | `assets/images/2025-09-30-voicevox-mcp-architecture.svg` | `posts/2025-09-30-voicevox-mcp-server.md` |

## Shared style

All figures use the same look, so the post does not switch styles between sections.

- background: white, so the figure reads the same in the light and dark color schemes
- fill `#e6e6e6`, border `#333333`, text `#222222`
- font: `system-ui` with a Japanese fallback, 14px for labels
- label text stays in English so a figure can be reused outside the Japanese posts

The Mermaid sources carry this palette in a `%%{init: …}%%` directive (`theme: base` plus `themeVariables`).
Kroki honours those variables, but it pins its own font stack and draws no background.
So SVGs rendered from Mermaid get a white `<rect>` injected as the first child of `<svg>`, and the `--mermaid-font-family` variable is rewritten to the shared stack.

## Mermaid figures

Regenerate on Linux, where nixpkgs has Chromium:

```console
$ nix shell nixpkgs#mermaid-cli nixpkgs#chromium -c \
    mmdc -i diagrams/2026-01-01-homelab-before.mmd -o assets/images/2026-01-01-homelab-before.svg -b white
```

Mermaid measures label text with the renderer's fonts, so a missing Japanese font makes the boxes too narrow.
The sources set `wrappingWidth: 400` so that each label stays on one line; with the default width the labels wrap and the boxes grow taller.
`mmdc` draws the white background itself (`-b white`); add the background `rect` by hand only when rendering through a service that does not.

The committed SVGs were rendered once by kroki.io and use `foreignObject` labels, which browsers render but some non-browser viewers ignore.
Re-render when the layout needs to change, and check the result by eye: nothing compares an SVG with its source.

## Width

Every SVG is written with `width="672"` (the width of the text column) and a height derived from its `viewBox`, so the figures in a post share one display width.
After re-rendering a diagram, run `node scripts/normalize-svg-width.mjs` to restore it.

## Size comparison

`2026-01-01-homelab-size.svg` is written by hand, because the figure has to be drawn to scale and Mermaid cannot express physical size.
It is a front elevation (width x height) at 1 px = 1 mm, with the same palette and font as the Mermaid figures.

| Host | W x D x H (mm) |
|---|---|
| HP ProLiant MicroServer N54L | 210 x 260 x 267 |
| Beelink ME mini | 99 x 99 x 99 |

The dimensions come from the HP QuickSpecs and the Beelink product page.
Change the rectangles, the labels and the numbers together if a measurement turns out to be wrong.
