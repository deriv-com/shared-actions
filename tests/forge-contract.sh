#!/usr/bin/env bash
# tests/forge-contract.sh
#
# Guards the caller-facing contract of .github/workflows/forge.yml. Callers live
# in other repositories, so a rename here breaks them at run time with no local
# signal — actionlint validates syntax but knows nothing about which input names
# downstream repos depend on.
#
# It also pins the two invariants the workflow's own comments promise but that
# nothing else enforces: the engine ref stays an immutable SHA, and no
# caller-relative `uses: ./` creeps in (such a path resolves against the CALLER,
# so it would work in one repo and break in every other).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
check() {
  if ! eval "$1"; then
    echo "FAIL: $2"
    fail=1
  else
    echo "PASS: $2"
  fi
}

WF="$ROOT/.github/workflows/forge.yml"

check '[[ -f "$WF" ]]' "forge.yml exists"

# --- it must stay a reusable workflow -------------------------------------
check 'grep -q "^  workflow_call:" "$WF"' "declared as workflow_call"
check '! grep -qE "^  (issues|pull_request|push|schedule):" "$WF"' \
  "no direct triggers — callers own those"

# --- inputs callers pass by name ------------------------------------------
for input in issue_number slack_channel slack_thread_ts requested_by \
             node_version install_command model runner_group engine_ref \
             timeout_minutes; do
  check "grep -q '^      ${input}:' \"\$WF\"" "input '${input}' is declared"
done

check 'awk "/^      issue_number:/{f=1} f && /required:/{print; exit}" "$WF" | grep -q "required: true"' \
  "issue_number stays required"

# --- secrets callers must forward -----------------------------------------
for secret in CLIENT_ID_GHAPP_WRITE PRIVATE_KEY_GHAPP_WRITE \
              CLIENT_ID_GHAPP PRIVATE_KEY_GHAPP FORGE_API_KEY; do
  check "grep -q '^      ${secret}:' \"\$WF\"" "secret '${secret}' is declared"
  check "awk '/^      ${secret}:/{f=1} f && /required:/{print; exit}' \"\$WF\" | grep -q 'required: true'" \
    "secret '${secret}' stays required"
done

# Optional by design: a missing Slack token degrades to a warning, and the
# gateway URL falls back to the deriv default.
for secret in FORGE_SLACK_BOT_TOKEN LITELLM_API_URL; do
  check "grep -q '^      ${secret}:' \"\$WF\"" "secret '${secret}' is declared"
  check "awk '/^      ${secret}:/{f=1} f && /required:/{print; exit}' \"\$WF\" | grep -q 'required: false'" \
    "secret '${secret}' stays optional"
done

# --- portability ----------------------------------------------------------
# A relative `uses:` inside a reusable workflow resolves against the caller, so
# any caller-local composite action makes this workflow non-portable.
# Matches both `uses: ./` and the list-item form `- uses: ./`. The leading `#`
# of a comment cannot match, so the header's prose about this rule is safe.
check '! grep -qE "^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*\./" "$WF"' \
  "no caller-relative 'uses: ./' — toolchain stays parameterised"

check 'grep -q "install_command" "$WF"' \
  "dependency install is still an input, not a hardcoded action"

# --- supply chain ---------------------------------------------------------
# The engine runs with a write token in scope, so tracking a branch would let
# any push to spec-to-pr execute in every caller repo.
check 'awk "/^      engine_ref:/{f=1} f && /default:/{print; exit}" "$WF" | grep -qE "\"[0-9a-f]{40}\""' \
  "engine_ref default is a full 40-char SHA, not a branch"

# Every third-party action pinned by SHA (the repo-wide rule this workflow must
# not be an exception to).
check '! grep -nE "^\s+uses: [a-zA-Z0-9_.-]+/[^@]+@(v?[0-9]+(\.[0-9]+)*|main|master)\s*$" "$WF"' \
  "all actions pinned by commit SHA"

# --- guards the workflow's own comments claim ------------------------------
check 'grep -q "gh label create" "$WF"' \
  "labels are created idempotently so a new caller repo needs no manual setup"

check 'grep -qE "ISSUE_NUMBER\" =~ \^\[0-9\]\+\\$" "$WF"' \
  "issue_number is validated as numeric before any API call"

check 'grep -q "s/sk-\[A-Za-z0-9_-\]{20,}/\*\*\*/g" "$WF"' \
  "failure-log scrub covers gateway keys (sk-), not only sk-ant-"

check 'grep -q "xox\[abposr\]-" "$WF"' \
  "failure-log scrub covers Slack tokens"

check 'grep -q -- "--max-time" "$WF"' \
  "the Slack call is time-bounded"

if [[ "$fail" -ne 0 ]]; then
  echo "❌ forge.yml contract test failed"
  exit 1
fi
echo "✅ forge.yml contract test passed"
