#!/bin/bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The startup-script of every runner pool's VMs (modules/projects/ci): Docker from the Ubuntu archive snapshot the
# template names (metadata apt-snapshot), so every VM of a template gets the same packages; its socket owned by the
# group `runner`, the user the manager connects as; then the readiness marker the autoscaler's
# instance_ready_command waits for (/var/run/runner-ready, on tmpfs: gone at the next boot).
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
READY=/var/run/runner-ready
DROPIN=/etc/systemd/system/docker.socket.d/override.conf
rm -f "$READY"

snapshot=$(curl -fsS -H Metadata-Flavor:Google \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/apt-snapshot)
[[ $snapshot =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "worker-startup: apt-snapshot [$snapshot] is not a snapshot ID" >&2; exit 1; }

id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
install -d -m 0755 "${DROPIN%/*}"
printf '[Socket]\nSocketGroup=runner\n' > "$DROPIN"
if ! command -v docker >/dev/null; then
  apt-get update -qq --snapshot "$snapshot"
  apt-get install -y -qq --snapshot "$snapshot" docker.io >/dev/null
fi
systemctl daemon-reload
systemctl restart docker.socket docker.service
for _ in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
docker info >/dev/null
touch "$READY"
echo "worker-startup: ready (Docker from the Ubuntu snapshot $snapshot)"
