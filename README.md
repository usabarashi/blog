# blog

A static blog generated from Markdown by Hakyll and Pandoc.
The intended URL is `https://usabarashi.github.io/blog/`.
GitHub Pages is not configured and no deployment workflow exists yet; see [docs/deployment.md](docs/deployment.md).

## Requirements

- Nix with flakes enabled
- direnv (optional; `.envrc` contains `use flake`)

## Setup

```console
$ echo 'use flake' > .envrc   # if the file does not exist yet
$ direnv allow                # or: nix develop
```

The dev shell provides GHC, cabal-install, Hakyll and Pandoc.
Dependencies come from GHC's package database, and `cabal.project` sets `active-repositories: :none`.
`cabal build` therefore never downloads from Hackage and uses exactly the versions Nix pins.

## Build and preview

```console
$ nix develop
$ cabal build
$ cabal run site -- build    # writes _site/
$ cabal run site -- watch    # preview at http://localhost:8000/
```

You can skip cabal entirely if you do not want a package index:

```console
$ nix run . -- build
$ nix run . -- watch
```

Adding a dependency only needs a line in `blog.cabal`; the dev shell and the Nix build take it from nixpkgs.

`_cache/` holds Hakyll's incremental state.
When you change contexts or rules in `src/Main.hs` and the output does not change, rebuild from scratch:

```console
$ cabal run site -- rebuild
```

Stop `site watch` before running `build` or `rebuild` in the same directory.
Both processes write `_cache/`, and running them at once can fail with a store decoding error such as `Data.Binary.Get.runGet at position 0: not enough bytes`.

`cabal run` and `nix run .` read the working tree, so they pick up files that git does not track yet.
Nix builds do not: `nix build .#checks.<system>.site` renders a copy of the repository, so run `git add` on new posts and pages first.
That check writes its output to `result/`; `site build` writes to `_site/`.

Full verification, which also checks that drafts never reach the output:

```console
$ nix build .#checks.aarch64-darwin.site    # x86_64-linux on Linux
```

## Writing a post

Posts live in `posts/`. The `slug` in the file name becomes the URL.

```text
posts/YYYY-MM-DD-slug.md  ->  /posts/slug.html
```

Start the file with YAML front matter.

```yaml
---
title: "Post title"
date: "2026-10-31"
tags:
  - haskell
  - nix
---
```

`tags` accepts a YAML list or a comma-separated string.
Each tag name becomes a file name under `/tags/`. Non-ASCII names work, and links are percent-encoded.
Avoid `/`, `..`, trailing dots or spaces, and names that differ only in case.

Drafts go in `posts/drafts/`.
No rule matches that directory, so drafts never reach `_site`; move a file to `posts/` to publish it.

Standalone pages live in `pages/` and become `/<name>.html`.
They appear in the sitemap, but not in the index, archive or tag pages, which list posts only.
The file name is used as is, so a date prefix stays in the URL; dated content belongs in `posts/`.

### Math

`$...$` and `$$...$$` are rendered as MathML by Pandoc.
No JavaScript or external CDN is loaded.

### Syntax highlighting

Code blocks are highlighted by Pandoc's skylighting.
The CSS is generated at build time from the Pandoc style (`pygments`) into `/css/syntax.css`; to change the theme, change `pygments` in `src/Main.hs`.

## Layout

```text
blog/
├── flake.nix           Nix build environment and checks
├── flake.lock
├── cabal.project
├── blog.cabal
├── src/Main.hs         Hakyll site definition
├── posts/              posts (posts/drafts/ is never published)
├── pages/              standalone pages
├── templates/          HTML templates
├── assets/             CSS and images (served without the assets/ prefix)
├── .github/workflows/  build verification
├── docs/               design notes and deployment plan
└── README.md
```

## Publishing

Publishing is on hold; see [docs/deployment.md](docs/deployment.md).
CI only verifies the build.

## License

The repository has no license yet (No license).
Articles (`posts/`, `pages/`) are All rights reserved; the Haskell code is a candidate for MIT.
