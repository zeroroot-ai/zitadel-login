#!/usr/bin/env bash
# upstream-ref.sh — the one reader of UPSTREAM_REF (zeroroot-ai/.github#20,
# zitadel-login#7).
#
# UPSTREAM_REF is the single copy of the pinned upstream ZITADEL version. The
# Dockerfile, the image workflow (build args + the v<upstream> image tag), the
# patch check and the Makefile all read it through this script, so no second
# copy can drift.
#
#   upstream-ref.sh                 print REPO=..., TAG=..., COMMIT=...
#   upstream-ref.sh TAG             print one value
#   upstream-ref.sh --github-output append the three keys (lower-case) to $GITHUB_OUTPUT
#   upstream-ref.sh --selftest      prove the parser accepts a good file and rejects bad ones
#
# UPSTREAM_REF_FILE overrides the path (the self-test uses it).
set -euo pipefail

FILE="${UPSTREAM_REF_FILE:-$(dirname "$0")/../UPSTREAM_REF}"

parse() {
  local file="$1" repo="" tag="" commit="" line key val
  [ -f "$file" ] || { echo "upstream-ref: $file not found" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    [ "$key" != "$line" ] || { echo "upstream-ref: not KEY=VALUE: '$line'" >&2; return 1; }
    case "$key" in
      REPO)   [ -z "$repo" ]   || { echo "upstream-ref: duplicate REPO" >&2; return 1; };   repo="$val" ;;
      TAG)    [ -z "$tag" ]    || { echo "upstream-ref: duplicate TAG" >&2; return 1; };    tag="$val" ;;
      COMMIT) [ -z "$commit" ] || { echo "upstream-ref: duplicate COMMIT" >&2; return 1; }; commit="$val" ;;
      *) echo "upstream-ref: unknown key '$key'" >&2; return 1 ;;
    esac
  done < "$file"
  [[ "$repo" =~ ^https://[A-Za-z0-9./_-]+\.git$ ]] || { echo "upstream-ref: REPO must be an https .git URL, got '$repo'" >&2; return 1; }
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "upstream-ref: TAG must look like vX.Y.Z, got '$tag'" >&2; return 1; }
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "upstream-ref: COMMIT must be a full 40-hex SHA, got '$commit'" >&2; return 1; }
  REPO="$repo"; TAG="$tag"; COMMIT="$commit"
}

selftest() {
  local t; t="$(mktemp -d)"; trap 'rm -rf "$t"' RETURN
  printf 'REPO=https://github.com/zitadel/zitadel.git\nTAG=v1.2.3\n# comment\n\nCOMMIT=0123456789abcdef0123456789abcdef01234567\n' > "$t/good"
  printf 'REPO=https://github.com/zitadel/zitadel.git\nTAG=v1.2.3\n' > "$t/missing-commit"
  printf 'REPO=https://github.com/zitadel/zitadel.git\nTAG=1.2.3\nCOMMIT=0123456789abcdef0123456789abcdef01234567\n' > "$t/bad-tag"
  printf 'REPO=https://github.com/zitadel/zitadel.git\nTAG=v1.2.3\nCOMMIT=41b111\n' > "$t/short-commit"
  printf 'REPO=https://github.com/zitadel/zitadel.git\nTAG=v1.2.3\nTAG=v1.2.2\nCOMMIT=0123456789abcdef0123456789abcdef01234567\n' > "$t/dup-tag"
  printf 'REPO=https://github.com/zitadel/zitadel.git\nTAG=v1.2.3\nCOMMIT=0123456789abcdef0123456789abcdef01234567\nBRANCH=main\n' > "$t/unknown-key"
  printf 'TAG v1.2.3\n' > "$t/not-kv"
  parse "$t/good" >/dev/null || { echo "SELFTEST BROKEN: good file rejected" >&2; return 2; }
  [ "$TAG" = "v1.2.3" ] || { echo "SELFTEST BROKEN: TAG parsed as '$TAG'" >&2; return 2; }
  local f
  for f in missing-commit bad-tag short-commit dup-tag unknown-key not-kv; do
    if parse "$t/$f" 2>/dev/null; then echo "SELFTEST BROKEN: $f accepted" >&2; return 2; fi
  done
  echo "OK: upstream-ref self-test: good file parsed, 6 bad shapes rejected"
}

case "${1:-}" in
  --selftest) selftest ;;
  --github-output)
    parse "$FILE"
    [ -n "${GITHUB_OUTPUT:-}" ] || { echo "upstream-ref: GITHUB_OUTPUT is unset" >&2; exit 1; }
    printf 'repo=%s\ntag=%s\ncommit=%s\n' "$REPO" "$TAG" "$COMMIT" >> "$GITHUB_OUTPUT"
    ;;
  REPO|TAG|COMMIT) parse "$FILE"; eval "printf '%s\n' \"\$$1\"" ;;
  '') parse "$FILE"; printf 'REPO=%s\nTAG=%s\nCOMMIT=%s\n' "$REPO" "$TAG" "$COMMIT" ;;
  *) echo "usage: $0 [REPO|TAG|COMMIT|--github-output|--selftest]" >&2; exit 64 ;;
esac
