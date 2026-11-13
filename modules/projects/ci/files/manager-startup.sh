#!/bin/bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The startup-script of the runner manager (modules/projects/ci). It installs GitLab Runner and the googlecloud
# fleeting plugin, our arm64 builds (ci/runner.sh, #40), from the bucket the VM's metadata names (runner-bucket), which
# only the manager's account reads, with the VM's token: each object is named by its SHA-256 and refused unless it has
# the one the metadata pins. Nothing comes from upstream, and no package is installed: gitlab-runner's service is the
# one upstream's package sets up, its user and its unit (gitlab-runner install). Then config.toml (metadata
# runner-config) with each pool's token from Secret Manager (runner-token-<pool>, its only enabled version: the gitlab
# stack replaces it when it re-registers a runner), and gitlab-runner restarted. Until a pool's token exists (the
# gitlab stack has not run yet), it waits for it. Nothing here prints a token.
#
# The config is pushed to the running manager, not by replacing it (#46): the ci stack updates the metadata in place,
# and runner-config-watch, a unit this script installs, re-runs this script (google-startup-scripts.service) when the
# metadata changes. That run rewrites config.toml, which gitlab-runner reloads by itself, its jobs untouched: it is
# restarted only on a new build, or when it is not running. Beside it, runner-reap (#49) deletes a pool's VM stuck
# creating on a capacity or quota error, so that the group's next one goes where there is room.
#
# A new build is a new manager, and the old one drains before the new one starts (#48): the ci stack never deletes a
# manager (it forgets the old one), and a new manager's gitlab-runner would remove every pool VM it did not create,
# jobs and all ("no data on pre-existing instance so removing for safety": it cannot resume another's jobs). So before
# gitlab-runner starts, this script tells each older manager to retire (its metadata runner-successor, and this
# script as its startup-script, which its watcher then runs) and waits until none is left; then it empties the pools'
# groups (runner-groups), stuck creations too (#29), and gitlab-runner starts on empty groups. A manager told to
# retire (runner-successor) starts runner-retire: gitlab-runner stops gracefully (SIGQUIT: it takes no new job and
# finishes its running ones), then the VM deletes itself.
#
# The handoff is capped (#51): while it lasts no job starts anywhere, and a repository manager's job runs for hours.
# The new manager starts gitlab-runner at most runner-handoff-limit seconds (the ci stack's manager_handoff_minutes,
# 30) after it began waiting: each older one drains until 5 minutes before then (runner-drain-until, which the new
# one sets), then cuts the jobs still running (SIGTERM: gitlab-runner aborts them, failed as runner_interrupted at
# once, and run again here: by GitLab where their retry names it, else by the looper's kicker, from their last
# checkpoint) and goes; one still there 2 minutes before then is deleted; the last 2 minutes empty the groups.
#
# MANAGER_ROOT, empty on the VM, is where tests/manager_startup_test.sh installs instead of /; RUNNER_POLL, 30 on the
# VM, is the seconds between its waits' checks.
set -Eeuo pipefail
root=${MANAGER_ROOT:-} poll=${RUNNER_POLL:-30}
md() { curl -fsS -H Metadata-Flavor:Google "http://metadata.google.internal/computeMetadata/v1/$1"; }
attr() { md "instance/attributes/$1"; }
say() { echo "manager-startup: $*"; }
die() { say "$*" >&2; exit 1; }
# access: the VM's access token (the manager's account), on stdout.
access() { md instance/service-accounts/default/token | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'; }

project=$(md project/project-id)
bucket=$(attr runner-bucket)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# get NAME SHA256 PATH: the bucket's object NAME/SHA256 installed at PATH, refused unless its SHA-256 is SHA256; nothing
# fetched if PATH already is that build (a reboot, a config pushed). installed is set when it installs one.
installed=''
get() {
  [[ $2 =~ ^[0-9a-f]{64}$ ]] || die "no SHA-256 pinned for $1"
  if [ -f "$root$3" ] && echo "$2  $root$3" | sha256sum -c --quiet - >/dev/null 2>&1; then return; fi
  curl -fsSL --retry 3 -H @<(printf 'Authorization: Bearer %s\n' "$(access)") -o "$tmp/$1" \
    "https://storage.googleapis.com/storage/v1/b/$bucket/o/$1%2F$2?alt=media" || die "cannot download $1/$2 from gs://$bucket"
  echo "$2  $tmp/$1" | sha256sum -c --quiet - || die "gs://$bucket/$1/$2 is not the pinned build"
  install -D -m 0755 "$tmp/$1" "$root$3"
  installed=1
  say "$1 installed, SHA-256 $2"
}
get gitlab-runner "$(attr runner-sha256)" /usr/bin/gitlab-runner
get fleeting-plugin-googlecloud "$(attr fleeting-plugin-sha256)" /usr/local/bin/fleeting-plugin-googlecloud

# The service as upstream's package's post-install sets it up: its user, and the unit gitlab-runner writes.
id -u gitlab-runner >/dev/null 2>&1 ||
  useradd --system --shell /bin/bash --comment 'GitLab Runner' --create-home --skel /dev/null gitlab-runner
[ -f "$root/etc/systemd/system/gitlab-runner.service" ] ||
  "$root/usr/bin/gitlab-runner" install --user=gitlab-runner --working-directory=/home/gitlab-runner

# The watcher (#46): each change of the metadata runs this script again. The guest agent's metadata server answers a
# wait_for_change when the attributes' ETag differs from the last one seen, or at its timeout with the same one.
install -d "$root/usr/local/sbin" "$root/etc/systemd/system"
cat > "$root/usr/local/sbin/runner-config-watch" <<'WATCH'
#!/bin/bash
# The runner manager's metadata watcher (tacplus-dev/cloud modules/projects/ci/files/manager-startup.sh, #46): when the
# metadata changes (the ci stack pushes a config in place), the startup script again, which rewrites config.toml.
# RUNNER_WATCH_ROUNDS, empty on the VM, is how many waits tests/manager_startup_test.sh lets it make.
set -uo pipefail
url='http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=true'
etag() { curl -fsS -o /dev/null -D - -H Metadata-Flavor:Google "$1" | tr -d '\r' | sed -n 's/^[Ee][Tt][Aa][Gg]: *//p'; }
rounds=${RUNNER_WATCH_ROUNDS:-0} n=0
until last=$(etag "$url") && [ -n "$last" ]; do sleep 10; done
while [ "$rounds" = 0 ] || [ "$n" -lt "$rounds" ]; do
  n=$((n + 1))
  now=$(etag "$url&wait_for_change=true&last_etag=$last&timeout_sec=3600") && [ -n "$now" ] || { sleep 10; continue; }
  [ "$now" = "$last" ] && continue
  last=$now
  echo "runner-config-watch: the metadata changed: the startup script again"
  systemctl restart google-startup-scripts.service || echo "runner-config-watch: the startup script failed (its journal says why)" >&2
done
WATCH
chmod 0755 "$root/usr/local/sbin/runner-config-watch"
cat > "$root/etc/systemd/system/runner-config-watch.service" <<'UNIT'
[Unit]
Description=Re-run the runner manager's startup script when its metadata changes (tacplus-dev/cloud#46)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/sbin/runner-config-watch
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

# The retirement (#48): run once a newer manager names this one's successor, not before.
cat > "$root/usr/local/sbin/runner-retire" <<'RETIRE'
#!/bin/bash
# The runner manager's retirement (tacplus-dev/cloud modules/projects/ci/files/manager-startup.sh, #48): a newer
# manager waits for this one to go before its gitlab-runner starts. gitlab-runner stops gracefully (SIGQUIT: no new
# job, the running ones finished) and never starts again here; then this VM deletes itself. The drain ends at
# runner-drain-until (#51, the successor's, re-read each check): the jobs still running then are cut (SIGTERM, a
# forced stop: gitlab-runner aborts them and fails them as runner_interrupted, run again on the successor), and a
# gitlab-runner still running RUNNER_ABORT_WAIT seconds later (60) is killed. The signals are gitlab-runner's alone
# (KillMode=mixed): its fleeting plugin, which its running jobs still reach their VMs through (the apply that made the
# successor among them), goes only once it has exited. MANAGER_ROOT and RUNNER_POLL as the startup script's.
set -uo pipefail
root=${MANAGER_ROOT:-} poll=${RUNNER_POLL:-30} abort=${RUNNER_ABORT_WAIT:-60}
md() { curl -fsS -H Metadata-Flavor:Google "http://metadata.google.internal/computeMetadata/v1/$1"; }
access() { md instance/service-accounts/default/token | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'; }
# running: gitlab-runner not stopped yet (active, or deactivating while its jobs finish).
running() { case $(systemctl is-active gitlab-runner) in inactive | failed) return 1 ;; esac; }
install -d "$root/etc/systemd/system/gitlab-runner.service.d"
printf '[Service]\nKillSignal=SIGQUIT\nKillMode=mixed\nTimeoutStopSec=infinity\n' > "$root/etc/systemd/system/gitlab-runner.service.d/drain.conf"
systemctl daemon-reload
systemctl disable gitlab-runner
echo "runner-retire: $(md instance/attributes/runner-successor) succeeds this manager: gitlab-runner finishes its jobs and stops"
systemctl stop --no-block gitlab-runner
while running; do
  end=$(md instance/attributes/runner-drain-until 2>/dev/null) || end=''
  if [[ $end =~ ^[0-9]+$ ]] && [ "$(date +%s)" -ge "$end" ]; then
    echo "runner-retire: the drain's end ($(date -u -d "@$end" +%FT%TZ)): gitlab-runner cuts its running jobs (runner_interrupted), to run again on the successor"
    systemctl kill --kill-whom=main --signal=SIGTERM gitlab-runner
    end=$(($(date +%s) + abort))
    while running && [ "$(date +%s)" -lt "$end" ]; do sleep "$poll"; done
    if running; then
      echo "runner-retire: gitlab-runner still running ${abort}s after the cut: killed"
      systemctl kill --signal=SIGKILL gitlab-runner
    fi
    break
  fi
  sleep "$poll"
done
name=$(md instance/name) zone=$(md instance/zone)
echo "runner-retire: gitlab-runner stopped, no job left: deleting $name"
until curl -fsS -X DELETE -H @<(printf 'Authorization: Bearer %s\n' "$(access)") -o /dev/null \
    "https://compute.googleapis.com/compute/v1/projects/$(md project/project-id)/zones/${zone##*/}/instances/$name"; do
  sleep "$poll"
done
RETIRE
chmod 0755 "$root/usr/local/sbin/runner-retire"
cat > "$root/etc/systemd/system/runner-retire.service" <<'UNIT'
[Unit]
Description=Drain this runner manager for its successor, then delete it (tacplus-dev/cloud#48)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/runner-retire
TimeoutStartSec=infinity
UNIT

# The reaper (#49): a VM the pools' groups cannot make, for lack of capacity or quota, stays CREATING, retried by the
# group forever, and the autoscaler counts it as coming: every job waiting on it waits with it (spot t2a in
# us-central1-b, 2026-11-12, #29). Each minute it lists the groups the metadata names (runner-groups, each a group's
# path in the Compute API: config, re-read each round), and deletes a VM creating on a capacity or quota error for
# RUNNER_REAP_AFTER seconds (5 minutes) or more; the autoscaler then asks for another, which a group spread over the
# region's zones makes where there is room. It deletes nothing else.
cat > "$root/usr/local/sbin/runner-reap" <<'REAP'
#!/bin/bash
# The runner manager's reaper (tacplus-dev/cloud modules/projects/ci/files/manager-startup.sh, #49): deletes a pool's
# VM stuck creating on a capacity or quota error, rather than letting its group retry it forever.
# RUNNER_REAP_ROUNDS, empty on the VM, is how many rounds tests/manager_startup_test.sh lets it make, RUNNER_REAP_SLEEP
# its wait between them, and RUNNER_REAP_STATE where it keeps when it first saw each VM stuck.
set -uo pipefail
md() { curl -fsS -H Metadata-Flavor:Google "http://metadata.google.internal/computeMetadata/v1/$1"; }
access() { md instance/service-accounts/default/token | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'; }
api() { curl -fsS -X POST -H @<(printf 'Authorization: Bearer %s\n' "$token") -H 'Content-Type: application/json' --data "${2:-}" "https://compute.googleapis.com/compute/v1/projects/$project/$1"; }
after=${RUNNER_REAP_AFTER:-300} state=${RUNNER_REAP_STATE:-/var/lib/runner-reap} rounds=${RUNNER_REAP_ROUNDS:-0} n=0
# The managed VMs (stdin) creating on a capacity or quota error for AFTER seconds or more, one per line; when each
# was first seen stuck is kept in STATE, the group's file.
stuck='
import json, re, sys
path, after, now = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    seen = json.load(open(path))
except (OSError, ValueError):
    seen = {}
capacity = re.compile(r"RESOURCE_POOL_EXHAUSTED|QUOTA_EXCEEDED|STOCKOUT")
stuck = {}
for m in json.load(sys.stdin).get("managedInstances", []):
    codes = [e.get("code", "") for e in m.get("lastAttempt", {}).get("errors", {}).get("errors", [])]
    if m.get("currentAction") == "CREATING" and m.get("instance") and any(capacity.search(c) for c in codes):
        stuck[m["instance"]] = seen.get(m["instance"], now)
json.dump(stuck, open(path, "w"))
for vm, since in sorted(stuck.items()):
    if now - since >= after:
        print(vm)
'
mkdir -p "$state"
while [ "$rounds" = 0 ] || [ "$n" -lt "$rounds" ]; do
  n=$((n + 1))
  [ "$n" = 1 ] || sleep "${RUNNER_REAP_SLEEP:-60}"
  project=$(md project/project-id) && groups=$(md instance/attributes/runner-groups) && token=$(access) || continue
  for group in $groups; do
    list=$(api "$group/listManagedInstances") || { echo "runner-reap: cannot list $group" >&2; continue; }
    mapfile -t vms < <(python3 -c "$stuck" "$state/${group//\//_}" "$after" "$(date +%s)" <<<"$list")
    [ "${#vms[@]}" -gt 0 ] || continue
    echo "runner-reap: deleting from $group, stuck creating on a capacity or quota error: ${vms[*]}"
    body=$(python3 -c 'import json,sys; print(json.dumps({"instances": sys.argv[1:], "skipInstancesOnValidationError": True}))' "${vms[@]}")
    api "$group/deleteInstances" "$body" >/dev/null || echo "runner-reap: cannot delete from $group" >&2
  done
done
REAP
chmod 0755 "$root/usr/local/sbin/runner-reap"
cat > "$root/etc/systemd/system/runner-reap.service" <<'UNIT'
[Unit]
Description=Delete a runner pool's VM stuck creating on a capacity or quota error (tacplus-dev/cloud#49)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/sbin/runner-reap
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now runner-config-watch.service
systemctl enable --now runner-reap.service

if successor=$(attr runner-successor 2>/dev/null) && [ -n "$successor" ]; then
  # Restarted, not started: one already draining (a newer successor, or one from before #51, which had no end) takes
  # this script's, and the end it is given now.
  systemctl restart --no-block runner-retire.service
  say "retiring for $successor: gitlab-runner finishes its jobs and stops, or has them cut at the drain's end, then this VM deletes itself"
  exit 0
fi

# token POOL: the pool's runner token on stdout, or nothing yet.
token() {
  curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$(access)") \
      "https://secretmanager.googleapis.com/v1/projects/$project/secrets/runner-token-$1/versions/latest:access" 2>/dev/null |
    python3 -c 'import base64,json,sys; print(base64.b64decode(json.load(sys.stdin)["payload"]["data"]).decode())'
}

( umask 077; attr runner-config > "$tmp/config.toml" )
for pool in $(attr runner-pools); do
  until t=$(token "$pool") && [[ $t =~ ^glrt-[A-Za-z0-9_.-]+$ ]]; do
    say "no runner token for the pool $pool yet (runner-token-$pool: the gitlab stack writes it); waiting"
    sleep 60
  done
  python3 - "$tmp/config.toml" "@TOKEN:$pool@" "$t" <<'PY'
import sys
path, mark, value = sys.argv[1:]
text = open(path).read()
assert text.count(mark) == 1, mark
open(path, "w").write(text.replace(mark, value))
PY
done
install -d -m 0700 "$root/etc/gitlab-runner"
# Whole or not at all: gitlab-runner reloads config.toml when it changes, and must never read half of one.
install -m 0600 "$tmp/config.toml" "$root/etc/gitlab-runner/.config.toml.new"
mv -f "$root/etc/gitlab-runner/.config.toml.new" "$root/etc/gitlab-runner/config.toml"

# compute METHOD PATH [BODY]: Compute Engine's API on this project, PATH under it (zones/<zone>/..., a group's path), with
# the VM's token; its answer on stdout. A POST has a body, BODY's file or an empty one (Google's front end refuses one
# without a length).
zone=$(md instance/zone) && zone=zones/${zone##*/}
compute() {
  local data=()
  [ "$1" = POST ] && data=(--data-binary "@${3:-/dev/null}")
  curl -fsS -X "$1" -H @<(printf 'Authorization: Bearer %s\n' "$(access)") -H 'Content-Type: application/json' \
    "${data[@]}" "https://compute.googleapis.com/compute/v1/projects/$project/$2"
}
# older: the managers made before this one, by name, one a line (the pools' VMs and this one are not): runner-manager-*,
# and runner-manager, its name before #46.
older() {
  compute GET "$zone/"'instances?filter=name%20eq%20%22runner-manager(-.*)%3F%22' | python3 -c '
import datetime, json, re, sys
me, at = sys.argv[1], datetime.datetime.fromisoformat
items = json.load(sys.stdin).get("items", [])
mine = [at(i["creationTimestamp"]) for i in items if i["name"] == me]
if len(mine) != 1:
    sys.exit("this manager, %s, is not among the instances" % me)
for i in items:
    if re.fullmatch("runner-manager(-.*)?", i["name"]) and i["name"] != me and at(i["creationTimestamp"]) < mine[0]:
        print(i["name"])
' "$1"
}
# retire NAME ME END: the older manager NAME told to retire, its successor ME, its drain to end at END (seconds since
# the epoch), with this script as its startup-script, which its watcher runs on the change (a manager older than #48
# has no runner-retire of its own, one older than #51 no drain's end); nothing if it already was.
retire() {
  compute GET "$zone/instances/$1" > "$tmp/old.json" && attr startup-script > "$tmp/script" &&
    python3 - "$tmp/old.json" "$tmp/script" "$2" "$3" > "$tmp/metadata.json" <<'PY' || return 1
import json, sys
inst, script, me, end = json.load(open(sys.argv[1])), open(sys.argv[2]).read(), sys.argv[3], sys.argv[4]
md = inst.get("metadata", {})
items = {i["key"]: i.get("value", "") for i in md.get("items", [])}
told = {"runner-successor": me, "startup-script": script, "runner-drain-until": end}
if all(items.get(k) == v for k, v in told.items()):
    sys.exit(0)
items.update(told)
json.dump({"fingerprint": md.get("fingerprint", ""), "items": [{"key": k, "value": v} for k, v in sorted(items.items())]}, sys.stdout)
PY
  [ -s "$tmp/metadata.json" ] || return 0
  compute POST "$zone/instances/$1/setMetadata" "$tmp/metadata.json" > /dev/null && say "told $1 to retire: $2 succeeds it"
}
# managed GROUP: how many instances the group whose path is GROUP (zonal or regional) has, whatever their state (creating and deleting ones too).
managed() {
  compute POST "$1/listManagedInstances" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("managedInstances", [])))'
}
# handoff: gitlab-runner starts alone on empty groups. The older managers first retire (each drains its jobs, then
# deletes itself): until then they hold the groups' VMs, and their jobs, and this manager takes no job. Not for longer
# than the handoff's limit (#51, runner-handoff-limit seconds from the handoff's start, which a re-run of this script
# keeps): each drains until 5 minutes before it, then cuts its jobs and goes; one still there 2 minutes before it (its
# watcher or runner-retire not running) is deleted, its jobs with it. Then the groups to zero, until each has no
# instance at all: a creation stuck on an error of the old fleet's time (QUOTA_EXCEEDED, retried by the group about
# every 90 minutes, #29) goes with them, and the VMs gitlab-runner then asks for are created at once.
handoff() {
  local me olds o g n limit since end gone state=$root/var/lib/runner-handoff
  me=$(md instance/name)
  limit=$(attr runner-handoff-limit 2>/dev/null) && [[ $limit =~ ^[0-9]+$ ]] || limit=1800
  install -d "$state"
  [ -s "$state/since" ] || date +%s > "$state/since"
  since=$(cat "$state/since")
  end=$((since + limit - 300)) gone=$((since + limit - 120))
  while :; do
    olds=$(older "$me") || { say "cannot list the managers yet"; sleep "$poll"; continue; }
    [ -z "$olds" ] && break
    for o in $olds; do
      if [ "$(date +%s)" -lt "$gone" ]; then
        retire "$o" "$me" "$end" || say "cannot tell $o to retire yet"
      elif compute DELETE "$zone/instances/$o" > /dev/null; then
        say "deleted $o: still there past its drain's end, 2 minutes before the handoff's limit (its jobs, if any, lost)"
      else
        say "cannot delete $o yet"
      fi
    done
    say "waiting for the older managers to finish their jobs, or cut them at $(date -u -d "@$end" +%FT%TZ), and go: ${olds//$'\n'/ }"
    sleep "$poll"
  done
  for g in $(attr runner-groups); do
    until compute POST "$g/resize?size=0" > /dev/null; do say "cannot resize $g to 0 yet"; sleep "$poll"; done
    until n=$(managed "$g") && [ "$n" = 0 ]; do say "the group $g still has ${n:-some} instances: waiting until it has none"; sleep "$poll"; done
  done
  rm -f "$state/since"
  say "no older manager left, the groups empty: $(attr runner-groups)"
}

if [ -n "$installed" ] || ! systemctl is-active --quiet gitlab-runner; then
  handoff
  systemctl restart gitlab-runner
else
  say "config.toml rewritten: gitlab-runner reloads it, its running jobs untouched"
fi
say "gitlab-runner $("$root/usr/bin/gitlab-runner" --version | sed -n 's/^Version: *//p') running the pools: $(attr runner-pools)"
