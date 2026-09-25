# zitadel-login — AGENTS.md

> **Workflow rules:** see [`zeroroot-ai/.github` → `AGENTS.md`](https://github.com/zeroroot-ai/.github/blob/main/AGENTS.md) — canonical for branching / commits / PRs / releases / merging. Conventional Commits MANDATORY. Never push to main. Never force-push.

## TL;DR

A **thin fork** of the upstream Zitadel Login V2 Next.js app: a pinned
upstream tag plus a small `patches/*.patch` set, built into
`ghcr.io/zeroroot-ai/zitadel-login:<zitadel-version>`. We self-host the
upstream app for chrome edits the branding API cannot express — we do
**not** reimplement login flows. Read `README.md` first; it is the
authoritative description of the fork structure.

## Architecture

No vendored source. `UPSTREAM_REF` pins `REPO`/`TAG`/`COMMIT`; the
`Dockerfile` clones upstream at that tag, verifies the SHA, applies the
patches, and runs upstream's own build. The patch set is the entire
customization surface.

## Gotchas

- **Do not add interactive-flow patches.** Password, MFA, passkey,
  reset, and IdP flows stay upstream's. Chrome only (explicit non-goal
  in `README.md`). One narrow, deliberate exception exists:
  `0003-redirect-on-vanished-auth-request.patch` (zeroroot-ai/hosted#196)
  changes what happens after verification already succeeded, when Zitadel
  reports the auth/SAML request record itself is gone. It does not touch
  credential verification. Read the patch's README section before treating
  it as license for more flow patches.
- **Patches are `git apply -p1` diffs rooted at `apps/login/...`** in
  the upstream monorepo. A patch that no longer applies after an
  upstream bump is the expected failure mode — rebase the patch, never
  fork more files.
- Branding that the label-policy API CAN express (colors, logo) belongs
  in the platform operator's Zitadel configuration, not here.

## Links

- Org-level workflow: [`AGENTS.md`](https://github.com/zeroroot-ai/.github/blob/main/AGENTS.md)
