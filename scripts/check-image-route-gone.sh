#!/usr/bin/env bash
# check-image-route-gone.sh — start the built login image and prove the
# Next.js image optimizer is not served.
#
# WHY. The published image is the login page: reachable before any
# authentication, from the internet. The image-optimization route carried
# an unauthenticated RCE (GHSA-2xp9-vwfh-vxw4, CVE-2026-75604), and this
# repo's mitigation is one config key, images.unoptimized (patches/0002),
# which the README says "removes the /_next/image route". Until this script
# existed that was asserted, never tested: nothing started the image and
# asked. A mitigation that is not tested is a claim.
#
# WHAT. Runs the image with a Zitadel it can never reach (the server starts
# without one; it only dials Zitadel on a page render), waits for the
# readiness path, then requests the optimizer with a well-formed query. The
# server must answer, and it must not answer with an image. A 200 with an
# image/* body means the optimizer is live and the image ships the surface
# the README says it does not.
#
#   check-image-route-gone.sh <image ref>
#   check-image-route-gone.sh --selftest   prove the assertion fails on a live optimizer
set -euo pipefail

BASE_PATH="/ui/v2/login"

# judge <status> <content-type> -> 0 when the optimizer is gone
judge() {
  local status="$1" ctype="$2"
  case "$status" in
    000) echo "no answer from the server"; return 1 ;;
    2??) case "$ctype" in
           image/*) echo "the optimizer answered $status with $ctype: the route is LIVE"; return 1 ;;
           *)       echo "answered $status but not an image ($ctype); treating a 2xx here as the route being present"; return 1 ;;
         esac ;;
    *) echo "the optimizer route answered $status ($ctype): not served"; return 0 ;;
  esac
}

if [ "${1:-}" = "--selftest" ]; then
  judge 400 "text/plain" >/dev/null || { echo "SELFTEST FAIL: a 400 must pass"; exit 1; }
  judge 404 "text/html" >/dev/null  || { echo "SELFTEST FAIL: a 404 must pass"; exit 1; }
  # THE FIXTURE THIS EXISTS FOR: a served optimizer must fail the gate.
  if judge 200 "image/webp" >/dev/null; then echo "SELFTEST FAIL: a 200 image/webp must fail"; exit 1; fi
  if judge 200 "text/html" >/dev/null;  then echo "SELFTEST FAIL: a 200 of any kind must fail"; exit 1; fi
  if judge 000 "" >/dev/null;           then echo "SELFTEST FAIL: no answer must fail"; exit 1; fi
  echo "OK: the route judge fails on a live optimizer and passes on an absent one"
  exit 0
fi

IMAGE="${1:?usage: $0 <image ref> | --selftest}"
NAME="zl-route-$$"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" -p 127.0.0.1:3000:3000 \
  -e ZITADEL_API_URL=http://127.0.0.1:9 \
  -e ZITADEL_SERVICE_USER_TOKEN=unused \
  "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:3000${BASE_PATH}/ready" || true)"
  [ "$code" != "000" ] && break
  sleep 1
done
echo "readiness path answered $code"
[ "$code" != "000" ] || { echo "the server never listened"; docker logs "$NAME" | tail -40; exit 1; }

url="http://127.0.0.1:3000${BASE_PATH}/_next/image?url=%2Fui%2Fv2%2Flogin%2Ffavicon.ico&w=64&q=75"
hdr="$(mktemp)"; trap 'rm -f "$hdr"; cleanup' EXIT
status="$(curl -s -o /dev/null -D "$hdr" -w '%{http_code}' "$url" || echo 000)"
ctype="$(grep -i '^content-type:' "$hdr" | head -1 | cut -d' ' -f2- | tr -d '\r')"
judge "$status" "${ctype:-none}"
