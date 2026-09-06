# ============================================================================
# zeroroot-ai/zitadel-login — uniform Makefile contract
# ============================================================================
# Implements the org-wide target contract (gibson#171 slice 1.4, enforced by
# the makefile-contract workflow in zeroroot-ai/.github):
#
#     make build | test | check | image
#
# This repo is a THIN FORK: no vendored source, just UPSTREAM_REF + patches/ +
# a Dockerfile that clones upstream at the pinned tag and applies the patch
# set (see README.md). The verbs map accordingly:
#
#   check — fast, offline structural gate: UPSTREAM_REF parses, the Dockerfile
#           ARG pins match it (the "keep in lockstep" comment made executable),
#           and the patch set exists.
#   test  — patch-set apply-check against the pinned upstream tag (README
#           per-bump checklist step 3). Needs network; shallow-clones upstream.
#   build — the container image IS the build artifact (docker build).
#   image — alias of build.
# ============================================================================

IMAGE_NAME ?= ghcr.io/zeroroot-ai/zitadel-login
NEXT_PUBLIC_LANDING_URL ?=

.PHONY: all build test check image help

all: check ## Default: run the fast offline gate

check: ## Offline gate: UPSTREAM_REF <-> Dockerfile pin lockstep + patches exist
	@set -eu; \
	REPO=$$(sed -n 's/^REPO=//p' UPSTREAM_REF); \
	TAG=$$(sed -n 's/^TAG=//p' UPSTREAM_REF); \
	COMMIT=$$(sed -n 's/^COMMIT=//p' UPSTREAM_REF); \
	[ -n "$$REPO" ] && [ -n "$$TAG" ] && [ -n "$$COMMIT" ] || \
	  { echo "FAIL: UPSTREAM_REF must define REPO, TAG and COMMIT"; exit 1; }; \
	echo "$$COMMIT" | grep -qE '^[0-9a-f]{40}$$' || \
	  { echo "FAIL: UPSTREAM_REF COMMIT is not a full 40-char SHA"; exit 1; }; \
	grep -qF "ARG UPSTREAM_REPO=$$REPO" Dockerfile || \
	  { echo "FAIL: Dockerfile ARG UPSTREAM_REPO drifted from UPSTREAM_REF ($$REPO)"; exit 1; }; \
	grep -qF "ARG UPSTREAM_TAG=$$TAG" Dockerfile || \
	  { echo "FAIL: Dockerfile ARG UPSTREAM_TAG drifted from UPSTREAM_REF ($$TAG)"; exit 1; }; \
	grep -qF "ARG UPSTREAM_COMMIT=$$COMMIT" Dockerfile || \
	  { echo "FAIL: Dockerfile ARG UPSTREAM_COMMIT drifted from UPSTREAM_REF ($$COMMIT)"; exit 1; }; \
	ls patches/*.patch >/dev/null 2>&1 || \
	  { echo "FAIL: patches/ contains no .patch files"; exit 1; }; \
	echo "OK: UPSTREAM_REF ($$TAG @ $$COMMIT) matches Dockerfile pins; patch set present"

test: ## Apply-check the patch set against the pinned upstream tag (needs network)
	@set -eu; \
	REPO=$$(sed -n 's/^REPO=//p' UPSTREAM_REF); \
	TAG=$$(sed -n 's/^TAG=//p' UPSTREAM_REF); \
	COMMIT=$$(sed -n 's/^COMMIT=//p' UPSTREAM_REF); \
	WORK=$$(mktemp -d); trap 'rm -rf "$$WORK"' EXIT; \
	echo "Cloning $$REPO @ $$TAG (shallow) ..."; \
	git clone --quiet --depth 1 --branch "$$TAG" "$$REPO" "$$WORK/up"; \
	ACTUAL=$$(git -C "$$WORK/up" rev-parse HEAD); \
	[ "$$ACTUAL" = "$$COMMIT" ] || \
	  { echo "FAIL: tag $$TAG resolved to $$ACTUAL, expected $$COMMIT (tag drift)"; exit 1; }; \
	for P in $(CURDIR)/patches/*.patch; do \
	  echo "apply-check $$P"; \
	  git -C "$$WORK/up" apply -p1 --check "$$P" || \
	    { echo "FAIL: $$P does not apply cleanly against $$TAG — hand-merge + regenerate (README.md)"; exit 1; }; \
	done; \
	echo "OK: patch set applies cleanly against $$TAG @ $$COMMIT"

build: ## Build the container image (clones upstream, applies patches, full Next.js build)
	docker build \
		--build-arg NEXT_PUBLIC_LANDING_URL=$(NEXT_PUBLIC_LANDING_URL) \
		-t $(IMAGE_NAME):$$(sed -n 's/^TAG=//p' UPSTREAM_REF) .

image: build ## Alias of build (the image is the only artifact)

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
