#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The drift job's expiry check (#12): each `expires_at = "YYYY-MM-DD"` of the stacks' source (the gitlab stack's
# memberships), one a line, keyed by its line's first string, that is past or within EXPIRY_DAYS days (30) of today,
# one line each, which the drift job files. An expiry is a date in a commit, never computed (the plan must be the
# commit's alone): renewing it is a commit of a later date, which the pipeline applies (README, Memberships). It
# exits 0 when it finds something: drift reports, it does not fail. It reads files only.
#
#   ci/expiry.sh FILE...    # EXPIRY_TODAY (YYYY-MM-DD, default today, UTC) for the tests; needs GNU date
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: ci/expiry.sh FILE..." >&2; exit 1; }
today=${EXPIRY_TODAY:-$(date -u +%F)}
days=${EXPIRY_DAYS:-30}
now=$(date -u -d "$today" +%s)
for f in "$@"; do
  { grep -nE 'expires_at *= *"[^"]*"' "$f" || true; } | while IFS= read -r line; do
    n=${line%%:*} text=${line#*:}
    what=$(sed -n 's/^[^"]*"\([^"]*\)".*/\1/p' <<< "$text")
    when=$(sed -n 's/.*expires_at *= *"\([^"]*\)".*/\1/p' <<< "$text")
    if ! [[ $when =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! at=$(date -u -d "$when" +%s 2>/dev/null) ||
      [ "$(date -u -d "@$at" +%F)" != "$when" ]; then
      echo "expiry: $f:$n: $what: expires_at \"$when\" is not a date YYYY-MM-DD"
      continue
    fi
    left=$(( (at - now) / 86400 ))
    if [ "$left" -lt 0 ]; then
      echo "expiry: $f:$n: $what expired on $when: renew it (a commit of a later date)"
    elif [ "$left" -le "$days" ]; then
      echo "expiry: $f:$n: $what expires on $when, in $left days: renew it (a commit of a later date)"
    fi
  done
done
