#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests that this repository runs in any folder handed to it (#8): no tracked file names an organization's
# resource (or looks one up, or grants on one) or the host that hands the folder over today, but the README's
# hosting note (between its markers `<!-- hosting note -->` and `<!-- /hosting note -->`). ROADMAP.md and HISTORY.md
# are not this repository's code but its record (Jody's, and the looper's append-only log): they are not read. The
# patterns are built here, so that this file does not hold them either. Needs bash and git.
#
#   tests/hosting_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
# An organization's resource name, a lookup or grant of one (the google provider's organization resources, gcloud's
# organization flag), the host.
pattern="organ""izations/|google_organ""ization|--organ""ization|sea""beam"

mapfile -t files < <(git -C "$here" ls-files -co --exclude-standard | grep -vxE 'ROADMAP\.md|HISTORY\.md')
[ "${#files[@]}" -gt 0 ] || { echo "FAIL no files"; exit 1; }
for f in "${files[@]}"; do
  [ -f "$here/$f" ] || continue
  if [ "$f" = README.md ]; then
    found=$(sed '/^<!-- hosting note -->$/,/^<!-- \/hosting note -->$/d' "$here/$f" | grep -niE "$pattern")
  else
    found=$(grep -niIE "$pattern" "$here/$f")
  fi
  [ -z "$found" ] || fail "$f names an organization or the host: $(head -3 <<< "$found" | tr '\n' ' ')"
done
[ "$(grep -cxE '<!-- /?hosting note -->' "$here/README.md")" = 2 ] || fail "the README has no hosting note between its two markers"
[ "$failed" = 0 ] && ok "no organization or host named outside the README's hosting note (${#files[@]} files)"

# The scan itself: it finds what it is for.
probe=$(mktemp)
trap 'rm -f "$probe"' EXIT
printf 'parent = "%s"\n' "organ""izations/123" > "$probe"
grep -qiE "$pattern" "$probe" && ok "the scan finds an organization's resource name" || fail "the scan misses an organization's resource name"
printf 'host: %s\n' "Sea""Beam" > "$probe"
grep -qiE "$pattern" "$probe" && ok "the scan finds the host's name, in any case" || fail "the scan misses the host's name"
exit "$failed"
