# zitadel-login

A **thin fork** of the upstream [Zitadel Login V2][upstream] Next.js app, built
so that login-UI changes the Zitadel branding/label-policy API cannot express
(logo click-through, back-button behavior, page chrome) become ordinary code
edits. We self-host the upstream app — we do **not** reimplement it.

- License: **MIT** (inherited from upstream `apps/login/LICENSE`; see `LICENSE`)
- Image: `ghcr.io/zeroroot-ai/zitadel-login:<upstream-tag>`, published by every push to `main` from the tag in `UPSTREAM_REF`

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
| `UPSTREAM_REF` | Pinned upstream `REPO` / `TAG` / `COMMIT`. The only copy of the version in this repo. |
| `scripts/upstream-ref.sh` | The one reader of `UPSTREAM_REF`. The workflow, the Makefile and the patch check go through it. |
| `scripts/patch-check.sh` | Sparse-clones upstream at the pinned tag and apply-checks the patch set. PR job and `make test`. |
| `patches/*.patch` | The customization, as `git apply -p1` diffs rooted at `apps/login/...`. |
| `Dockerfile` | Multi-stage: clone upstream @ tag → verify SHA → apply patches → upstream build → upstream runtime. Carries no version; the tag, commit and landing URL are required build args. |
| `.github/workflows/image.yml` | Reads `UPSTREAM_REF`, runs the patch check on PRs, builds + publishes the image tagged `<upstream-tag>` via the org `reusable-image-build.yml`. |

The runtime stage of the `Dockerfile` follows upstream
`apps/login/Dockerfile`, so the image is a **drop-in replacement**: same env
contract, same port (`3000`), same entrypoint and healthcheck. It departs from
upstream in exactly two places, both marked in the file: the hardening `RUN`
after `FROM`, and the `COPY` of `LICENSE` and `NOTICE` into `/licenses` at the
end. MIT requires that notice to travel with every copy, so neither is
optional. The deploy chart
swaps only `login.image.repository`; core Zitadel is untouched, and the existing
Stakater Reloader branding cache-bust keeps working unchanged.

## Transport to the Zitadel API

The runtime stage ships `ZITADEL_TLS_ENABLED="false"`, the same default as
upstream `apps/login/Dockerfile`. That flag governs the login app's own
connection to the Zitadel core API, not the browser's connection to the login
page. The image does not choose the API endpoint; the deployment does, and the
two settings have to agree:

| Setting | Where the chart sets it | Value in the umbrella |
|---|---|---|
| `ZITADEL_API_URL` | `zitadel.login.env` (charts, `helm/gibson/values.yaml`) | `http://gibson-zitadel:8080`, the core Service on the pod network |
| `ZITADEL_TLS_ENABLED` | `zitadel.login.env`, or unset to take the image default | unset, so `false`, matching the `http://` URL |

In the umbrella the login pod and the core pod run in one namespace behind
the namespace default-deny NetworkPolicy, and the hop between them never
leaves the cluster network. A deployment that fronts the core API with TLS
sets both keys in `zitadel.login.env`: an `https://` `ZITADEL_API_URL` and
`ZITADEL_TLS_ENABLED=true`. Setting only the flag makes the app dial TLS to a
plaintext port and every login fails on the handshake. The image default is
not a statement that plaintext is acceptable on the open network.

## The patches

Two, applied in order by `git apply -p1`:

### `0002-disable-image-optimization.patch`

One key in `next.config.mjs`: `images.unoptimized = true`, which removes the
`/_next/image` route.

GHSA-2xp9-vwfh-vxw4 / CVE-2026-75604 is an **unauthenticated** remote code
execution in that API when an AVIF file is processed, fixed in next `16.3.3`.
This app takes whatever next version upstream Zitadel's lockfile carries
(`16.2.11` at `v4.17.3`, built `--frozen-lockfile`), and it is the login page:
reachable before any authentication, from the internet.

Nothing here uses the optimizer. `next/image` appears in exactly one file in
the app and that file is a test mock; the branding logo renders through a
plain `<img>` in `src/components/logo.tsx`. So the route is dead weight that
happens to be the vulnerable surface, and this removes it rather than
narrowing its input.

It does **not** close the alert. Trivy reads the package version, not the
config, so `next 16.2.11` stays flagged until upstream ships a lockfile with a
fixed version. Re-check on every `UPSTREAM_REF` bump and drop this patch when
the pinned lockfile is at `16.3.3` or later.

### `0001-zeroroot-login-customizations.patch`

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

The landing origin is **never** hardcoded (respects the
no-hardcoded-hostname guard). It is injected at image-build time via the
`NEXT_PUBLIC_LANDING_URL` build arg, sourced from the `NEXT_PUBLIC_LANDING_URL`
Actions variable in `image.yml`. `NEXT_PUBLIC_*` is inlined into the client
bundle at **build** time (Next.js semantics), so the value is baked per image;
the marketing landing origin is stable and shared across envs, so this is the
right tradeoff. To change it, update the Actions variable and rebuild.

## Maintenance contract: rebase on every Zitadel bump

> **Core Zitadel and the login UI ship from the same tag and MUST move
> together.** The chart pins `zitadel.image.tag` and the login image at the
> same upstream tag, and a chart guard rejects a move of one without the other
> (zeroroot-ai/charts#13). This repo leads: bump here first, the image
> publishes itself, the chart follows through the version fan-out
> (zeroroot-ai/.github#24). Tracking epic: zeroroot-ai/.github#20.

Per-bump checklist:

1. Edit `UPSTREAM_REF`: set `TAG` to the new upstream tag and `COMMIT` to
   `git rev-parse <tag>` in `zitadel/zitadel`. Nothing else carries the version.
2. Re-resolve the patch set: `make test` sparse-clones upstream at the new tag
   and apply-checks `patches/*.patch`. If it fails, hand-merge the three files
   (`logo.tsx`, `back-button.tsx`, `username-form.tsx`) and regenerate the
   patch. The same check runs as the `patch-check` job on the PR.
3. Merge. The push to `main` publishes `ghcr.io/zeroroot-ai/zitadel-login:<tag>`
   next to `sha-<short>`; no git tag is involved.

What the workflow enforces, so the checklist stays three steps:

- The `NEXT_PUBLIC_LANDING_URL` Actions variable must be set on this repo. The
  `resolve` job fails with a message that names it, and the Dockerfile fails
  again if the build arg is empty. An empty value once shipped an unbranded
  image (the first build on 2026-07-02), so the build no longer tolerates it.
- The Dockerfile declares `UPSTREAM_REPO`, `UPSTREAM_TAG`, `UPSTREAM_COMMIT`
  and `NEXT_PUBLIC_LANDING_URL` as build args with no defaults. `make check`
  fails if a default appears.

To check the branding is baked into a published image:

```bash
docker run --rm --entrypoint sh ghcr.io/zeroroot-ai/zitadel-login:<tag> \
  -c 'grep -rl "<landing-host>" /app >/dev/null && echo BRANDED || echo UNBRANDED'
```

## Building locally

```bash
make build NEXT_PUBLIC_LANDING_URL=https://<your-landing-origin>
```

`make build` reads the tag and commit from `UPSTREAM_REF` and refuses an empty
landing URL.

The build clones the upstream monorepo and runs the full pnpm + nx build, so it
needs network access and is resource-heavy (a Next.js 16 / React 19 monorepo
build). CI runs it on GitHub-hosted runners via `image.yml`.

## License and history

MIT, inherited from the upstream `apps/login/LICENSE`. See [LICENSE](LICENSE).

The published image is a modified work. [NOTICE](NOTICE) names the upstream project, the pinned version and the two patches.

Issue and pull request numbers cited in comments and documents dated before 2026-09-05 refer to the tracker before the history reset, archived offline. They do not resolve on GitHub.

[upstream]: https://github.com/zitadel/zitadel/tree/main/apps/login
