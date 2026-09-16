# syntax=docker/dockerfile:1
#
# zeroroot-ai/zitadel-login (deploy#888) — a THIN fork of the upstream Zitadel
# Login V2 Next.js app (zitadel/zitadel monorepo, apps/login). We do NOT vendor
# the source: the builder stage clones upstream at the pinned tag, verifies the
# commit SHA, applies our isolated patch set (patches/*.patch), then runs the
# upstream build verbatim. Rebasing onto the next Zitadel tag is therefore an
# edit of UPSTREAM_REF plus a patch re-resolve (see README.md). This file
# carries no version of its own.
#
# The runtime stage is a byte-for-byte copy of upstream apps/login/Dockerfile so
# the image stays a drop-in replacement: same env contract, same ports, same
# entrypoint/healthcheck. The chart (deploy) only swaps login.image.repository.

# --- upstream ref: NO defaults here. UPSTREAM_REF is the only copy ----------
# The image workflow reads UPSTREAM_REF through scripts/upstream-ref.sh and
# passes these as build args (zitadel-login#7). `make build` does the same.
# A build without them fails in stage 1 instead of cloning a stale tag.
ARG UPSTREAM_REPO
ARG UPSTREAM_TAG
ARG UPSTREAM_COMMIT

# Landing origin for the logo link + loginname back button (deploy#888 patch).
# NEVER hardcoded (respects the deploy#630 no-hardcoded-hostname guard) — passed
# in via --build-arg from the CI workflow's `vars.NEXT_PUBLIC_LANDING_URL`.
# REQUIRED: an empty value used to render the patch inert and ship an
# unbranded image (the first build, 2026-07-02). Stage 2 now fails.
# NOTE: NEXT_PUBLIC_* is inlined into the client bundle at BUILD time (Next.js
# semantics), so changing it requires a rebuild. The marketing landing origin is
# stable and shared across envs, so a single baked value is the right tradeoff.
ARG NEXT_PUBLIC_LANDING_URL

# ---------------------------------------------------------------------------
# Stage 1: fetch upstream source at the pinned tag and apply our patch set.
# ---------------------------------------------------------------------------
FROM node:24@sha256:be23f54a88d34e8824c741b19b91064094f92c1c97b194144bfc8b50d67258e2 AS source
ARG UPSTREAM_REPO
ARG UPSTREAM_TAG
ARG UPSTREAM_COMMIT
WORKDIR /src
RUN test -n "${UPSTREAM_REPO}" && test -n "${UPSTREAM_TAG}" && test -n "${UPSTREAM_COMMIT}" \
    || { echo "ERROR: UPSTREAM_REPO, UPSTREAM_TAG and UPSTREAM_COMMIT build args are required; they come from UPSTREAM_REF via scripts/upstream-ref.sh"; exit 1; }
RUN git clone --depth 1 --branch "${UPSTREAM_TAG}" "${UPSTREAM_REPO}" . \
    && ACTUAL="$(git rev-parse HEAD)" \
    && if [ "${ACTUAL}" != "${UPSTREAM_COMMIT}" ]; then \
         echo "ERROR: tag ${UPSTREAM_TAG} resolved to ${ACTUAL}, expected ${UPSTREAM_COMMIT} (tag drift)"; \
         exit 1; \
       fi
COPY patches/ /patches/
# Apply every patch in order; -p1 because the diffs are rooted at apps/login/...
RUN for p in /patches/*.patch; do echo "applying $p"; git apply -p1 --verbose "$p"; done

# ---------------------------------------------------------------------------
# Stage 2: build the Next.js standalone bundle with the upstream toolchain.
# Mirrors upstream CI (pnpm + nx); the login `build` script assembles the
# standalone (copies scripts/* + public, swaps server.mjs in as server.js).
# ---------------------------------------------------------------------------
FROM node:24@sha256:be23f54a88d34e8824c741b19b91064094f92c1c97b194144bfc8b50d67258e2 AS builder
ARG NEXT_PUBLIC_LANDING_URL
RUN test -n "${NEXT_PUBLIC_LANDING_URL}" \
    || { echo "ERROR: NEXT_PUBLIC_LANDING_URL build arg is empty; the image would ship unbranded. Set the NEXT_PUBLIC_LANDING_URL Actions variable (CI) or pass --build-arg (local)."; exit 1; }
ENV NEXT_PUBLIC_LANDING_URL=${NEXT_PUBLIC_LANDING_URL}
WORKDIR /src
COPY --from=source /src /src
RUN corepack enable
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

# Security bumps on top of the upstream lockfile.
#
# The install above is deliberately `--frozen-lockfile`, so editing a version in
# apps/login/package.json makes pnpm refuse the install outright, and patching
# pnpm-lock.yaml means a thousand-line diff that breaks on every upstream bump.
# So: install exactly what upstream locked, then move the two packages that ship
# a known hole, and prove the move happened.
#
# The logic lives in a script because it needs two different mechanisms - a
# filtered `add` for a direct dependency, a pnpm override for a transitive one -
# and nesting that in a Dockerfile RUN is how the first attempt shipped a
# version check that could never resolve. scripts/security-bumps.sh explains
# both.
#
# Drop this the moment an upstream tag ships next 16.3.3+.
ARG NEXT_FLOOR=16.3.3
ARG SHARP_FLOOR=0.35.4
COPY scripts/security-bumps.sh /tmp/security-bumps.sh
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    NEXT_FLOOR="${NEXT_FLOOR}" SHARP_FLOOR="${SHARP_FLOOR}" sh /tmp/security-bumps.sh \
    && rm -f /tmp/security-bumps.sh
# Build the standalone bundle in explicit dependency order (proto generate ->
# client build -> login standalone). Using the exact package names (not the
# short nx project alias) keeps this robust across nx project-naming changes.
# The login package's own `build` script runs `next build` + assembles the
# standalone (copies scripts/* + public, swaps server.mjs in as server.js).
# Output: apps/login/.next/standalone
RUN pnpm exec nx run @zitadel/proto:generate \
    && pnpm exec nx run @zitadel/client:build \
    && pnpm --filter @zitadel/login run build

# ---------------------------------------------------------------------------
# Stage 3: runtime — copy of upstream apps/login/Dockerfile so the image
# remains a drop-in replacement (env contract / ports / entrypoint). It has
# exactly TWO deliberate departures from upstream, both marked below:
#   1. the hardening RUN right after FROM (apk upgrade + npm removal);
#   2. the LICENSE/NOTICE copy at the end of the file.
# Everything between them is upstream verbatim. Do NOT delete either one to
# "restore upstream fidelity" — (2) in particular is a license obligation,
# not a style choice. See the comment on each.
# ---------------------------------------------------------------------------
FROM node:24-alpine@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf
# --- departure 1 of 2 from upstream apps/login/Dockerfile -------------------
# Hardening on top of the digest-pinned base (zitadel-login#1):
#   * `apk upgrade` pulls the distro fixes that landed after the node image
#     was built (2026-09: openssl 3.5.8-r0). The pin makes the base
#     reproducible; the upgrade keeps it patched between dependabot bumps.
#     Same pattern as gibson-executor#349.
#   * The global npm tree is removed. Nothing at runtime uses npm/npx: the
#     standalone server runs under plain `node` (see ENTRYPOINT/HEALTHCHECK).
#     npm ships its own vendored deps (undici, tar, ip-address, ...) that
#     lag behind their fixes and only add scan surface.
RUN apk upgrade --no-cache \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
WORKDIR /app
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs
# If /.env-file/.env is mounted into the container, its variables are made available to the server before it starts up.
RUN mkdir -p /.env-file && touch /.env-file/.env && chown -R nextjs:nodejs /.env-file

COPY --from=builder --chown=nextjs:nodejs /src/apps/login/.next/standalone ./

USER nextjs
ENV HOSTNAME="::" \
    PORT="3000" \
    NODE_ENV="production" \
    NODE_OPTIONS="--use-openssl-ca --require /app/load-ssl-cert-dir.cjs" \
    SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt" \
    ZITADEL_TLS_ENABLED="false" \
    OTEL_SERVICE_NAME="zitadel-login" \
    OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/node", "/app/healthcheck.mjs", "/ui/v2/login/ready"]
ENTRYPOINT ["/app/entrypoint.sh", "node", "apps/login/server.js"]

# --- departure 2 of 2 from upstream apps/login/Dockerfile -------------------
# This image redistributes ZITADEL's MIT-licensed code. MIT requires the
# copyright and permission notice in "all copies or substantial portions of
# the Software", and a published image is a copy. LICENSE is the upstream MIT
# text, unchanged. NOTICE names the upstream project and this fork's two
# patches. /licenses is the OCI convention.
#
# Upstream does not ship these because upstream's build context is the Zitadel
# monorepo, not this repo. Removing them would make the published image
# violate the license it is distributed under, so they stay.
#
# Last in the file on purpose: a COPY from the build context invalidates every
# layer below it, and there is none below this one.
COPY LICENSE /licenses/LICENSE
COPY NOTICE /licenses/NOTICE
