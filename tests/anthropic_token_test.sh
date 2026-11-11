#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/anthropic-token.sh, the anthropic provider's identity_token_command (#34): each call prints one of the job's
# ID tokens for Anthropic that no call printed before, in order, and only it; none is ever printed twice, even by
# calls at once; when all are presented it fails, saying so, and prints nothing; without its directory it fails.
# Needs bash.
#
#   tests/anthropic_token_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
token=$here/ci/anthropic-token.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
export ANTHROPIC_ID_TOKEN_1=tok-one ANTHROPIC_ID_TOKEN_2=tok-two ANTHROPIC_ID_TOKEN_3=tok-three

export ANTHROPIC_ID_TOKENS_DIR=$work/a && mkdir "$ANTHROPIC_ID_TOKENS_DIR"
got=$("$token"; "$token"; "$token")
[ "$got" = "$(printf 'tok-one\ntok-two\ntok-three')" ] && ok "each call: the next token not presented yet, and only it" || fail "three calls: [$got]"
if out=$("$token" 2>"$work/err"); then fail "a fourth call printed [$out]"
else [ -z "$out" ] && grep -q 'were all presented already' "$work/err" && ok "once all are presented: fails, saying so, printing nothing" ||
  fail "the fourth call: [$out] $(cat "$work/err")"; fi

export ANTHROPIC_ID_TOKENS_DIR=$work/b && mkdir "$ANTHROPIC_ID_TOKENS_DIR"
for i in 1 2 3 4 5 6; do "$token" > "$work/at-once.$i" 2>/dev/null & done
wait
got=$(cat "$work"/at-once.* | sort)
[ "$got" = "$(printf 'tok-one\ntok-three\ntok-two')" ] && ok "six calls at once: the three tokens, each once" || fail "six calls at once: [$got]"

ANTHROPIC_ID_TOKENS_DIR=$work/none "$token" > /dev/null 2>&1 && fail "a call without its directory succeeded" || ok "without its directory: fails"
(unset ANTHROPIC_ID_TOKENS_DIR; "$token" > /dev/null 2>&1) && fail "a call without ANTHROPIC_ID_TOKENS_DIR succeeded" || ok "without ANTHROPIC_ID_TOKENS_DIR: fails"
exit "$failed"
