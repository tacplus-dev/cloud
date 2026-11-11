# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by every script that runs tofu: TF_CLI_CONFIG_FILE, OpenTofu's CLI configuration, which installs
# gitlabhq/gitlab, hashicorp/kubernetes, hashicorp/google and ippontech/anthropic from bin/providers (our builds,
# ci/gitlab-provider.sh, ci/kubernetes-provider.sh, ci/google-provider.sh and ci/anthropic-provider.sh, which
# ci/tools.sh puts there) and never from a registry, and every other provider from its registry as usual; either way
# only by the lock file's hashes. It is
# written into bin/ for this checkout, as OpenTofu reads a mirror's relative path from the working directory.
tofurc_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$tofurc_root/bin"
cat > "$tofurc_root/bin/tofurc.$$" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "$tofurc_root/bin/providers"
    include = ["registry.opentofu.org/gitlabhq/gitlab", "registry.opentofu.org/hashicorp/kubernetes", "registry.opentofu.org/hashicorp/google", "registry.opentofu.org/ippontech/anthropic"]
  }
  direct {
    exclude = ["registry.opentofu.org/gitlabhq/gitlab", "registry.opentofu.org/hashicorp/kubernetes", "registry.opentofu.org/hashicorp/google", "registry.opentofu.org/ippontech/anthropic"]
  }
}
EOF
mv "$tofurc_root/bin/tofurc.$$" "$tofurc_root/bin/tofurc"
export TF_CLI_CONFIG_FILE=$tofurc_root/bin/tofurc
