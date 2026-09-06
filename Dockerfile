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
ARG UPSTREAM_TAG=v4.14.0
ARG UPSTREAM_COMMIT=10b1af91d68700707d41e820545e478cf267511b

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
FROM node:24 AS source
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
FROM node:24 AS builder
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
# Stage 3: runtime — verbatim copy of upstream apps/login/Dockerfile so the
# image remains a drop-in replacement (env contract / ports / entrypoint).
# ---------------------------------------------------------------------------
FROM node:24-alpine
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
