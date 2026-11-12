#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/security.sh, the security job (#10), on a repository of its own (ci/security.sh, the CI file, an
# exceptions file) with gitleaks itself and stubs for osv-scanner, govulncheck and trivy (tests/stub): a clean tree
# passes, with its report; a secret planted in the tree fails, and so does one only in its history, and a shallow
# clone (its history unscanned); an expired exception fails, and one with a key looper-scan does not read; a HIGH
# or CRITICAL finding with a fixed version fails (trivy on the CI image, by its digest; govulncheck on a pinned
# binary, symbols present; osv-scanner on the tree), unless an unexpired exception names it or an alias; one
# without a fix, a MEDIUM one, or a govulncheck module-level one does not; a pinned binary missing fails, and so does
# a tool that cannot run. Needs bash, git, jq, gitleaks and yq (bin/: ci/tools.sh).
#
#   tests/security_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$here/bin:$PATH
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
for t in gitleaks yq jq git; do command -v "$t" >/dev/null || { echo "FAIL no $t (ci/tools.sh)"; exit 1; }; done

# The base repository: what ci/security.sh reads, committed, and a bin/ of the pinned binaries' names (empty files:
# the govulncheck stub reads none), the stubs and the real gitleaks and yq.
base=$work/base
mkdir -p "$base/ci" "$base/bin/tflint.d/x" "$base/bin/providers/x" "$base/bin/scan"
cp "$here/ci/security.sh" "$here/ci/gitlab-project.gitlab-ci.yml" "$base/ci/"
printf '/bin/\n/security/\n' > "$base/.gitignore"
echo "a clean tree" > "$base/README.md"
printf 'exceptions:\n' > "$base/security-exceptions.yaml"
for b in tofu tflint tflint.d/x/tflint-ruleset-google providers/x/terraform-provider-gitlab_v1 \
         providers/x/terraform-provider-google_v8 providers/x/terraform-provider-kubernetes_v3 providers/x/terraform-provider-anthropic_v1 scan/gitlab-runner \
         scan/fleeting-plugin-googlecloud; do
  : > "$base/bin/$b"
done
for s in osv-scanner govulncheck trivy; do cp "$here/tests/stub/$s" "$base/bin/$s"; done
ln -s "$(command -v gitleaks)" "$base/bin/gitleaks"
ln -s "$(command -v yq)" "$base/bin/yq"
git -C "$base" init -q
git -C "$base" -c user.name=t -c user.email=t@t add -A
git -C "$base" -c user.name=t -c user.email=t@t commit -qm base

# repo: a fresh copy of the base repository, its path on stdout.
repo() { local r; r=$(mktemp -d "$work/r.XXXX") && cp -a "$base/." "$r/" && echo "$r"; }
commit() { git -C "$1" -c user.name=t -c user.email=t@t add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$2"; }
# scan REPO [VAR=VALUE...]: ci/security.sh in REPO with those variables; its exit code, its output in REPO/log.
scan() {
  local r=$1; shift
  env "$@" "$r/ci/security.sh" > "$r/log" 2>&1
}
verdict() { jq -r .verdict "$1/security/report.json" 2>/dev/null; }
exceptions() { # REPO ID EXPIRES [EXTRA-LINE]: security-exceptions.yaml with that one entry, committed
  printf 'exceptions:\n  - id: %s\n    reason: "a test"\n    decided_by: "tests/security_test.sh"\n    expires: %s\n' "$2" "$3" \
    > "$1/security-exceptions.yaml"
  [ -z "${4:-}" ] || echo "$4" >> "$1/security-exceptions.yaml"
  commit "$1" exceptions
}
# A token gitleaks knows (a GitHub personal access token), made here so that this file holds none.
token() { printf 'ghp_%s' "$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 36)"; }
trivy_json() { # FILE SEVERITY FIXED
  jq -n --arg s "$2" --arg f "$3" '{Results: [{Target: "debian 13.7", Vulnerabilities: [
    {VulnerabilityID: "CVE-2026-0001", PkgName: "libfoo", InstalledVersion: "1.0", FixedVersion: $f, Severity: $s, Title: "a test"}]}]}' > "$1"
}

r=$(repo)
if scan "$r" STUB_LOG="$r/stub.log"; then
  [ "$(verdict "$r")" = pass ] && ok "a clean tree passes, its report security/report.json" || fail "a clean tree: verdict $(verdict "$r")"
else
  fail "a clean tree fails: $(tail -5 "$r/log")"
fi
[ "$(jq -r .commit "$r/security/report.json" 2>/dev/null)" = "$(git -C "$r" rev-parse HEAD)" ] || fail "the report does not name the commit"
image=$(yq -r .default.image "$here/ci/gitlab-project.gitlab-ci.yml")
grep -qx "trivy $image" "$r/stub.log" 2>/dev/null && ok "trivy scans the CI image, by its digest" || fail "trivy scanned: $(cat "$r/stub.log" 2>/dev/null)"
for b in tofu tflint tflint-ruleset-google yq gitleaks osv-scanner trivy govulncheck terraform-provider-gitlab_v1 \
         terraform-provider-google_v8 terraform-provider-kubernetes_v3 terraform-provider-anthropic_v1 gitlab-runner fleeting-plugin-googlecloud; do
  grep -q "/$b\$" "$r/log" || fail "govulncheck did not scan $b"
done
ok "govulncheck scans every pinned binary"

r=$(repo)
echo "token = \"$(token)\"" > "$r/config.txt" && commit "$r" "a secret"
if scan "$r"; then fail "a planted secret passes"
elif jq -e '[.findings[] | select(.tool == "gitleaks" and .blocking and .id == "config.txt:github-pat:1")] | length > 0' "$r/security/report.json" >/dev/null 2>&1; then
  ok "a secret planted in the tree fails the job"
else fail "a planted secret: $(tail -5 "$r/log")"; fi
grep -q 'ghp_' "$r/security/report.json" "$r"/security/raw/*.json && fail "the report holds the secret (not redacted)" || ok "the report redacts it"

r=$(repo)
echo "token = \"$(token)\"" > "$r/config.txt" && commit "$r" "a secret"
rm "$r/config.txt" && commit "$r" "the secret removed"
if scan "$r"; then fail "a secret in the history passes"
elif jq -e '[.findings[] | select(.tool == "gitleaks" and .blocking)] | length == 1' "$r/security/report.json" >/dev/null 2>&1; then
  ok "a secret only in the history fails the job"
else fail "a secret in the history: $(tail -5 "$r/log")"; fi

r=$(repo)
echo more >> "$r/README.md" && commit "$r" second
git clone -q --depth 1 "file://$r" "$work/shallow"
cp -a "$r/bin" "$work/shallow/"
if scan "$work/shallow"; then fail "a shallow clone passes"
else grep -q 'shallow' "$work/shallow/log" && ok "a shallow clone fails: its history is not scanned" || fail "a shallow clone: $(tail -3 "$work/shallow/log")"; fi

r=$(repo)
exceptions "$r" CVE-2026-0001 2000-01-01
if scan "$r"; then fail "an expired exception passes"
else grep -q 'exception CVE-2026-0001 expired on 2000-01-01' "$r/log" && ok "an expired exception fails the job" || fail "an expired exception: $(tail -3 "$r/log")"; fi

r=$(repo)
exceptions "$r" CVE-2026-0001 2999-12-31 '    severity: high'
if scan "$r"; then fail "an exception with an unknown key passes"
else grep -q 'unknown key "severity"' "$r/log" && ok "an exception with a key looper-scan does not read fails" || fail "an unknown key: $(tail -3 "$r/log")"; fi

trivy_json "$work/high-fixed.json" HIGH 1.1
trivy_json "$work/critical-nofix.json" CRITICAL ""
trivy_json "$work/medium-fixed.json" MEDIUM 1.1
r=$(repo)
scan "$r" STUB_TRIVY_JSON="$work/high-fixed.json" && fail "a HIGH finding with a fix in the CI image passes" ||
  { grep -q 'FAIL HIGH trivy CVE-2026-0001' "$r/log" && ok "a HIGH finding with a fixed version fails (trivy, the CI image)" || fail "trivy HIGH: $(tail -3 "$r/log")"; }
exceptions "$r" CVE-2026-0001 2999-12-31
scan "$r" STUB_TRIVY_JSON="$work/high-fixed.json" && [ "$(jq -r '.findings[0].excepted' "$r/security/report.json")" = CVE-2026-0001 ] &&
  ok "an unexpired exception accepts it" || fail "an exception did not accept it: $(tail -3 "$r/log")"
r=$(repo)
scan "$r" STUB_TRIVY_JSON="$work/critical-nofix.json" && ok "a CRITICAL finding without a fix does not fail" || fail "CRITICAL, no fix: $(tail -3 "$r/log")"
scan "$r" STUB_TRIVY_JSON="$work/medium-fixed.json" && ok "a MEDIUM finding with a fix does not fail" || fail "MEDIUM: $(tail -3 "$r/log")"

cat > "$work/gv.json" <<'EOF'
{"osv": {"id": "GO-2026-0002", "aliases": ["CVE-2026-0002"], "summary": "a test"}}
{"finding": {"osv": "GO-2026-0002", "fixed_version": "v0.2.0", "trace": [{"module": "golang.org/x/net", "version": "v0.1.0", "package": "golang.org/x/net/http2", "function": "Serve"}]}}
EOF
grep -v '"function"' "$work/gv.json" > "$work/gv-module.json"
echo '{"finding": {"osv": "GO-2026-0002", "fixed_version": "v0.2.0", "trace": [{"module": "golang.org/x/net", "version": "v0.1.0"}]}}' >> "$work/gv-module.json"
r=$(repo)
scan "$r" STUB_GOVULNCHECK_JSON="$work/gv.json" STUB_GOVULNCHECK_FOR=gitlab-runner && fail "a govulncheck finding with a fix passes" ||
  { grep -q 'FAIL HIGH govulncheck GO-2026-0002: bin/scan/gitlab-runner' "$r/log" && ok "a pinned binary's vulnerable symbol with a fix fails (govulncheck)" || fail "govulncheck: $(tail -3 "$r/log")"; }
exceptions "$r" CVE-2026-0002 2999-12-31
scan "$r" STUB_GOVULNCHECK_JSON="$work/gv.json" STUB_GOVULNCHECK_FOR=gitlab-runner && ok "an exception naming its alias accepts it" ||
  fail "an alias's exception: $(tail -3 "$r/log")"
r=$(repo)
scan "$r" STUB_GOVULNCHECK_JSON="$work/gv-module.json" && ok "a module-level govulncheck finding (no symbol present) does not fail" ||
  fail "module level: $(tail -3 "$r/log")"

jq -n '{results: [{source: {path: "x/go.mod"}, packages: [{package: {name: "golang.org/x/net", version: "0.1.0"},
  vulnerabilities: [{id: "GO-2026-0003", summary: "a test", affected: [{ranges: [{events: [{introduced: "0"}, {fixed: "0.2.0"}]}]}]}],
  groups: [{ids: ["GO-2026-0003"], aliases: ["CVE-2026-0003"], max_severity: "7.5"}]}]}]}' > "$work/osv.json"
r=$(repo)
scan "$r" STUB_OSV_JSON="$work/osv.json" STUB_OSV_RC=1 && fail "an osv-scanner finding with a fix passes" ||
  { grep -q 'FAIL HIGH osv-scanner GO-2026-0003: golang.org/x/net@0.1.0 (x/go.mod)' "$r/log" && ok "a dependency's HIGH finding with a fix fails (osv-scanner)" || fail "osv: $(tail -3 "$r/log")"; }
r=$(repo)
scan "$r" STUB_OSV_RC=128 && ok "a tree with no manifest osv-scanner reads passes" || fail "osv 128: $(tail -3 "$r/log")"

r=$(repo)
rm "$r/bin/scan/gitlab-runner"
scan "$r" && fail "a missing pinned binary passes" ||
  { grep -q 'no bin/scan/gitlab-runner to scan' "$r/log" && ok "a pinned binary missing fails" || fail "missing binary: $(tail -3 "$r/log")"; }
r=$(repo)
scan "$r" STUB_TRIVY_RC=1 && fail "trivy failing passes" ||
  { grep -q 'PROBLEM trivy image' "$r/log" && ok "a tool that cannot run fails" || fail "trivy failing: $(tail -3 "$r/log")"; }

# The scanners built here (ci/tools.sh, gobuild), as built: with the fixed klauspost/compress (GO-2026-6865) and brotli
# (GO-2026-6888), not their upstreams' (#24). bin/osv-scanner only after ci/tools.sh security.
fixed() { # BINARY MODULE VERSION: BINARY has no MODULE older than VERSION
  local v
  v=$(go version -m "$1" | awk -v m="$2" '$1 == "dep" && $2 == m { print $3 }')
  [ -z "$v" ] || [ "$(printf '%s\n%s\n' "${v#v}" "${3#v}" | sort -V | head -1)" = "${3#v}" ]
}
if ! command -v go >/dev/null; then fail "no go: the scanners' modules cannot be read"
else
  for b in gitleaks osv-scanner; do
    p=$here/bin/$b
    [ -f "$p" ] || { [ "$b" = osv-scanner ] && continue; fail "no bin/$b (ci/tools.sh)"; continue; }
    fixed "$p" github.com/klauspost/compress v1.20.2 && fixed "$p" github.com/andybalholm/brotli v1.2.7 &&
      ok "bin/$b is built with klauspost/compress >= v1.20.2 and brotli >= v1.2.7" ||
      fail "bin/$b: $(go version -m "$p" | grep -E 'klauspost/compress|andybalholm/brotli' | awk '{print $2 "@" $3}' | tr '\n' ' ')"
  done
  # The manager's binaries (ci/runner.sh, #40), as built: with the fixed x/net, klauspost/compress and go-jose
  # (CVE-2026-116587, in step with tacplus-dev/cluster's runner build, #44), not their upstreams'.
  for b in gitlab-runner fleeting-plugin-googlecloud; do
    p=$here/bin/manager/$b
    [ -f "$p" ] || { fail "no bin/manager/$b (ci/tools.sh)"; continue; }
    fixed "$p" golang.org/x/net v0.62.0 && fixed "$p" github.com/klauspost/compress v1.20.2 &&
      fixed "$p" github.com/go-jose/go-jose/v4 v4.1.6 &&
      ok "bin/manager/$b is built with x/net >= v0.62.0, klauspost/compress >= v1.20.2 and go-jose >= v4.1.6" ||
      fail "bin/manager/$b: $(go version -m "$p" | grep -E 'x/net|klauspost/compress|go-jose' | awk '{print $2 "@" $3}' | tr '\n' ' ')"
  done
fi

[ "$failed" = 0 ] && echo "security: all passed" || { echo "security: FAILED"; exit 1; }
