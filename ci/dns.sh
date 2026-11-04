#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The drift job's DNS check (#13): what the internet resolves against the zone this pipeline writes (tacplus.dev's,
# in the dev project). It asks both public resolvers, 8.8.8.8 and 1.1.1.1, for each record set of the zone but its
# SOA (its serial is the server's), its own NS among them, and reports each answer that differs, in any order or
# case (a TXT record's strings excepted). During the cutover (README, The tacplus.dev cutover) that is the
# registrar's old name servers and any resolver still on the zone it replaces; after it, a record changed by hand
# or a delegation gone. One line per finding, "dns <zone>: ...", on stdout; a zone it cannot list or a resolver it
# cannot ask is a finding too. It only lists and asks, and exits 0 when it finds something: ci/drift.sh files what
# it prints. It compares the data, not the TTLs, which a resolver counts down.
#
#   ci/dns.sh PROJECT ZONE    # needs gcloud (signed in: ci/lib.sh ci_gcp), dig and jq
set -uo pipefail
[ $# = 2 ] || { echo "usage: ci/dns.sh PROJECT ZONE" >&2; exit 1; }
project=$1 zone=$2
resolvers=(8.8.8.8 1.1.1.1)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! gcloud dns record-sets list --zone="$zone" --project="$project" --format=json > "$tmp/records.json" 2> "$tmp/err"; then
  echo "dns $zone: cannot list its records: $(grep -m1 '^ERROR' "$tmp/err" || head -c 300 "$tmp/err" | tr '\n' ' ')"
  exit 0
fi
# A record set's data as one comparable line: each item lower case but a TXT's, sorted, joined by spaces.
same() { # same TYPE: stdin, one item a line
  if [ "$1" = TXT ]; then sort; else tr '[:upper:]' '[:lower:]' | sort; fi | paste -sd' ' -
}
jq -r '.[] | select(.type != "SOA") | [.name, .type, (.rrdatas | join("\n") | @base64)] | @tsv' "$tmp/records.json" > "$tmp/sets" ||
  { echo "dns $zone: its records are not a list of record sets"; exit 0; }
while IFS=$'\t' read -r name type data; do
  want=$(base64 -d <<< "$data" | same "$type")
  for r in "${resolvers[@]}"; do
    if ! dig +short +time=5 +tries=2 "@$r" "$name" "$type" > "$tmp/answer" 2>&1; then
      echo "dns $zone: @$r cannot be asked for $name $type: $(head -c 300 "$tmp/answer" | tr '\n' ' ')"
      continue
    fi
    got=$(same "$type" < "$tmp/answer")
    [ "$got" = "$want" ] || echo "dns $zone: @$r answers $name $type with [$got], the zone holds [$want]"
  done
done < "$tmp/sets"
