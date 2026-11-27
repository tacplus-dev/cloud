#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests gates.yaml's map (#118): a land that changes only the top-level docs no other test reads (PROPOSALS.md,
# ROADMAP.md, STATE.md, HISTORY.md, LICENSE) runs the docs set, never full; the docs set runs the one test that reads
# them (tests/hosting_test.sh); README.md, which the tests read, and any other path stay full's. The sets are chosen
# as tacplus-dev/looper's repo-looper chooses them (choose_gates, glob_regex): a path no set names, a path full names,
# or a change to gates.yaml itself runs full. Needs bash, git and yq.
#
#   tests/gates_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
map=$here/gates.yaml
yq -e '.' "$map" >/dev/null 2>&1 || { echo "FAIL gates.yaml does not parse (or no yq)"; exit 1; }

# glob_regex PATTERN: the ERE matching the paths it names, as repo-looper's: without a slash a file's name at any
# depth, with one (a leading one too) the path from the root; * and ? within a directory, ** across them, a trailing
# slash everything under it.
glob_regex() {
  local p=$1 r='' c i=0
  [[ $p == */ ]] && p+="**"
  [[ $p == */* ]] || p="**/$p"
  p=${p#/}
  while ((i < ${#p})); do
    c=${p:i:1}
    if [[ ${p:i:3} == "**/" ]]; then r+="(.*/)?"; i=$((i + 3)); continue; fi
    if [[ ${p:i:2} == "**" ]]; then r+=".*"; i=$((i + 2)); continue; fi
    case $c in
      '*') r+='[^/]*' ;;
      '?') r+='[^/]' ;;
      .|^|$|+|'('|')'|'{'|'}'|'|'|'['|']'|\\) r+="\\$c" ;;
      *) r+=$c ;;
    esac
    i=$((i + 1))
  done
  echo "^$r\$"
}

mapfile -t sets < <(yq -r 'keys | .[]' "$map")
# gates PATH...: the gate set a land changing these paths runs (the sets' names joined by +, in the map's order).
gates() {
  local f s p hit seen=" " out=''
  for f in "$@"; do
    [ "$f" = gates.yaml ] && { echo full; return; }
    hit=
    for s in "${sets[@]}"; do
      while IFS= read -r p; do
        [[ -n $p && $f =~ $(glob_regex "$p") ]] || continue
        [ "$s" = full ] && { echo full; return; }
        hit=1; [[ $seen == *" $s "* ]] || seen+="$s "
        break
      done < <(yq -r ".[\"$s\"].paths // [] | .[]" "$map")
    done
    [ -n "$hit" ] || { echo full; return; }
  done
  for s in "${sets[@]}"; do [[ $seen == *" $s "* ]] && out+="${out:++}$s"; done
  echo "$out"
}

[ "$(yq -r '.docs.run // ""' "$map")" = tests/hosting_test.sh ] &&
  ok "the docs set runs the test that reads the docs" || fail "docs's run: [$(yq -r '.docs.run' "$map" 2>&1)]"
docs=(PROPOSALS.md ROADMAP.md STATE.md HISTORY.md LICENSE)
for f in "${docs[@]}"; do
  [ -f "$here/$f" ] || fail "$f: no such file"
  [ "$(gates "$f")" = docs ] && ok "a land changing only $f runs docs" || fail "$f alone runs [$(gates "$f")]"
done
[ "$(gates "${docs[@]}")" = docs ] && ok "a land changing all the docs runs docs" || fail "the docs together run [$(gates "${docs[@]}")]"
# A docs file no test or script but hosting_test.sh (which reads every tracked file) names outside a comment: one
# that reads it takes it to full.
for f in "${docs[@]}"; do
  for t in "$here"/tests/*.sh "$here"/ci/*.sh; do
    case ${t#"$here"/} in tests/hosting_test.sh|tests/gates_test.sh) continue ;; esac
    ! grep -vE '^[[:space:]]*#' "$t" | grep -qF -- "$f" || fail "$f is read by ${t#"$here"/}: it is full's"
  done
done
for f in README.md stacks/dev/main.tf tests/ci_test.sh ci/checks.sh gates.yaml docs/x.md; do
  [ "$(gates "$f")" = full ] && ok "a land changing $f runs full" || fail "$f runs [$(gates "$f")]"
done
[ "$(gates PROPOSALS.md README.md)" = full ] && ok "a docs change with README.md runs full" || fail "PROPOSALS.md and README.md run [$(gates PROPOSALS.md README.md)]"
exit "$failed"
