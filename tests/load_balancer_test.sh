#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the public entry in the source (#21; decisions/network-exposure-2026-11-03.md, its addendum "we terminate TLS,
# not the cloud"): no module or stack declares a certificate (Compute's or Certificate Manager's), an SSL policy, an
# HTTP, HTTPS or SSL proxy or a URL map (ci/policy.sh refuses them in any plan too); the dev module's one firewall rule is
# the load balancer's, from Google's proxy and health-check ranges, so that the nodes' only ingress allow rule from
# outside the network is that one; and the NEGs' names, a contract with the Services that expose them
# (tacplus-dev/operator, tacplus-dev/fleet-seatrials), are the settings' and the README's alike. The dev stack's plan
# test checks the plan itself (stacks/dev/tests). Needs bash and git.
#
#   tests/load_balancer_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

# TLS or L7 on Google's side, as a resource or a data source.
tls='^(resource|data) "(google_certificate_manager_[a-z_]+|google_compute_(region_)?(ssl_certificate|managed_ssl_certificate|ssl_policy|target_https?_proxy|target_ssl_proxy|url_map))"'
mapfile -t tf < <(git -C "$here" ls-files -co --exclude-standard -- 'modules/*.tf' 'stacks/*.tf' | sed "s|^|$here/|")
[ "${#tf[@]}" -gt 0 ] || fail "no .tf files"
found=$(grep -nE "$tls" "${tf[@]}")
[ -z "$found" ] && ok "no certificate, SSL policy, HTTP(S) or SSL proxy or URL map in the modules and stacks (${#tf[@]} files)" ||
  fail "TLS or L7 on Google's side: $found"
probe=$(mktemp)
trap 'rm -f "$probe"' EXIT
for t in google_compute_ssl_certificate google_compute_managed_ssl_certificate google_certificate_manager_certificate \
  google_compute_target_https_proxy google_compute_region_target_https_proxy google_compute_target_ssl_proxy \
  google_compute_target_http_proxy google_compute_url_map google_compute_ssl_policy; do
  printf 'resource "%s" "x" {}\n' "$t" > "$probe"
  grep -qE "$tls" "$probe" || fail "the scan misses $t"
done
printf 'resource "google_compute_target_tcp_proxy" "x" {}\n' > "$probe"
grep -qE "$tls" "$probe" && fail "the scan refuses a TCP proxy" || ok "the scan finds each TLS or L7 type, and not a TCP proxy"

# The dev module's firewall rules: the load balancer's alone, from Google's two ranges.
rules=$(cat "$here"/modules/projects/dev/*.tf | sed -nE 's/^resource "google_compute_firewall" "([a-z_]+)".*/\1/p' | tr '\n' ' ')
[ "$rules" = "lb " ] && ok "the dev module's one firewall rule is the load balancer's" || fail "the dev module's firewall rules: [$rules]"
ranges=$(sed -nE 's/^ *google_proxy_ranges *= *\[(.*)\]$/\1/p' "$here/modules/projects/dev/load-balancer.tf")
[ "$ranges" = '"35.191.0.0/16", "130.211.0.0/22"' ] && ok "its sources are Google's proxy and health-check ranges" ||
  fail "its sources: [$ranges]"
grep -qE '^ *source_ranges *= *local\.google_proxy_ranges$' "$here/modules/projects/dev/load-balancer.tf" &&
  ok "the rule takes them as they are" || fail "the rule's source_ranges are not local.google_proxy_ranges"

# The NEGs' names: each in the settings, and in the README with its port.
mapfile -t negs < <(sed -nE 's/^ *([a-z-]+) *= *\{ port = ([0-9]+), neg = "([a-z0-9-]+)", endpoint_port = ([0-9]+), ready = (true|false) \}$/\1 \2 \3 \4/p' "$here/modules/settings/main.tf")
[ "${#negs[@]}" = 2 ] || fail "the settings' load_balancer is not two listeners: ${negs[*]}"
for l in "${negs[@]}"; do
  read -r name port neg endpoint <<< "$l"
  grep -qF "| \`$name\` | $port | \`$neg\` | $endpoint |" "$here/README.md" &&
    ok "the README names the NEG $neg ($name, port $port, endpoints on $endpoint)" ||
    fail "the README has no row | \`$name\` | $port | \`$neg\` | $endpoint |"
done
exit "$failed"
