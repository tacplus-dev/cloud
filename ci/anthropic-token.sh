#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The anthropic provider's identity_token_command (stacks/anthropic): prints one of the job's GitLab ID tokens for
# Anthropic (id_tokens ANTHROPIC_ID_TOKEN_1, _2, ...) that no exchange of this job has presented yet, the first one
# left. Anthropic accepts each token's jti once, and the provider exchanges again for each provider it starts and
# before a token expires, so every exchange gets a token of its own. Each is claimed by a directory made in
# ANTHROPIC_ID_TOKENS_DIR (mkdir: one claim wins, even at once), so none is printed twice; when none is left it
# fails, saying so, and the exchange with it. It prints only the token, never anything else on stdout.
#
#   ci/anthropic-token.sh     # ANTHROPIC_ID_TOKENS_DIR (ci/lib.sh's ci_anthropic makes it), ANTHROPIC_ID_TOKEN_<n>
set -euo pipefail
dir=${ANTHROPIC_ID_TOKENS_DIR:?anthropic-token.sh: ANTHROPIC_ID_TOKENS_DIR is not set (ci/lib.sh: ci_anthropic)}
[ -d "$dir" ] || { echo "anthropic-token.sh: no directory $dir" >&2; exit 1; }
i=1
while v=ANTHROPIC_ID_TOKEN_$i && [ -n "${!v:-}" ]; do
  if mkdir "$dir/$i" 2>/dev/null; then
    printf '%s\n' "${!v}"
    exit 0
  fi
  i=$((i + 1))
done
echo "anthropic-token.sh: the job's $((i - 1)) ID token(s) for Anthropic (ANTHROPIC_ID_TOKEN_<n>) were all presented already: Anthropic accepts each once (ci/gitlab-project.gitlab-ci.yml, .anthropic)" >&2
exit 1
