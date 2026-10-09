#!/usr/bin/env bash
# tests/qa-checklist-contract.sh
#
# Guards the caller-facing contract of .github/workflows/qa-checklist.yml.
# Callers live in other repositories and consume it at @master, so a rename or
# a dropped output ships org-wide with no local signal.
#
# It pins the input names callers pass, the default model, and the three places
# the requested model is reported: the checklist comment footer, the run
# summary table and the workflow_completed event payload.
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

WF="$ROOT/.github/workflows/qa-checklist.yml"
DOC="$ROOT/.github/workflows/QA_CHECKLIST_README.md"
DEFAULT_MODEL="claude-sonnet-5-5"

check '[[ -f "$WF" ]]' "qa-checklist.yml exists"
check 'grep -q "^  workflow_call:" "$WF"' "declared as workflow_call"

# --- inputs and secret callers pass by name -------------------------------
for input in claude_model anthropic_base_url; do
  check "grep -q '^      ${input}:' \"\$WF\"" "input '${input}' is declared"
done
check 'grep -q "^      ANTHROPIC_AUTH_TOKEN:" "$WF"' "secret 'ANTHROPIC_AUTH_TOKEN' is declared"

# --- default model: input default and env fallback agree -------------------
check "grep -qF 'default: \"${DEFAULT_MODEL}\"' \"\$WF\"" "claude_model defaults to ${DEFAULT_MODEL}"
check "grep -qF \"CLAUDE_MODEL: \\\${{ inputs.claude_model || '${DEFAULT_MODEL}' }}\" \"\$WF\"" \
  "CLAUDE_MODEL env falls back to ${DEFAULT_MODEL}"
check "grep -qF '| \`claude_model\` | no | \`${DEFAULT_MODEL}\` |' \"\$DOC\"" \
  "README documents the same default"

# --- the requested model is reported in all three places -------------------
check 'grep -qF "· Model: \`\${{ env.CLAUDE_MODEL }}\`" "$WF"' \
  "checklist footer template names the model"
check 'grep -qF "echo \"| Model | \$CLAUDE_MODEL |\" >> \$GITHUB_STEP_SUMMARY" "$WF"' \
  "run summary table has a Model row"
check 'grep -qF -- "--arg model \"\$CLAUDE_MODEL\"" "$WF" && grep -qE "^ +model: \\\$model,$" "$WF"' \
  "workflow_completed payload carries model"

# Shell steps read the model from the env, never as an interpolated expression.
check '! grep -E "^ +(echo|--arg).*\\\$\{\{ *env\.CLAUDE_MODEL" "$WF" >/dev/null' \
  "shell steps do not interpolate env.CLAUDE_MODEL into scripts"

exit $fail
