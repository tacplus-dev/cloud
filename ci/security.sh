#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The security job (#10): tacplus-dev/looper#49's floor, on what this repository is and pins, with looper-scan's
# policy. tacplus-dev/build's checks never reach this pipeline, which applies with the strongest credentials we have.
#
#   osv-scanner   the tree's dependency manifests and lock files (the commit's tree: git archive of HEAD)
#   govulncheck   -mode=binary, every pinned binary the pipeline runs or installs: OpenTofu, tflint and its google
#                 ruleset, yq, the scanners, the gitlab provider (bin/), the google provider, GitLab Runner and its
#                 fleeting plugin (bin/scan/); symbols present only. shellcheck is not Go.
#   gitleaks      the tree, and its history (every commit: a shallow clone is refused)
#   trivy         the CI image the jobs run in (ci/gitlab-project.gitlab-ci.yml's default image, by digest)
#
# The policy (looper-scan's): a secret fails, and so does a HIGH or CRITICAL finding with a fixed version, unless
# an unexpired entry of security-exceptions.yaml names it (its id, or an alias); an entry that has expired, or has
# more or less than id, reason, decided_by and expires (YYYY-MM-DD), fails; a tool that cannot run fails. The
# report: security/report.json (the findings, each blocking, accepted or neither; the problems; the verdict), with
# each tool's own report in security/raw/; the job's artifact.
#
#   ci/security.sh      # needs bin/ (ci/tools.sh, ci/tools.sh security), git, jq; exits 1 when the policy fails
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bin=$here/bin
export PATH=$bin:$PATH
out=$here/security
rm -rf "$out" && mkdir -p "$out/raw" "$out/norm"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
problems=()
problem() { problems+=("$1"); echo "security: $1" >&2; }
step() { echo "== $1"; }
today=$(date -u +%Y-%m-%d)

# Each tool's findings, normalized as looper-scan's: an array of {tool, kind (sca|secret), id, aliases, severity,
# fix, where, title}, in norm/.
JQ_LIB='def finding($tool; $kind; $id; $aliases; $sev; $fix; $where; $title):
  {tool: $tool, kind: $kind, id: $id, aliases: ($aliases // [] | map(select(. != $id)) | unique),
   severity: $sev, fix: $fix, where: $where, title: ($title // "" | tostring | .[0:300])};
def bucket: if . == null then "UNKNOWN" elif . >= 9 then "CRITICAL" elif . >= 7 then "HIGH"
  elif . >= 4 then "MEDIUM" elif . > 0 then "LOW" else "UNKNOWN" end;'
norm() { # name jq-program raw [jq args...]
  local name=$1 prog=$2 raw=$3; shift 3
  jq -s "$@" "$JQ_LIB $prog" "$raw" > "$out/norm/$name.json" || problem "$name: its report could not be read ($raw)"
}

# The commit's tree, as committed (no bin/, no .terraform/).
tree=$work/tree
mkdir -p "$tree"
git -C "$here" archive HEAD | tar -x -C "$tree" || problem "git archive HEAD: no commit to scan"

step "osv-scanner: the tree"
rc=0
osv-scanner scan source -r --format json --output "$out/raw/osv-scanner.json" "$tree" >/dev/null 2>"$out/raw/osv-scanner.log" || rc=$?
case $rc in
  0|1) norm osv-scanner '
    [.[0].results[]? | (.source.path | ltrimstr($root + "/")) as $where | .packages[]? | .package as $p
     | (.vulnerabilities // []) as $vs | .groups[]? | . as $g
     | ([$vs[] | select(.id as $i | $g.ids | index($i)) | .affected[]?.ranges[]?.events[]? | .fixed // empty] | length > 0) as $fix
     | finding("osv-scanner"; "sca"; $g.ids[0]; ($g.aliases + $g.ids);
               ($g.max_severity | if . == null or . == "" then null else tonumber end | bucket); $fix;
               ($p.name + "@" + ($p.version // "") + " (" + $where + ")"); ([$vs[] | select(.id == $g.ids[0]) | .summary // empty][0]))]' \
      "$out/raw/osv-scanner.json" --arg root "$tree" ;;
  128) echo "osv-scanner: no manifest or lock file it reads in the tree"; echo '[]' > "$out/norm/osv-scanner.json" ;;
  *) problem "osv-scanner exited $rc: $(grep -m1 -i error "$out/raw/osv-scanner.log")" ;;
esac

step "govulncheck -mode=binary: the pinned binaries"
shopt -s globstar nullglob
pinned=(tofu tflint 'tflint.d/**/tflint-ruleset-google' yq gitleaks osv-scanner trivy govulncheck
  'providers/**/terraform-provider-gitlab*' 'scan/plugins/**/terraform-provider-google*' scan/gitlab-runner
  scan/fleeting-plugin-googlecloud)
i=0
for p in "${pinned[@]}"; do
  found=()
  # shellcheck disable=SC2231 # the glob is the point
  for b in $bin/$p; do [ -f "$b" ] && found+=("$b"); done
  ((${#found[@]})) || { problem "govulncheck: no bin/$p to scan (ci/tools.sh, ci/tools.sh security)"; continue; }
  for b in "${found[@]}"; do
    i=$((i + 1)) rel=${b#"$here"/}
    if ! govulncheck -mode=binary -format json "$b" > "$out/raw/govulncheck-$i.json" 2>"$out/raw/govulncheck-$i.log"; then
      problem "govulncheck: $rel: $(grep -m1 . "$out/raw/govulncheck-$i.log")"; continue
    fi
    echo "$rel"
    norm "govulncheck-$i" '
      ([.[] | .osv // empty | {(.id): .}] | add // {}) as $osv
      | [.[] | .finding // empty | select(.trace[0].function != null)]
      | unique_by(.osv) | map(.trace[0] as $t
        | finding("govulncheck"; "sca"; .osv; ($osv[.osv].aliases // []); "HIGH"; ((.fixed_version // "") != "");
                  ($where + " (" + $t.module + "@" + ($t.version // "") + ", " + ($t.package // "") + "." + ($t.function // "") + ")");
                  $osv[.osv].summary))' \
      "$out/raw/govulncheck-$i.json" --arg where "$rel"
  done
done
shopt -u globstar nullglob

step "gitleaks: the tree and its history"
gl_norm='[.[0][]? | (.File | ltrimstr($root + "/")) as $f
  | ((if (.Commit // "") != "" then .Commit[0:12] + ":" else "" end) + $f + ":" + .RuleID + ":" + (.StartLine | tostring)) as $id
  | finding("gitleaks"; "secret"; $id; [.RuleID]; "CRITICAL"; true; $id; .Description)]'
if gitleaks dir --no-banner --redact --exit-code 0 -f json -r "$out/raw/gitleaks-tree.json" "$tree" >/dev/null 2>"$out/raw/gitleaks-tree.log"; then
  norm gitleaks-tree "$gl_norm" "$out/raw/gitleaks-tree.json" --arg root "$tree"
else
  problem "gitleaks dir: $(tail -1 "$out/raw/gitleaks-tree.log")"
fi
if [ "$(git -C "$here" rev-parse --is-shallow-repository 2>/dev/null)" != false ]; then
  problem "gitleaks git: $here is a shallow clone, or no repository: its history cannot be scanned (git fetch --unshallow)"
elif gitleaks git --no-banner --redact --exit-code 0 -f json -r "$out/raw/gitleaks-history.json" "$here" >/dev/null 2>"$out/raw/gitleaks-history.log"; then
  echo "$(git -C "$here" rev-list --count HEAD) commits"
  norm gitleaks-history "$gl_norm" "$out/raw/gitleaks-history.json" --arg root "$here"
else
  problem "gitleaks git: $(tail -1 "$out/raw/gitleaks-history.log")"
fi

step "trivy: the CI image"
image=$(yq -r '.default.image // ""' "$tree/ci/gitlab-project.gitlab-ci.yml" 2>/dev/null)
if [[ ! $image =~ @sha256:[0-9a-f]{64}$ ]]; then
  problem "trivy: the CI image is not pinned by digest: [$image]"
elif trivy image -q --scanners vuln --format json -o "$out/raw/trivy-image.json" "$image" 2>"$out/raw/trivy-image.log"; then
  echo "$image"
  norm trivy-image '
    [.[0].Results[]? | .Target as $t | (.Vulnerabilities // [])[]
     | finding("trivy"; "sca"; .VulnerabilityID; []; (.Severity // "UNKNOWN"); ((.FixedVersion // "") != "");
               ("the CI image: " + .PkgName + "@" + (.InstalledVersion // "") + " "
                + ($t | ltrimstr($image) | ltrimstr(" ") | if startswith("(") then . else "(" + . + ")" end)); .Title)]' \
    "$out/raw/trivy-image.json" --arg image "$image"
else
  problem "trivy image $image: $(tail -1 "$out/raw/trivy-image.log")"
fi

# security-exceptions.yaml, read as looper-scan reads it (tacplus-dev/looper#49): a list "exceptions:" of entries
# with exactly id, reason, decided_by and expires; a file it cannot read that way is a problem, never an empty list.
# The commit's, as the CI image is the commit's CI file's.
step "security-exceptions.yaml"
exceptions='[]'
if [ -f "$tree/security-exceptions.yaml" ]; then
  exceptions=$(awk '
    function flush() { if (n) printf "%s}", (out++ ? "," : "") cur; cur = ""; n = 0 }
    function str(v) { gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); return "\"" v "\"" }
    function field(s, k, v) { k = s; sub(/:.*/, "", k); v = s; sub(/^[^:]*:/, "", v)
      if (k !~ /^(id|reason|decided_by|expires)$/) { print "line " NR ": unknown key \"" k "\"" > "/dev/stderr"; bad = 1 }
      cur = cur (n++ ? "," : "{") "\"" k "\":" str(v) }
    BEGIN { printf "[" }
    /^[ \t]*(#|$)/ { next }
    /^exceptions:[ \t]*(\[\])?[ \t]*$/ { seen = 1; next }
    seen && /^  - [a-z_]+:/ { flush(); s = $0; sub(/^  - /, "", s); field(s); next }
    seen && n && /^    [a-z_]+:/ { s = $0; sub(/^    /, "", s); field(s); next }
    { print "line " NR ": not an exception entry: " $0 > "/dev/stderr"; bad = 1 }
    END { flush(); printf "]\n"; if (!seen && NR) { print "no exceptions: list" > "/dev/stderr"; bad = 1 }; exit bad }
  ' "$tree/security-exceptions.yaml" 2>"$work/exc.err") || { problem "security-exceptions.yaml: $(head -1 "$work/exc.err")"; exceptions='[]'; }
fi
while IFS= read -r e; do [ -z "$e" ] || problem "$e"; done < <(jq -r --arg today "$today" '.[] |
    if (.id // "") == "" then "an exception without an id"
    elif ((.reason // "") == "" or (.decided_by // "") == "") then "exception \(.id): it needs a reason and who decided (decided_by)"
    elif ((.expires // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not) then "exception \(.id): expires \(.expires // "" | @json) is not a date YYYY-MM-DD"
    elif .expires < $today then "exception \(.id) expired on \(.expires) (\(.decided_by): \(.reason))"
    else empty end' <<<"$exceptions")
echo "$(jq length <<<"$exceptions") entries"

# The policy, and the report.
norms=("$out"/norm/*.json)
[ -e "${norms[0]}" ] || norms=(/dev/null)
jq -s --argjson exc "$exceptions" --arg today "$today" '
  [.[][]] | unique_by([.tool, .id, .where]) | map(
    . as $f
    | ([$exc[] | select(.expires >= $today and (.id as $x | $f.id == $x or any($f.aliases[]; . == $x)))][0]) as $e
    | . + {excepted: ($e.id // null),
           blocking: ($e == null and (.kind == "secret" or ((.severity == "HIGH" or .severity == "CRITICAL") and .fix)))})
  | sort_by(if .blocking then 0 else 1 end, {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}[.severity] // 4, .tool, .id, .where)' \
  "${norms[@]}" > "$work/findings.json" || { problem "the findings could not be read together"; echo '[]' > "$work/findings.json"; }
blocking=$(jq '[.[] | select(.blocking)] | length' "$work/findings.json")
verdict=pass
((${#problems[@]})) && verdict="fail: ${problems[0]}"
[ "$verdict" = pass ] && ((blocking)) && verdict="fail: $blocking finding(s) the policy fails"
printf '%s\n' "${problems[@]}" | jq -R . | jq -s 'map(select(. != ""))' > "$work/problems.json"
jq -n --arg commit "$(git -C "$here" rev-parse HEAD 2>/dev/null)" --arg image "$image" --arg date "$today" --arg verdict "$verdict" \
  --slurpfile findings "$work/findings.json" --slurpfile problems "$work/problems.json" --argjson exceptions "$exceptions" \
  '{commit: $commit, date: $date, image: $image, verdict: $verdict, problems: $problems[0], exceptions: $exceptions, findings: $findings[0]}' \
  > "$out/report.json"

step "verdict"
jq -r '"\(.findings | length) finding(s): \([.findings[] | select(.blocking)] | length) failing the policy, \([.findings[] | select(.excepted)] | length) accepted by an exception."' "$out/report.json"
jq -r '.problems[] | "PROBLEM \(.)"' "$out/report.json"
jq -r '.findings[] | select(.blocking) | "FAIL \(.severity) \(.tool) \(.id): \(.where)\(if .title != "" then ": " + .title else "" end)"' "$out/report.json"
echo "security: $verdict (security/report.json)"
[ "$verdict" = pass ]
