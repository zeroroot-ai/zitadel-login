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
#   check — fast, offline structural gate: UPSTREAM_REF parses (the only
#           version copy), the Dockerfile declares its ARGs with no defaults,
#           and the patch set exists.
#   test  — patch-set apply-check against the pinned upstream tag
#           (scripts/patch-check.sh, also the PR job). Needs network.
#   build — the container image IS the build artifact (docker build).
#   image — alias of build.
# ============================================================================

IMAGE_NAME ?= ghcr.io/zeroroot-ai/zitadel-login
NEXT_PUBLIC_LANDING_URL ?=

.PHONY: all build test check image help

all: check ## Default: run the fast offline gate

check: ## Offline gate: UPSTREAM_REF parses, the Dockerfile carries no version of its own, patches exist
	@set -eu; \
	bash scripts/upstream-ref.sh --selftest >/dev/null; \
	bash scripts/patch-check.sh --selftest >/dev/null; \
	bash scripts/upstream-ref.sh >/dev/null; \
	for A in UPSTREAM_REPO UPSTREAM_TAG UPSTREAM_COMMIT NEXT_PUBLIC_LANDING_URL; do \
	  grep -qxE "ARG $$A" Dockerfile || \
	    { echo "FAIL: Dockerfile must declare 'ARG $$A' with no default; UPSTREAM_REF is the only copy"; exit 1; }; \
	  ! grep -qE "^ARG $$A=" Dockerfile || \
	    { echo "FAIL: Dockerfile gives ARG $$A a default; delete it, the value comes from UPSTREAM_REF"; exit 1; }; \
	done; \
	ls patches/*.patch >/dev/null 2>&1 || \
	  { echo "FAIL: patches/ contains no .patch files"; exit 1; }; \
	echo "OK: UPSTREAM_REF ($$(bash scripts/upstream-ref.sh TAG) @ $$(bash scripts/upstream-ref.sh COMMIT)) is the only version copy; patch set present"

test: ## Apply-check the patch set against the pinned upstream tag (needs network)
	@bash scripts/patch-check.sh

build: ## Build the container image (clones upstream, applies patches, full Next.js build)
	@test -n "$(NEXT_PUBLIC_LANDING_URL)" || { echo "FAIL: set NEXT_PUBLIC_LANDING_URL=<landing origin>; an empty value ships an unbranded image"; exit 1; }
	docker build \
		--build-arg UPSTREAM_REPO=$$(bash scripts/upstream-ref.sh REPO) \
		--build-arg UPSTREAM_TAG=$$(bash scripts/upstream-ref.sh TAG) \
		--build-arg UPSTREAM_COMMIT=$$(bash scripts/upstream-ref.sh COMMIT) \
		--build-arg NEXT_PUBLIC_LANDING_URL=$(NEXT_PUBLIC_LANDING_URL) \
		-t $(IMAGE_NAME):$$(bash scripts/upstream-ref.sh TAG) .

image: build ## Alias of build (the image is the only artifact)

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
