# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The stack anthropic: its state in the bootstrap project's bucket, under the prefix anthropic. OpenTofu and every
# provider are pinned to one version; .terraform.lock.hcl pins each provider's hashes for linux and darwin, arm64 and
# amd64 (ci/lock.sh writes it): ippontech/anthropic's are our builds' (ci/anthropic-provider.sh).

terraform {
  required_version = "= 1.13.2"

  backend "gcs" {
    bucket = "tacplus-bootstrap-tofu-state"
    prefix = "anthropic"
  }

  required_providers {
    anthropic = {
      source  = "ippontech/anthropic"
      version = "1.92.0"
    }
  }
}
