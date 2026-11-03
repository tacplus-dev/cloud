#!/bin/bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The startup-script of the runner VMs' instance templates (looper#43): the
# loopers' workers (runner-arm64-tacplus), the build runner's
# (runner-arm64-build) and fleet-seatrials' deploy runner's. Kept here
# (github.com/tacplus-dev/looper runner/startup.sh) and set as the template's
# metadata by `runner-image template`. README: Infrastructure.
#
# An off-the-shelf Ubuntu arm64 VM with Docker; everything else a job needs
# comes from its container image. The template's image is the family
# runner-arm64-docker (`runner-image build`), Docker already installed and
# enabled, so this only checks what the image has and waits for Docker. On a
# stock Ubuntu image it installs Docker first, as the templates up to
# runner-arm64-t2a8-v5 did at every boot.
#
# The runner manager connects over SSH as `fleeting` as soon as sshd answers
# (the guest agent creates that user from the ssh-keys metadata), so group
# membership added later never reaches that session: Docker's socket is
# instead created with group `fleeting` by a docker.socket drop-in.
#
# Its last step, once Docker answers, is /var/run/runner-ready (on tmpfs: gone
# at the next boot, never in an image). The autoscaler's instance_ready_command
# waits for it, so no job is placed on a VM whose Docker is not up or is about
# to restart (the first job of a fresh VM failed when this script restarted
# Docker under it, 2026-10-31). The outcome is also the guest attribute
# runner/ready ("<seconds since boot> baked|installed", or "failed"), which
# `runner-image build` reads when it boots a new image.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
READY=/var/run/runner-ready
DROPIN=/etc/systemd/system/docker.socket.d/override.conf

# A guest attribute of this VM, best effort: a template without
# enable-guest-attributes refuses it.
attribute() { # key value
  curl -fsS -m 5 -X PUT -H Metadata-Flavor:Google --data "$2" \
    "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/$1" >/dev/null 2>&1 || true
}
trap 'attribute runner/ready failed' ERR

rm -f "$READY"
id fleeting >/dev/null 2>&1 || useradd -m -s /bin/bash fleeting

restart=0 how=baked
want="$(printf '[Socket]\nSocketGroup=fleeting')"
if [[ ! -f "$DROPIN" || "$(<"$DROPIN")" != "$want" ]]; then
  install -d -m 0755 "${DROPIN%/*}"
  printf '%s\n' "$want" > "$DROPIN"
  restart=1
fi
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null
  restart=1 how=installed
fi
systemctl daemon-reload
systemctl enable docker.socket docker >/dev/null 2>&1
if ((restart)); then
  systemctl restart docker.socket docker
else
  systemctl start docker.socket docker
fi

# Docker answers, or this VM is never ready (the ready command gives up and the
# autoscaler removes it).
for ((i = 0; ; i++)); do
  systemctl is-active --quiet docker && docker info >/dev/null 2>&1 && break
  ((i < 60)) || { echo "runner: docker is not active after 120 seconds" >&2; false; }
  sleep 2
done
touch "$READY"
attribute runner/ready "$(cut -d. -f1 /proc/uptime) $how"
echo "runner: ready ($how)"
