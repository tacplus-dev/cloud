# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# tflint (ci/lint.sh): the bundled terraform rules, recommended preset, and the google ruleset at the version
# ci/tools.sh installs (by checksum, into bin/tflint.d: `tflint --init` is never run).

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "google" {
  enabled = true
  version = "0.41.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
