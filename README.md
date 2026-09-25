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

Four, applied in order by `git apply -p1`:

### `0004-security-settings-single-public-host-header.patch`

Fixes a stock Zitadel defect: `fetchIframeOrigins()` in
`security-settings.ts` sends a duplicated `x-zitadel-public-host` header
whenever `CUSTOM_REQUEST_HEADERS` names that header (or
`x-zitadel-instance-host`) in a different case than the hardcoded lowercase
literal.

`fetchIframeOrigins()` calls Zitadel's `GetSecuritySettings` with a raw
`fetch()` (it runs from Next.js Edge middleware, where the Node-only Connect
transport used everywhere else in the app is unavailable). It built its
outgoing headers on a plain `Record<string, string>`, and HTTP header names
are case-insensitive: `"x-zitadel-public-host"` and `"X-Zitadel-Public-Host"`
are two different object keys but the same header on the wire. Per the
WHATWG Fetch spec, when a `Headers` object is constructed from an object
literal with two entries that normalize to the same name, the values are
combined and comma-joined, not overwritten — so Zitadel received
`x-zitadel-public-host: host, host` and rejected the request as an untrusted
instance domain, and `GetSecuritySettings` 404'd. Every other call in this
app goes through `createServerTransport` in `zitadel.ts`, which sets the same
headers on a real Connect `Headers` object via `.set()` (case-insensitive,
overwriting), so it never hits this. The failure is caught: the login page
falls back to no iframe origins (`frame-ancestors 'none'`, the secure
default), so there is no sign-in impact, but the security settings lookup
silently fails whenever a deployment's `CUSTOM_REQUEST_HEADERS` casing
doesn't exactly match the two hardcoded lowercase header names — as staging's
did (`X-Zitadel-Public-Host`).

Fix: build `fetchIframeOrigins()`'s headers on a real `Headers` object with
`.set()`/`.delete()`, matching `createServerTransport`'s pattern, so a
differently-cased `CUSTOM_REQUEST_HEADERS` entry overwrites the code-set
value instead of duplicating it. Offered upstream as
[zitadel/zitadel#12822][upstream-issue-security-settings-header]. See
`security-settings.test.ts` for the reproduction.

### `0003-redirect-on-vanished-auth-request.patch`

Sends the person to a fresh sign-in instead of "Unknown error occurred" when
the OIDC auth request or SAML request they are completing no longer exists.

Observed on staging on 2026-09-25, after a Zitadel rebuild: a browser reopened
a login URL carrying a `requestId` from before the rebuild. The person entered
credentials and changed their password, both accepted, then the login app
called `CreateCallback` to hand the relying party its result. Zitadel answered
`not_found`, "Auth Request does not exist" (COMMAND-jae5P), because the auth
request record itself was gone, not because anything the person did was
wrong. `loginWithOIDCAndSession` (`oidc.ts`) and `loginWithSAMLAndSession`
(`saml.ts`) already special-case `Code.FailedPrecondition` from this same call
(an auth request already completed, so the person lands on `/signedin`). This
patch adds the sibling case for `Code.NotFound`: the request record is simply
gone, so the current session proves nothing was ever handed back to the
relying party, and `/signedin` would be the wrong claim. The person is sent to
`/loginname` (upstream's own no-`requestId` landing page, see `page.tsx`
at the app root) with `requestExpired=true`, and `loginname/page.tsx` shows
one line, reusing the existing `error.sessionExpired` translation, instead of
adding a new key.

This is the one deliberate exception to "chrome only, no interactive-flow
patches" below: it does not touch credential verification, MFA, passkeys,
password reset or external IdPs, and it changes exactly one terminal step,
what happens after Zitadel itself says the request record is gone. Offered
upstream as [zitadel/zitadel#12821][upstream-issue-vanished-auth-request]. See
`oidc.test.ts` and `saml.test.ts` for the reproduction.

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
   and apply-checks `patches/*.patch`. If a patch fails, hand-merge the files it
   touches (0001: `logo.tsx`, `back-button.tsx`, `username-form.tsx`; 0002:
   `next.config.mjs`; 0003: `oidc.ts`, `saml.ts`, `loginname/page.tsx` and their
   tests; 0004: `security-settings.ts` and its test) and regenerate that
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

The published image is a modified work. [NOTICE](NOTICE) names the upstream project, the pinned version and the four patches.

Issue and pull request numbers cited in comments and documents dated before 2026-09-05 refer to the tracker before the history reset, archived offline. They do not resolve on GitHub.

[upstream]: https://github.com/zitadel/zitadel/tree/main/apps/login
[upstream-issue-vanished-auth-request]: https://github.com/zitadel/zitadel/issues/12821
[upstream-issue-security-settings-header]: https://github.com/zitadel/zitadel/issues/12822
