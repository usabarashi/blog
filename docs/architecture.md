# Layout and technical choices

This file records decisions and their reasons. Tool and library versions are pinned in `flake.lock` and `blog.cabal`; `nix flake metadata` and `nix develop -c ghc-pkg list` show what the build actually uses.

## Toolchain

The flake builds the generator from the pinned nixpkgs with `callCabal2nix`, and creates the dev shell with `shellFor`.
The dev shell therefore exposes the same packages that the Nix build compiles against, through GHC's package database.

`cabal.project` sets `active-repositories: :none`, so cabal never fetches sources from Hackage.
Dependencies resolve to the versions in the dev shell, which keeps `cabal build` aligned with the Nix build instead of drifting towards newer Hackage releases.

The same check runs on `ubuntu-latest` in CI, so the Linux build is exercised on every pull request.

Two choices are worth recording because the files do not explain them.

- nixpkgs ships a Hakyll release that Hackage has marked deprecated.
  The next release is described in its changelog as nearly identical, adding only QuickCheck support.
  This site uses stable entry points (`pandocCompilerWith`, templates, `buildTags`), so it follows nixpkgs and moves on with the next `flake.lock` update.
- The Pandoc range that Hakyll accepts includes the pinned Pandoc.
  Pandoc 3.8 replaced the syntax highlighting writer option (`writerHighlightStyle` became `writerHighlightMethod`), and Hakyll handles both behind CPP.
  The site only sets `writerHTMLMathMethod = MathML`, which is unaffected.

## Output shape

| Input | Output |
|---|---|
| `posts/YYYY-MM-DD-slug.md` | `/posts/slug.html` |
| `pages/about.md` | `/about.html` |
| tag `haskell` | `/tags/haskell.html` |
| `posts/drafts/**` | nothing |

`postRoute` drops the date from the article URL with `gsubRoute`.
Ordering and display use the `date` front matter field, which Hakyll's `recentFirst` parses as `%Y-%m-%d`.

## Serving from /blog/

Templates use site-root absolute paths (`/css/style.css`, `/archive.html`).
`relativizeUrls` rewrites them to paths relative to each page's depth on output.

- The same HTML works in local preview (`http://localhost:8000/`) and on the GitHub Pages project page (`https://usabarashi.github.io/blog/`).
- Nothing has to be configured for the `/blog/` prefix, so renaming the repository or moving the site does not require touching the templates.

RSS and the sitemap need absolute URLs, so they prefix every URL with `siteRoot` in `src/Main.hs`.
That constant is the single place to edit when the site moves.

## Math

`$...$` and `$$...$$` become Pandoc's MathML output.
MathJax and KaTeX are not loaded, so viewing a page needs no external request and no JavaScript.
Depending on the browser's MathML support is an accepted trade-off.

## Syntax highlighting

The style is Pandoc's default (`pygments`).
The CSS is generated at build time by `create ["css/syntax.css"]` in `src/Main.hs` from Pandoc's `styleToCss`.
A committed stylesheet would drift from the Pandoc version, so the generator owns it.

## Drafts

`posts/drafts/` matches no rule, and Hakyll does not render files without rules, so drafts never appear in `_site`.
The build check in `flake.nix` asserts that, and also asserts that generated HTML contains no site-root absolute URL.
That second assertion is the invariant behind serving the same output from both `/` and `/blog/`; the feed and sitemap are excluded because they need absolute URLs.

The protection applies to files under `posts/drafts/` only; a draft placed directly in `posts/` would be published.

## Diagrams

A diagram is authored in Mermaid and committed twice: the source under `diagrams/*.mmd`, and a rendered SVG under `assets/images/`.
A figure that Mermaid cannot express, such as the to-scale chassis comparison, is written directly as an SVG; `diagrams/README.md` records which outputs come from which source.
Pre-rendering keeps the site free of JavaScript and keeps the Nix build independent of a browser.
Chromium is Linux-only in nixpkgs, so `checks.<system>.site` must never render diagrams; it only copies the committed SVG.

To regenerate on a Linux machine with the pinned nixpkgs:

```sh
nix shell nixpkgs#mermaid-cli nixpkgs#chromium -c \
  mmdc -i diagrams/2026-01-01-homelab-before.mmd -o assets/images/2026-01-01-homelab-before.svg -b white
```

`-b white` gives the same background as the hand-written figures; `diagrams/README.md` holds the same command.
After rendering, run `node scripts/normalize-svg-width.mjs` so the new SVG matches the display width of the others.

Mermaid measures text while rendering, so the labels are only laid out correctly when the renderer can find a Japanese font.
Install a CJK font in that shell if the boxes come out too narrow, and check the result before committing.
The committed `2026-01-01-homelab-before.svg` was rendered once by kroki.io; its labels are `foreignObject` HTML rather than SVG text, which browsers render but some non-browser viewers ignore.

Nothing verifies that an SVG matches its `.mmd` yet. Re-render after editing the source and inspect the result; a drift check belongs in CI once rendering is reproducible.

The feed carries the post body before `relativizeUrls` runs, so root-absolute image paths reach aggregators unchanged and would resolve from the site root instead of `/blog/`.
The feed therefore rewrites `src="/` to an absolute URL under `siteRoot` (`absoluteBodyField` in `src/Main.hs`); ordinary pages keep the relativized paths.

## Not verified

- `site watch`, the Warp preview server. The agent sandbox rejects Warp's sendfile call, so the server could not be exercised here.
  The output of `site build` was served by a static server under a `/blog/` prefix instead, and the HTML, CSS and RSS were fetched successfully.
