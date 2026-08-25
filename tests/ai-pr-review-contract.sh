#!/usr/bin/env bash
# tests/ai-pr-review-contract.sh
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

WF="$ROOT/.github/workflows/ai-pr-review.yml"
README="$ROOT/.github/workflows/AI_PR_REVIEW_README.md"
LINT="$ROOT/.github/workflows/lint-actions.yml"

check '[[ -f "$WF" ]]' "ai-pr-review.yml exists"
check '[[ -f "$README" ]]' "AI_PR_REVIEW_README.md exists"

# Optional display title: model swap on anthropic (e.g. GLM) without a new engine.
check 'grep -q "^      review_title:" "$WF"' "review_title input is declared"
check 'awk '\''/^      review_title:/{f=1} f && /default:/{print; exit}'\'' "$WF" | grep -q "default: \"\""' "review_title defaults to empty"
check 'grep -q "REVIEW_TITLE_INPUT:" "$WF"' "resolve step reads review_title"
check 'grep -q "inputs.review_title" "$WF"' "job name can use review_title"
check 'grep -q "REVIEW_TITLE=\"\$REVIEW_TITLE_INPUT\"" "$WF" || grep -q "REVIEW_TITLE=\"\${REVIEW_TITLE_INPUT}\"" "$WF"' "non-empty review_title overrides engine default"
check '! grep -q "ai_review_engine_glm" "$WF"' "does not add a glm engine"
check '! grep -qE "engine: glm|'\''glm'\''" "$WF"' "engine enum is unchanged"

check 'grep -q "| \`review_title\`" "$README"' "README documents review_title"
check 'grep -q "GLM PR Review" "$README"' "README shows GLM PR Review as the caller example"

check 'grep -q "tests/ai-pr-review-contract.sh" "$LINT"' "lint-actions runs this contract script"

if [[ "$fail" -ne 0 ]]; then
  echo "contract checks failed"
  exit 1
fi
echo "all contract checks passed"
