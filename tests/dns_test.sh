#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/dns.sh, the drift job's DNS check (#13), against a stub gcloud and a stub dig over fixtures (tests/stub/dns,
# tests/fixtures/dns): it asks both public resolvers, 8.8.8.8 and 1.1.1.1, for each record set of the zone but its SOA,
# and reports each answer that differs from the zone (in any order or case, a name's TXT strings excepted), saying the
# resolver, the record and both sides: during the cutover, the registrar's old name servers and a resolver's old
# address; it reports a resolver it cannot reach and a zone it cannot list; it reports nothing when they agree; it
# only lists and asks. The drift job checks the zone modules/settings names, in the dev project. Needs bash and jq.
#
#   tests/dns_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export STUB_LOG=$work/log PATH=$here/tests/stub/dns:$PATH

check() { # check SCENARIO [ARG...]
  export STUB_DNS=$here/tests/fixtures/dns/$1; shift
  : > "$STUB_LOG"; "$here/ci/dns.sh" "$@" > "$work/out" 2> "$work/err"
}
reports() { # reports WHAT EXPECTED-LINE-PART...: each part is in exactly one line of the report
  local what=$1 part n; shift
  for part in "$@"; do
    n=$(grep -cF -- "$part" "$work/out")
    [ "$n" = 1 ] || { fail "$what: [$part] in $n lines of: $(cat "$work/out" "$work/err")"; return; }
  done
  ok "$what"
}

check clean tacplus-dev tacplus-dev && [ ! -s "$work/out" ] && ok "resolvers answering what the zone holds: nothing reported" ||
  fail "clean: $(cat "$work/out" "$work/err")"
for r in 8.8.8.8 1.1.1.1; do
  for q in "tacplus.dev. A" "tacplus.dev. NS" "tacplus.dev. TXT" "www.tacplus.dev. CNAME" "seatrials.tacplus.dev. A" "dev.tacplus.dev. NS"; do
    grep -qxF "dig +short +time=5 +tries=2 @$r $q" "$STUB_LOG" || fail "@$r is not asked for $q: $(cat "$STUB_LOG")"
  done
done
grep -q ' SOA$' "$STUB_LOG" && fail "the zone's SOA is compared (its serial is the server's)" || ok "both resolvers are asked for each record set but the SOA"
grep -vE '^(gcloud dns record-sets list --zone=tacplus-dev --project=tacplus-dev --format=json|dig \+short \+time=5 \+tries=2 @(8\.8\.8\.8|1\.1\.1\.1) [a-z0-9.-]+ [A-Z]+)$' "$STUB_LOG" &&
  fail "the check runs more than the list and the questions" || ok "the check only lists and asks"

check cutover tacplus-dev tacplus-dev && ok "the check exits 0 when it finds something (drift reports, it does not fail)" ||
  fail "cutover: the check failed: $(cat "$work/err")"
reports "the registrar's old name servers, at each resolver" \
  "dns tacplus-dev: @8.8.8.8 answers tacplus.dev. NS with [ns-cloud-a1.googledomains.com. ns-cloud-a2.googledomains.com.], the zone holds [ns-cloud-b1.googledomains.com. ns-cloud-b2.googledomains.com.]" \
  "dns tacplus-dev: @1.1.1.1 answers tacplus.dev. NS with [ns-cloud-a1.googledomains.com. ns-cloud-a2.googledomains.com.], the zone holds [ns-cloud-b1.googledomains.com. ns-cloud-b2.googledomains.com.]"
reports "a resolver's old address" \
  "dns tacplus-dev: @1.1.1.1 answers seatrials.tacplus.dev. A with [146.148.80.132], the zone holds [203.0.113.10]"
reports "a delegation a resolver does not answer" \
  "dns tacplus-dev: @1.1.1.1 answers dev.tacplus.dev. NS with [], the zone holds [ns-cloud-c1.googledomains.com. ns-cloud-c2.googledomains.com.]"
[ "$(wc -l < "$work/out")" = 4 ] && ok "nothing else is reported (the records both sides agree on)" ||
  fail "the report is not those 4 lines: $(cat "$work/out")"

check unreachable tacplus-dev tacplus-dev && [ "$(wc -l < "$work/out")" = 6 ] &&
  reports "a resolver it cannot reach, once a record" "dns tacplus-dev: @1.1.1.1 cannot be asked for tacplus.dev. A: " "dns tacplus-dev: @1.1.1.1 cannot be asked for www.tacplus.dev. CNAME: " ||
  fail "unreachable: $(cat "$work/out" "$work/err")"
check clean tacplus-dev none && reports "a zone it cannot list is reported" "dns none: cannot list its records: ERROR: "
"$here/ci/dns.sh" tacplus-dev > /dev/null 2>&1 && fail "no zone: passed" || ok "no zone: usage"

# The drift job checks the zone modules/settings names, in the dev project, after the live audit.
# shellcheck source=ci/lib.sh
zone=$(ci_tmp=$work && source "$here/ci/lib.sh" && ci_zone)
[ "$zone" = "tacplus-dev tacplus-dev" ] && ok "ci_zone: the dev project and the zone modules/settings names" || fail "ci_zone: [$zone]"
grep -qF '"$here/dns.sh" $(ci_zone)' "$here/ci/drift.sh" && ok "drift runs the DNS check on it" || fail "ci/drift.sh does not run ci/dns.sh on ci_zone"
exit "$failed"
