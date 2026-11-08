#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/expiry.sh, the drift job's expiry check (#12; rotations, #26), over a fixture (tests/fixtures/expiry): it reports each
# expires_at of the stacks that is past, or within 30 days, saying where, what and when, so that the nightly drift
# files it and a commit renews it; it reports nothing further off; it reports a date it cannot read. The drift job
# checks every stack. Needs bash and GNU date.
#
#   tests/expiry_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fixture=$here/tests/fixtures/expiry/main.tf

EXPIRY_TODAY=2027-09-01 "$here/ci/expiry.sh" "$fixture" > "$work/out" 2> "$work/err" &&
  ok "the check exits 0 when it finds something (drift reports, it does not fail)" || fail "exit: $(cat "$work/err")"
grep -qF 'tacplus-dev/build:soon-bot expires on 2027-09-15, in 14 days' "$work/out" &&
  grep -qF "$fixture:4:" "$work/out" && ok "an expiry within 30 days: reported, where and when" || fail "soon: $(cat "$work/out")"
grep -qF 'tacplus-dev/build:expired-bot expired on 2027-08-31' "$work/out" && ok "a past expiry: reported" || fail "expired: $(cat "$work/out")"
! grep -qF 'far-bot' "$work/out" && ok "an expiry further than 30 days: nothing" || fail "far: $(cat "$work/out")"
[ "$(wc -l < "$work/out")" = 2 ] && grep -q 'renew' "$work/out" && ok "one line each, saying to renew it" || fail "lines: $(cat "$work/out")"

EXPIRY_TODAY=2027-01-01 "$here/ci/expiry.sh" "$fixture" > "$work/out" 2>&1 && [ ! -s "$work/out" ] &&
  ok "all far off: nothing reported" || fail "far off: $(cat "$work/out")"

printf '  "x:y" = { access_level = "reporter", expires_at = "2027-13-45" }\n' > "$work/bad.tf"
EXPIRY_TODAY=2027-01-01 "$here/ci/expiry.sh" "$work/bad.tf" > "$work/out" 2>&1
grep -qF "$work/bad.tf:1: x:y" "$work/out" && grep -qF 'not a date' "$work/out" && ok "a date it cannot read: reported" ||
  fail "bad date: $(cat "$work/out")"

# A rotation (#26): a rotate_by date, as the build trigger's, is reported the same way, saying to rotate it.
printf '  trigger = { description = "BUILD_TRIGGER_TOKEN of tacplus-dev/looper", rotate_by = "2027-09-10" }\n' > "$work/rotate.tf"
EXPIRY_TODAY=2027-09-01 "$here/ci/expiry.sh" "$work/rotate.tf" > "$work/out" 2>&1
grep -qF "$work/rotate.tf:1: BUILD_TRIGGER_TOKEN of tacplus-dev/looper is to be rotated by 2027-09-10, in 9 days: rotate it" "$work/out" &&
  ok "a rotation within 30 days: reported, saying to rotate it" || fail "rotate_by: $(cat "$work/out")"
EXPIRY_TODAY=2027-09-11 "$here/ci/expiry.sh" "$work/rotate.tf" > "$work/out" 2>&1
grep -qF 'BUILD_TRIGGER_TOKEN of tacplus-dev/looper was to be rotated by 2027-09-10: rotate it' "$work/out" &&
  ok "a rotation past due: reported" || fail "rotate_by past: $(cat "$work/out")"

# The drift job checks every stack, after the DNS check; the membership tacplus-dev/build needs has an expiry it reads.
grep -qF '"$here/expiry.sh" "$here"/../stacks/*/*.tf' "$here/ci/drift.sh" && ok "drift runs the expiry check on every stack" ||
  fail "ci/drift.sh does not run ci/expiry.sh on the stacks"
"$here/ci/expiry.sh" "$here"/stacks/*/*.tf > "$work/out" 2>&1 && ! grep -q 'not a date' "$work/out" &&
  grep -qE '^ *"tacplus-dev/build:tacplus-looper-bot" += \{.*expires_at += "[0-9]{4}-[0-9]{2}-[0-9]{2}"' "$here/stacks/gitlab/main.tf" &&
  ok "the stacks' expiries are dates it reads, tacplus-looper-bot's among them" || fail "the stacks: $(cat "$work/out")"
grep -qE '^ *trigger += \{ description = "BUILD_TRIGGER_TOKEN[^"]*", rotate_by += "[0-9]{4}-[0-9]{2}-[0-9]{2}"' "$here/stacks/gitlab/main.tf" &&
  ok "the build trigger's rotate_by is a date it reads (#26)" || fail "stacks/gitlab/main.tf: no build trigger rotate_by it reads"
exit "$failed"
