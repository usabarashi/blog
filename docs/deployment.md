# Publishing (undecided)

## Current state

Checked through the GitHub API on 2026-10-31. None of it was changed.

- `usabarashi/blog` is public (its initial state).
- GitHub Pages is not configured for `usabarashi/blog` (`GET /repos/usabarashi/blog/pages` returns 404).
- `usabarashi/usabarashi.github.io` does not exist, which contradicts the repository layout in the handover notes.

Repository visibility, Pages settings and deployment stay untouched until the GitHub Pro question is settled.
`main` has no publishing workflow, so a merge cannot publish anything.

## Option A: private repository plus GitHub Pages

Keep the writing repository private and let Actions build on merge to `main` and publish to Pages.

- Publishing Pages from a private repository requires GitHub Pro or higher. On Free, Pages is only available for public repositories.
- Drafts, draft pull requests and the Haskell sources stay private.
- Only the HTML that Pages serves becomes public.
- Builds consume Actions minutes of the private repository (the Free plan includes 2,000 minutes per month).

## Option B: private writing repository plus public output repository

Keep the writing repository private, make a separate output repository public, and let Actions copy only the generated site into it.

- Using `usabarashi.github.io` as the output makes the site `https://usabarashi.github.io/`, not `/blog/`. `siteRoot` in `src/Main.hs` would have to become `https://usabarashi.github.io`.
- Using a public repository named `blog` keeps `https://usabarashi.github.io/blog/` and needs no change.
- `GITHUB_TOKEN` cannot write to another repository, so the transfer needs a deploy key or a fine-grained PAT with write access to the output repository, stored as a secret.
- Actions minutes are consumed like in option A.

## What deployment adds

How the site is built is defined once, by `checks.<system>.site` in `flake.nix`.
The deploy workflow must call that check rather than repeat its build steps, so there is only one place to keep the build working.

Option A additionally needs:

1. `usabarashi/blog` made private (owner action).
2. The Pages source set to "GitHub Actions".
3. A deploy workflow with `pages: write` and `id-token: write` permissions, a job in the `github-pages` environment, and only the Pages-specific steps: `actions/configure-pages`, `actions/upload-pages-artifact` (with the check's `result` directory as `path`) and `actions/deploy-pages`.

Pin those actions to commit SHAs with the release in a trailing comment, the way `build.yml` does; otherwise a moved tag changes what the workflow runs.

If that workflow would end up repeating the checkout and Nix setup from `build.yml`, turn `build.yml` into a reusable workflow (`on: workflow_call`) and upload the rendered site as a job artifact for the deploy job to consume.
Either way the build itself stays in one place.

Option B needs no Pages settings; its workflow pushes the same `result` directory to the output repository instead.

## PR previews

There is no PR preview.
A preview is only useful if it opens from a link, and publishing a PR branch would expose drafts and overwrite the `main` site, because one repository maps to one GitHub Pages site.

If link-based previews become a requirement, they need a separate hosting target or an access-controlled external service.
Decide that together with repository visibility and the deployment method.

## Open questions

- Option A or option B (waiting on GitHub Pro availability).
- Whether the public repository is `blog` or `usabarashi.github.io`. The former keeps `/blog/`; the latter requires changing `siteRoot`.
- Whether to add a 404 page.
- Whether PR previews must be reachable by link, and if so, where they are hosted.
