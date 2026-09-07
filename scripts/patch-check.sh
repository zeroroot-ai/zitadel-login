#!/usr/bin/env bash
# patch-check.sh — prove the patch set applies to the pinned upstream tag
# (zitadel-login#7). Runs as a PR job and as `make test`, so a bump of
# UPSTREAM_REF whose patch no longer applies goes red before the image build.
#
#   patch-check.sh            sparse-clone upstream at TAG (apps/login only),
#                             verify COMMIT, `git apply -p1 --check` every patch
#   patch-check.sh --selftest prove the check passes on a patch that applies
#                             and fails on one that does not (no network)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

check_tree() { # <tree> <patch-dir>
  local tree="$1" dir="$2" p rc=0
  ls "$dir"/*.patch >/dev/null 2>&1 || { echo "patch-check: no .patch files in $dir" >&2; return 1; }
  for p in "$dir"/*.patch; do
    if git -C "$tree" apply -p1 --check "$p"; then
      echo "OK: $(basename "$p") applies"
    else
      echo "FAIL: $(basename "$p") does not apply; rebase the patch (README.md)" >&2; rc=1
    fi
  done
  return $rc
}

selftest() {
  local t; t="$(mktemp -d)"; trap 'rm -rf "$t"' RETURN
  git -C "$t" init -q -b main up
  mkdir -p "$t/up/apps/login/src"
  printf 'export const a = 1;\n' > "$t/up/apps/login/src/logo.tsx"
  git -C "$t/up" -c user.name=t -c user.email=t@t add -A
  git -C "$t/up" -c user.name=t -c user.email=t@t commit -q -m base
  mkdir -p "$t/good" "$t/bad"
  cat > "$t/good/0001.patch" <<'P'
--- a/apps/login/src/logo.tsx
+++ b/apps/login/src/logo.tsx
@@ -1 +1 @@
-export const a = 1;
+export const a = 2;
P
  cat > "$t/bad/0001.patch" <<'P'
--- a/apps/login/src/logo.tsx
+++ b/apps/login/src/logo.tsx
@@ -1 +1 @@
-export const a = 99;
+export const a = 2;
P
  check_tree "$t/up" "$t/good" >/dev/null 2>&1 || { echo "SELFTEST BROKEN: applying patch rejected" >&2; return 2; }
  if check_tree "$t/up" "$t/bad" >/dev/null 2>&1; then echo "SELFTEST BROKEN: non-applying patch accepted" >&2; return 2; fi
  echo "OK: patch-check self-test: applying patch accepted, conflicting patch rejected"
}

case "${1:-}" in
  --selftest) selftest; exit ;;
  '') ;;
  *) echo "usage: $0 [--selftest]" >&2; exit 64 ;;
esac

eval "$("$HERE/upstream-ref.sh")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo "patch-check: sparse clone of $REPO at $TAG (apps/login)"
git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$TAG" "$REPO" "$WORK/up"
git -C "$WORK/up" sparse-checkout set apps/login
ACTUAL="$(git -C "$WORK/up" rev-parse HEAD)"
[ "$ACTUAL" = "$COMMIT" ] || { echo "FAIL: tag $TAG resolved to $ACTUAL, UPSTREAM_REF says $COMMIT (tag drift)" >&2; exit 1; }
check_tree "$WORK/up" "$ROOT/patches"
echo "OK: patch set applies to $TAG @ $COMMIT"
