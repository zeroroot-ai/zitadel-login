# zitadel-login

A **thin fork** of the upstream [Zitadel Login V2][upstream] Next.js app, built
so that login-UI changes the Zitadel branding/label-policy API cannot express
(logo click-through, back-button behavior, page chrome) become ordinary code
edits. We self-host the upstream app — we do **not** reimplement it.

- Tracker: [deploy#888](https://github.com/zeroroot-ai/deploy/issues/888)
- License: **MIT** (inherited from upstream `apps/login/LICENSE`; see `LICENSE`)
- Image: `ghcr.io/zeroroot-ai/zitadel-login:<zitadel-version>` (e.g. `:v4.17.3`)

## Explicit non-goal

This is **not** a custom login UI on Zitadel's Session API. Every interactive
flow (password, MFA/TOTP, passkey/WebAuthn, password reset, external IdP,
account selection) stays in Zitadel's own app and keeps working unchanged. We
fork only to gain editability of the chrome.

## How the fork is structured (no vendored source)

The upstream login app lives in the `zitadel/zitadel` monorepo under
`apps/login` and depends on the monorepo workspace (`@zitadel/proto`,
`@zitadel/client`). Rather than vendoring tens of thousands of files, this repo
is a small, isolated patch set on top of a pinned upstream tag:

| File | Role |
|------|------|
| `UPSTREAM_REF` | Pinned upstream `REPO` / `TAG` / `COMMIT` (single source of truth). |
| `patches/*.patch` | The customization, as `git apply -p1` diffs rooted at `apps/login/...`. |
| `Dockerfile` | Multi-stage: clone upstream @ tag → verify SHA → apply patches → upstream build → upstream runtime. |
| `.github/workflows/image.yml` | Builds + publishes the image via the org `reusable-image-build.yml`. |

The runtime stage of the `Dockerfile` is a verbatim copy of upstream
`apps/login/Dockerfile`, so the image is a **drop-in replacement**: same env
contract, same port (`3000`), same entrypoint and healthcheck. The deploy chart
swaps only `login.image.repository`; core Zitadel is untouched, and the existing
Stakater Reloader branding cache-bust (deploy#943) keeps working unchanged.

## The customization patch (`patches/0001-zeroroot-login-customizations.patch`)

Three files, ~44 lines, all guarded by config so the diff is **inert by
default** (renders exactly as upstream when unconfigured):

1. **`logo.tsx`** — wraps the brand logo in a link to `NEXT_PUBLIC_LANDING_URL`
   when set.
2. **`back-button.tsx`** — adds an optional `href` prop; when present the button
   navigates to that external origin instead of `router.back()`. Backward
   compatible — every other call site is unchanged.
3. **`username-form.tsx`** — the loginname entry page passes
   `NEXT_PUBLIC_LANDING_URL` as the back-button `href` (browser-history "back" on
   the entry page lands on a meaningless OIDC redirect, so it is repointed to the
   marketing landing origin).

### No hardcoded hostnames

The landing origin is **never** hardcoded (respects the deploy#630
no-hardcoded-hostname guard). It is injected at image-build time via the
`NEXT_PUBLIC_LANDING_URL` build arg, sourced from the `NEXT_PUBLIC_LANDING_URL`
Actions variable in `image.yml`. `NEXT_PUBLIC_*` is inlined into the client
bundle at **build** time (Next.js semantics), so the value is baked per image;
the marketing landing origin is stable and shared across envs, so this is the
right tradeoff. To change it, update the Actions variable and rebuild.

## Maintenance contract: rebase on every Zitadel bump

> **Core Zitadel and the login UI ship from the same tag and MUST move
> together.** On every Zitadel version bump, rebase this fork onto the new
> upstream login tag and rebuild the image at the matching tag **before** the
> core bump merges in `deploy`, or the login UI and core drift.

Per-bump checklist:

1. Find the new upstream commit: the tag is `vX.Y.Z` in `zitadel/zitadel`;
   record `git rev-parse vX.Y.Z`.
2. Update `UPSTREAM_REF` (`TAG`, `COMMIT`) and the matching `ARG`s in
   `Dockerfile`.
3. Re-resolve the patch set against the new tag (the diffs are tiny and target
   `logo.tsx`, `back-button.tsx`, `username-form.tsx`):
   ```bash
   git clone --depth 1 --branch vX.Y.Z https://github.com/zitadel/zitadel.git up
   cd up && git apply -p1 --check ../patches/*.patch   # if it fails, hand-merge + regenerate
   ```
4. **Before tagging, confirm the `NEXT_PUBLIC_LANDING_URL` Actions variable is
   set on this repo** (`gh variable list -R zeroroot-ai/zitadel-login`). The
   build does NOT fail when it is unset — it silently produces an **unbranded**
   image (the patch renders inert, exactly upstream). This shipped once:
   the first `v4.14.0` build (2026-07-02) was published unbranded because the
   repo had zero Actions variables.
5. Tag this repo `vX.Y.Z`; CI publishes `ghcr.io/zeroroot-ai/zitadel-login:vX.Y.Z`.
   Sanity-check the branding is baked in before consuming the image:
   ```bash
   docker run --rm --entrypoint sh ghcr.io/zeroroot-ai/zitadel-login:vX.Y.Z \
     -c 'grep -rl "<landing-host>" /app >/dev/null && echo BRANDED || echo UNBRANDED'
   ```
6. **Only then** bump the deploy chart: `zitadel.image` (core) **and**
   `zitadel.login.image.tag` in the same PR. The deploy chart requires an
   immutable digest pin (`tag: "vX.Y.Z@sha256:<digest>"`, deploy#789); resolve
   the fresh digest with
   `gh api /orgs/zeroroot-ai/packages/container/zitadel-login/versions`.

## Building locally

```bash
docker build \
  --build-arg NEXT_PUBLIC_LANDING_URL=https://<your-landing-origin> \
  -t ghcr.io/zeroroot-ai/zitadel-login:v4.17.3 .
```

The build clones the upstream monorepo and runs the full pnpm + nx build, so it
needs network access and is resource-heavy (a Next.js 16 / React 19 monorepo
build). CI runs it on GitHub-hosted runners via `image.yml`.

[upstream]: https://github.com/zitadel/zitadel/tree/main/apps/login
