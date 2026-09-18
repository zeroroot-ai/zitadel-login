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

# TRANSITIVE_OVERRIDES — "<name>@<version>" per line, whitespace separated.
# Everything here is pulled in by something else, so `pnpm add` would install a
# second copy at the root and leave what the app resolves untouched. A pnpm
# override is the mechanism that actually moves a transitive dependency.
#
#   sharp@0.35.4                               GHSA-rgj7-g3m4-5g8c, HIGH
#   @opentelemetry/propagator-jaeger@2.9.0     CVE-2026-59892, HIGH
#   @opentelemetry/core@2.8.0                  CVE-2026-54285, MEDIUM (zitadel-login#15)
#
# Add a line when a scan finds a fixable transitive CVE upstream has not moved.
# Delete one the moment an upstream tag ships the fixed version.
TRANSITIVE_OVERRIDES="${TRANSITIVE_OVERRIDES:-sharp@${SHARP_FLOOR} @opentelemetry/propagator-jaeger@2.9.0 @opentelemetry/core@2.8.0}"

TRANSITIVE_OVERRIDES="${TRANSITIVE_OVERRIDES}" node -e '
  const fs = require("fs"), f = "/src/package.json";
  const p = JSON.parse(fs.readFileSync(f, "utf8"));
  const add = {};
  for (const spec of (process.env.TRANSITIVE_OVERRIDES || "").split(/\s+/).filter(Boolean)) {
    const at = spec.lastIndexOf("@");
    if (at <= 0) { console.error("FAIL: bad override spec: " + spec); process.exit(1); }
    add[spec.slice(0, at)] = spec.slice(at + 1);
  }
  p.pnpm = p.pnpm || {};
  p.pnpm.overrides = Object.assign({}, p.pnpm.overrides, add);
  fs.writeFileSync(f, JSON.stringify(p, null, 2));
  console.log("overrides: " + Object.entries(add).map(([k, v]) => k + "@" + v).join(", "));
'
pnpm install --no-frozen-lockfile

# next 16.3 type-checks files that 16.2 did not, and upstream's
# apps/login/tsconfig.json includes "**/*.ts" while excluding only node_modules,
# acceptance, dockerized and vitest.config*. That pulls upstream's own .test.ts
# files into the PRODUCTION build's type check, and they do not pass it.
#
# Measured: ~30 errors on the 16.3.3 build, every single one in a .test.ts file
# (loginname, password, verify, session, verify-helper). Not one in application
# source. So this is not "the app does not work on 16.3" - it is the build
# type-checking files it does not ship.
#
# Narrowing the exclude list is the correct scope. It is NOT
# `typescript.ignoreBuildErrors`, which would switch off type checking for the
# real source too and hide a genuine break behind the same flag.
node -e '
  const fs = require("fs"), f = "/src/apps/login/tsconfig.json";
  const t = JSON.parse(fs.readFileSync(f, "utf8"));
  const want = ["**/*.test.ts", "**/*.test.tsx"];
  t.exclude = Array.from(new Set((t.exclude || []).concat(want)));
  fs.writeFileSync(f, JSON.stringify(t, null, 2));
  for (const w of want) {
    if (!t.exclude.includes(w)) { console.error("FAIL: " + w + " missing from exclude"); process.exit(1); }
  }
  console.log("tsconfig exclude: " + t.exclude.join(", "));
'

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

# Every override must have taken, or be absent from the tree entirely. An
# override that silently did nothing is the failure mode this whole file exists
# to prevent.
for spec in ${TRANSITIVE_OVERRIDES}; do
  name="${spec%@*}"; want="${spec##*@}"
  got=$(pnpm --filter @zitadel/login exec node -p \
    "try { require('${name}/package.json').version } catch (e) { 'absent' }")
  echo "${name}=${got} (want ${want} or absent)"
  case "${got}" in
    absent|"${want}") ;;
    *) echo "FAIL: ${name} is ${got}, expected ${want} or absent" >&2; exit 1 ;;
  esac
done
