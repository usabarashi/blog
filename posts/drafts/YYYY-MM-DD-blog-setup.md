---
title: "Setting up this blog with Hakyll and Nix"
date: "2026-10-31"
tags:
  - haskell
  - nix
---

Posts are written in Markdown and Hakyll turns them into static HTML.
The build environment is pinned with Nix flakes.

## Writing a post

Front matter holds the title, date and tags; the body follows in Markdown.
Files are named `posts/YYYY-MM-DD-slug.md`, and the slug becomes the URL.

```haskell
main :: IO ()
main = hakyll $ do
    match "posts/*.md" $ do
        route postRoute
        compile $ pandocCompilerWith defaultHakyllReaderOptions pandocOptions
            >>= loadAndApplyTemplate "templates/post.html" postCtx
            >>= relativizeUrls
```

## Math

Pandoc renders math as MathML, so no JavaScript or external CDN is involved.

Inline math looks like $a^2 + b^2 = c^2$. Display math is written as a block.

$$
\int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi}
$$

## Drafts

Files under `posts/drafts/` match no rule, so they are never written to `_site`.
Keep a post there until it is ready to publish.
