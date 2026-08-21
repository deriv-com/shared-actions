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

KIMI="$ROOT/.github/actions/ai_sca_engine_kimi/action.yml"
check '[[ -f "$KIMI" ]]' "ai_sca_engine_kimi/action.yml exists"
if [[ -f "$KIMI" ]]; then
  check '! grep -nE "timeout-minutes:" "$KIMI"' "kimi SCA has no timeout-minutes"
  check '! grep -nE "secrets\\." "$KIMI"' "kimi SCA does not mention secrets."
  check '! grep -nE "\\$\\{\\{[[:space:]]*\\}\\}" "$KIMI"' "kimi SCA has no empty expression pair"
  check '! grep -nE "github\\.token" "$KIMI"' "kimi SCA does not use github.token"
  check 'grep -q "decision = \"deny\"" "$KIMI" || grep -q "pattern = \"Bash\"" "$KIMI"' "kimi SCA denies Bash"
  check 'grep -q "autofix_result.md" "$KIMI"' "kimi SCA writes autofix_result.md"
  check 'grep -q "Kimi SCA engine" "$KIMI"' "kimi SCA failures are engine-named"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "contract checks failed"
  exit 1
fi
echo "all contract checks passed"
