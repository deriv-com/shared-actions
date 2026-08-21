#!/usr/bin/env bash
# tests/trivy-sca-autofix-contract.sh
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

PROMPT="$ROOT/.github/actions/trivy_sca_autofix_prompt/prompt.md"
ACTION="$ROOT/.github/actions/trivy_sca_autofix_prompt/action.yml"
check '[[ -f "$PROMPT" ]]' "prompt.md exists"
check '[[ -f "$ACTION" ]]' "trivy_sca_autofix_prompt/action.yml exists"
if [[ -f "$PROMPT" ]]; then
  check 'grep -q "FixedVersion" "$PROMPT"' "prompt mentions FixedVersion"
  check 'grep -q "/tmp/autofix_result.md" "$PROMPT"' "prompt names result file"
  check 'grep -q "package.json" "$PROMPT"' "prompt names package.json"
  check 'grep -q "do not invent" "$PROMPT"' "prompt forbids invented versions"
  check 'grep -q ".trivyignore" "$PROMPT"' "prompt forbids trivyignore"
  check 'grep -q "DATA" "$PROMPT"' "prompt frames inputs as data"
fi
if [[ -f "$ACTION" ]]; then
  check '! grep -nE "timeout-minutes:" "$ACTION"' "prompt action has no timeout-minutes"
  check '! grep -nE "secrets\\." "$ACTION"' "prompt action does not mention secrets."
  check '! grep -nE "\\$\\{\\{[[:space:]]*\\}\\}" "$ACTION"' "prompt action has no empty expression pair"
  check 'grep -q "github.action_path" "$ACTION"' "prompt action uses github.action_path"
  check 'grep -q "/tmp/fix_prompt.md" "$ACTION"' "prompt action copies to /tmp/fix_prompt.md"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "contract checks failed"
  exit 1
fi
echo "all contract checks passed"
