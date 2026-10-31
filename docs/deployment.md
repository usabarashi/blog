# Publishing

## Current setup

The blog is published from this repository, `usabarashi/blog`, by GitHub Pages at `https://usabarashi.github.io/blog/`.

- The repository is public, so the Markdown sources and the drafts under `posts/drafts/` are public as well. Publishing does not hide anything that is already in the repository.
- Pages uses the "GitHub Actions" source, not a branch. Generated HTML is never committed.
- `.github/workflows/build.yml` is the only workflow. It verifies every pull request, and it publishes on a push to `main` or a manual run on `main`.

## What the workflow does

The `site` job renders the site with `checks.x86_64-linux.site` and asserts the output is publishable.
Publishing steps and a second job follow, guarded so that a pull request run uploads no artifact and deploys nothing.

The two publishing runs share one concurrency group, so an older run cannot publish over a newer one.
Manual runs are useful for redeploying without a new commit.

## First-time setup

Done once by the repository owner.

1. Settings → Pages → Build and deployment → Source: **GitHub Actions**.

   ```console
   $ gh api -X POST repos/usabarashi/blog/pages -f build_type=workflow
   ```

2. Settings → Environments → `github-pages` → Deployment branches and tags: limit to `main`.
   The environment is created by the first deploy, so set this right after it appears.

3. Merge the workflow to `main` and let the run finish. The first deploy creates the environment and publishes the site.

## Verifying a deployment

```console
$ gh run list --workflow build.yml --limit 3
$ gh api repos/usabarashi/blog/pages --jq '{html_url, status, build_type}'

$ curl -sI https://usabarashi.github.io/blog/ | head -1
$ curl -sI https://usabarashi.github.io/blog/css/style.css | head -1
$ curl -sI https://usabarashi.github.io/blog/rss.xml | head -1
$ curl -sI https://usabarashi.github.io/blog/sitemap.xml | head -1
$ curl -s -o /dev/null -w "%{http_code}\n" https://usabarashi.github.io/blog/drafts
404
```

The Pages CDN can serve the previous version for a few minutes after a deploy.
`*.github.io` uses HTTPS automatically; check "Enforce HTTPS" in Settings → Pages after the first deploy.

`sitemap.xml` lists the pages that exist, and `rss.xml` carries absolute URLs, so both follow `siteRoot` in `src/Main.hs`.
That constant must match the published URL.

## If the repository has to become private

Pages from a private repository requires GitHub Pro or higher.
Without it, publishing needs a second, public repository that receives only the generated site, while this repository stays private.
In that case the published URL depends on the output repository name, and `siteRoot` has to change unless the output repository is named `blog`.

## Open questions

- Whether to add a 404 page.
- Whether the site needs a custom domain.
- Whether pull requests should get a preview that opens from a link. That needs a hosting target of its own, because one repository maps to one Pages site and publishing a PR branch would replace the live site.
