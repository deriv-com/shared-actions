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
  check 'grep -q "show_full_output: false" "$ANTH"' "anthropic SCA disables show_full_output"
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
  check 'grep -qF '\''Write(${OUT_DIR}/*)'\'' "$GROK"' "grok SCA Write allow matches output_path dir"
  check 'grep -qF '\''Edit(${OUT_DIR}/*)'\'' "$GROK"' "grok SCA Edit allow matches output_path dir"
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
  check 'grep -q "cache-dir: /tmp/trivy-cache" "$WF"' "trivy cache-dir is /tmp/trivy-cache"
  check 'grep -c "cache-dir: /tmp/trivy-cache" "$WF" | grep -qx 2' "both trivy steps use /tmp/trivy-cache"
  check 'grep -q "cache: \"false\"" "$WF"' "trivy cache disabled"
  check 'grep -q "persist-credentials: false" "$WF"' "checkout does not persist PAT"
  check '! grep -q "token: \${{ secrets.AUTOFIX_GITHUB_TOKEN }}" "$WF"' "checkout does not pass the write PAT"
  check 'grep -q "Restored non-allowlisted tracked paths" "$WF"' "allowlist restores engine-stripped tracked files"
  check '! grep -q "git add -A" "$WF"' "commit step does not git add -A"
  check 'grep -q "core.hooksPath=/dev/null" "$WF"' "commit/push bypass consumer hooks"
  check 'grep -q "commit --no-verify" "$WF"' "commit uses --no-verify"
  check '! grep -A5 "gh pr create" "$WF" | grep -q "\-\-label"' "gh pr create does not pass --label"
  check 'grep -q "contents: read" "$WF"' "job contents permission is read"
  check 'grep -q "install_dir" "$WF"' "detect package manager outputs install_dir"
  check 'grep -q "corepack enable" "$WF"' "corepack enabled after setup-node"
  check 'grep -q "remote set-url origin" "$WF"' "commit step resets remote.origin before PAT push"
  check 'grep -q "REPO:" "$WF" && grep -q "github.repository" "$WF"' "commit step passes github.repository via env"
  check 'grep -q "\.git/config" "$WF"' "commit step rewrites .git/config before PAT push"
  check 'grep -q "https://github.com/\${REPO}.git" "$WF"' "commit step sets origin to github.com REPO"
  check 'grep -q "GIT_CONFIG_GLOBAL" "$WF"' "commit step ignores global gitconfig on PAT push"
  check '! grep -q "GIT_CONFIG_GLOBAL=/dev/null" "$WF"' "global gitconfig is writable (not /dev/null)"
  check 'grep -q "mktemp" "$WF"' "commit step uses mktemp for global gitconfig"
  check 'grep -q "/usr/bin/git" "$WF"' "commit step pins /usr/bin/git"
  check 'grep -q "/usr/bin/gh" "$WF"' "commit step pins /usr/bin/gh"
  check 'grep -q "unset.*GH_HOST" "$WF"' "commit step unsets GH_HOST"
  check 'grep -q "GIT_CONFIG_PARAMETERS" "$WF"' "commit step unsets GIT_CONFIG_PARAMETERS"
  check 'grep -q "env -i" "$WF"' "commit step runs PAT git/gh under env -i"
  check 'grep -q "GH_HOST=github.com" "$WF"' "env -i child sets GH_HOST=github.com"
  check 'grep -q "GH_CONFIG_DIR" "$WF"' "env -i child uses isolated GH_CONFIG_DIR"
  check 'grep -q "credential.https://github.com.helper" "$WF"' "commit step sets local gh credential helper"
fi

DOC="$ROOT/.github/workflows/TRIVY_SCA_AUTOFIX_README.md"
README="$ROOT/README.md"
check '[[ -f "$DOC" ]]' "TRIVY_SCA_AUTOFIX_README.md exists"
check 'grep -q "trivy-sca-autofix.yml" "$README"' "root README lists the workflow"
if [[ -f "$DOC" ]]; then
  check 'grep -q "AUTOFIX_GITHUB_TOKEN" "$DOC"' "docs mention the PAT"
  check 'grep -q "engine:" "$DOC"' "docs show engine switch"
  check 'grep -q "nothing to do" "$DOC"' "docs include the clean-master case"
  check 'grep -q "chore/trivy-sca-autofix" "$DOC"' "docs name the singleton branch"
  check '! grep -q "gh auth setup-git" "$DOC"' "docs do not mention gh auth setup-git"
fi

LINT="$ROOT/.github/workflows/lint-actions.yml"
if [[ -f "$LINT" ]]; then
  check 'grep -q "trivy-sca-autofix-contract.sh" "$LINT"' "lint-actions runs contract script"
  check 'grep -q "tests/trivy-sca-autofix-contract.sh" "$LINT"' "lint-actions paths include contract script"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "contract checks failed"
  exit 1
fi
echo "all contract checks passed"
