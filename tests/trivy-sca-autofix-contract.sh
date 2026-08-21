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

ANTH="$ROOT/.github/actions/ai_sca_engine_anthropic/action.yml"
check '[[ -f "$ANTH" ]]' "ai_sca_engine_anthropic/action.yml exists"
if [[ -f "$ANTH" ]]; then
  check '! grep -nE "timeout-minutes:" "$ANTH"' "anthropic SCA has no timeout-minutes"
  check '! grep -nE "secrets\\." "$ANTH"' "anthropic SCA does not mention secrets."
  check '! grep -nE "\\$\\{\\{[[:space:]]*\\}\\}" "$ANTH"' "anthropic SCA has no empty expression pair"
  check '! grep -nE "github_token:" "$ANTH"' "anthropic SCA does not pass github_token"
  check 'grep -q "disallowedTools" "$ANTH"' "anthropic SCA sets disallowedTools"
  check 'grep -q "Bash" "$ANTH"' "anthropic SCA mentions Bash in denylist"
  check 'grep -q "Anthropic SCA engine" "$ANTH"' "anthropic SCA failures are engine-named"
  check 'grep -q "fefa07e9c665b7320f08c3b525980457f22f58aa" "$ANTH"' "anthropic SCA pins the same claude-code-action SHA as review"
fi

GROK="$ROOT/.github/actions/ai_sca_engine_grok/action.yml"
check '[[ -f "$GROK" ]]' "ai_sca_engine_grok/action.yml exists"
if [[ -f "$GROK" ]]; then
  check '! grep -nE "timeout-minutes:" "$GROK"' "grok SCA has no timeout-minutes"
  check '! grep -nE "secrets\\." "$GROK"' "grok SCA does not mention secrets."
  check '! grep -nE "\\$\\{\\{[[:space:]]*\\}\\}" "$GROK"' "grok SCA has no empty expression pair"
  check '! grep -nE "github\\.token" "$GROK"' "grok SCA does not use github.token"
  check 'grep -q "workspace-write" "$GROK"' "grok SCA uses workspace-write sandbox"
  check '! grep -q "GROK_SANDBOX: read-only" "$GROK"' "grok SCA does not use read-only sandbox"
  check 'grep -q "Grok SCA engine" "$GROK"' "grok SCA failures are engine-named"
  check 'grep -q "deny Bash" "$GROK" || grep -q "--deny Bash" "$GROK"' "grok SCA denies Bash"
fi

WF="$ROOT/.github/workflows/trivy-sca-autofix.yml"
check '[[ -f "$WF" ]]' "trivy-sca-autofix.yml exists"
if [[ -f "$WF" ]]; then
  check 'grep -q "workflow_call:" "$WF"' "workflow is reusable"
  check 'grep -q "engine:" "$WF"' "workflow has engine input"
  check 'python3 -c "import pathlib,sys; t=pathlib.Path(\"$WF\").read_text(); sys.exit(0 if all(x in t for x in [\"kimi)\", \"anthropic)\", \"grok)\"]) else 1)"' "resolve case has kimi, anthropic, grok"
  check 'grep -q "ai_sca_engine_kimi@master" "$WF"' "kimi dispatch pinned at master"
  check 'grep -q "ai_sca_engine_anthropic@master" "$WF"' "anthropic dispatch pinned at master"
  check 'grep -q "ai_sca_engine_grok@master" "$WF"' "grok dispatch pinned at master"
  check 'grep -q "trivy_sca_autofix_prompt@master" "$WF"' "prompt composite pinned at master"
  check 'grep -q "send_slack_notification@master" "$WF"' "slack action pinned at master"
  check 'grep -q "ed142fd0673e97e23eac54620cfb913e5ce36c25" "$WF"' "trivy-action SHA pinned"
  check 'grep -q "d23441a48e516b6c34aea4fa41551a30e30af803" "$WF"' "checkout SHA pinned"
  check 'grep -q "chore/trivy-sca-autofix" "$WF"' "singleton branch name"
  check 'grep -q "ignore-scripts" "$WF"' "install uses ignore-scripts"
  check 'grep -q "AUTOFIX_GITHUB_TOKEN" "$WF"' "PAT secret declared"
  check '! grep -nE "ref:.*pull_request.head" "$WF"' "does not checkout PR head"
  check 'grep -q "GITHUB_TOKEN:" "$WF"' "engine dispatch mentions GITHUB_TOKEN (cleared to empty)"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "contract checks failed"
  exit 1
fi
echo "all contract checks passed"
