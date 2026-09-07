# syntax=docker/dockerfile:1
#
# zeroroot-ai/zitadel-login (deploy#888) — a THIN fork of the upstream Zitadel
# Login V2 Next.js app (zitadel/zitadel monorepo, apps/login). We do NOT vendor
# the source: the builder stage clones upstream at the pinned tag, verifies the
# commit SHA, applies our isolated patch set (patches/*.patch), then runs the
# upstream build verbatim. Rebasing onto the next Zitadel tag is therefore a
# two-line change in UPSTREAM_REF + this file's ARGs (see README.md).
#
# The runtime stage is a byte-for-byte copy of upstream apps/login/Dockerfile so
# the image stays a drop-in replacement: same env contract, same ports, same
# entrypoint/healthcheck. The chart (deploy) only swaps login.image.repository.

# --- pinned upstream ref (keep in lockstep with UPSTREAM_REF) ---------------
ARG UPSTREAM_REPO=https://github.com/zitadel/zitadel.git
ARG UPSTREAM_TAG=v4.17.3
ARG UPSTREAM_COMMIT=41b11149c6997eddd7e38390912e12ff5f918a73

# Landing origin for the logo link + loginname back button (deploy#888 patch).
# NEVER hardcoded (respects the deploy#630 no-hardcoded-hostname guard) — passed
# in via --build-arg from the CI workflow's `vars.NEXT_PUBLIC_LANDING_URL`.
# Empty by default → the patch is inert and the UI renders exactly as upstream.
# NOTE: NEXT_PUBLIC_* is inlined into the client bundle at BUILD time (Next.js
# semantics), so changing it requires a rebuild. The marketing landing origin is
# stable and shared across envs, so a single baked value is the right tradeoff.
ARG NEXT_PUBLIC_LANDING_URL=""

# ---------------------------------------------------------------------------
# Stage 1: fetch upstream source at the pinned tag and apply our patch set.
# ---------------------------------------------------------------------------
FROM node:26@sha256:f5d1cc40abc10c2843339a2134d07817cf33c405cb16bfd052b0ed790254c3a3 AS source
ARG UPSTREAM_REPO
ARG UPSTREAM_TAG
ARG UPSTREAM_COMMIT
WORKDIR /src
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
FROM node:26@sha256:f5d1cc40abc10c2843339a2134d07817cf33c405cb16bfd052b0ed790254c3a3 AS builder
ARG NEXT_PUBLIC_LANDING_URL
ENV NEXT_PUBLIC_LANDING_URL=${NEXT_PUBLIC_LANDING_URL}
WORKDIR /src
COPY --from=source /src /src
RUN corepack enable
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile
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
# remains a drop-in replacement (env contract / ports / entrypoint). The one
# addition is the hardening RUN right after FROM; everything below it is
# upstream verbatim.
# ---------------------------------------------------------------------------
FROM node:26-alpine@sha256:2d984a15c9b54fd0aeb608b8e0d0d83529eb34d2966db27a1fb4f1edc3d298a3
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
