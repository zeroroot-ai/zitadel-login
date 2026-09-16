#!/usr/bin/env sh
# security-bumps.sh — move the packages that ship a known hole, then prove it.
#
# Runs inside the builder stage, after `pnpm install --frozen-lockfile`, against
# the upstream tree at /src. Upstream's newest release still pins both, so this
# is not a wait-for-upstream situation:
#
#   next   CVE-2026-75604, GHSA-2xp9-vwfh-vxw4 — both CRITICAL, unauthenticated
#          remote code execution on a page served before login. This image is
#          the login UI.
#   sharp  GHSA-rgj7-g3m4-5g8c — HIGH.
#
# The two need different mechanisms, which is what the first attempt got wrong:
#
#   next  is a DIRECT dependency of apps/login, so `pnpm --filter ... add` moves
#         it. Reading it back from /src/node_modules does NOT work: pnpm puts a
#         package in ITS OWN package's node_modules, so next lives at
#         /src/apps/login/node_modules/next. `pnpm exec` runs in that directory,
#         so plain resolution finds it.
#   sharp is TRANSITIVE — nothing declares it, next pulls it for image
#         optimization. `pnpm add` would install a second copy at the root and
#         leave what next resolves untouched. A pnpm override is the tool that
#         actually moves a transitive dependency.
set -eu

NEXT_FLOOR="${NEXT_FLOOR:?}"
SHARP_FLOOR="${SHARP_FLOOR:?}"
cd /src

pnpm --filter @zitadel/login add "next@${NEXT_FLOOR}"

node -e '
  const fs = require("fs"), f = "/src/package.json";
  const p = JSON.parse(fs.readFileSync(f, "utf8"));
  p.pnpm = p.pnpm || {};
  p.pnpm.overrides = Object.assign({}, p.pnpm.overrides, { sharp: process.env.SHARP_FLOOR });
  fs.writeFileSync(f, JSON.stringify(p, null, 2));
'
pnpm install --no-frozen-lockfile

# Prove it. A silent no-op here would ship a vulnerable image while the
# Dockerfile claimed otherwise, which is the whole reason this file exists.
got_next=$(pnpm --filter @zitadel/login exec node -p "require('next/package.json').version")
echo "next=${got_next} (want ${NEXT_FLOOR})"
[ "${got_next}" = "${NEXT_FLOOR}" ] || {
  echo "FAIL: next is ${got_next}, expected ${NEXT_FLOOR}" >&2; exit 1; }

# sharp is optional: the fork disables image optimization (patches/0002), so an
# absent sharp is a correct outcome and not a failure. A PRESENT one must be at
# the floor.
got_sharp=$(pnpm --filter @zitadel/login exec node -p \
  "try { require('sharp/package.json').version } catch (e) { 'absent' }")
echo "sharp=${got_sharp} (want ${SHARP_FLOOR} or absent)"
case "${got_sharp}" in
  absent|"${SHARP_FLOOR}") ;;
  *) echo "FAIL: sharp is ${got_sharp}, expected ${SHARP_FLOOR} or absent" >&2; exit 1 ;;
esac
