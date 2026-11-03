# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The stack org: its state in the bootstrap project's bucket, under the prefix org. OpenTofu and every provider are
# pinned to one version; .terraform.lock.hcl pins each provider's hashes for linux and darwin, arm64 and amd64
# (ci/lock.sh writes it).

terraform {
  required_version = "= 1.13.2"

  backend "gcs" {
    bucket = "tacplus-bootstrap-tofu-state"
    prefix = "org"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.9.0"
    }
  }
}
