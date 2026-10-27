#!/usr/bin/env bash
# Guards the checkout/resolution ordering that unit tests cannot see: the
# resolver reads process.cwd(), so the comment action must resolve guidance
# only after checking out the PR branch it will edit.
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

ACTION="$ROOT/.github/actions/docsync_ai_comment/action.yml"
SCHEDULED="$ROOT/.github/actions/docsync_ai/action.yml"
LINT="$ROOT/.github/workflows/lint-actions.yml"

checkout_line=$(awk '/name: Checkout PR Branch/ { print NR; exit }' "$ACTION")
guidance_line=$(awk '/id: guidance/ { print NR; exit }' "$ACTION")

check '[[ -n "$checkout_line" ]]' "comment action checks out the PR branch"
check '[[ -n "$guidance_line" ]]' "comment action resolves the guidance file"
check '[[ "$checkout_line" -lt "$guidance_line" ]]' \
  "PR branch checkout precedes guidance resolution"
check 'grep -q "id: guidance" "$SCHEDULED"' \
  "scheduled action resolves the guidance file"
check 'grep -q "GUIDANCE_FILE: \${{ steps.guidance.outputs.file }}" "$ACTION"' \
  "comment action plumbs the resolved file into consumers"
check 'grep -q "GUIDANCE_FILE: \${{ steps.guidance.outputs.file }}" "$SCHEDULED"' \
  "scheduled action plumbs the resolved file into consumers"
check 'grep -qE "\(claude\|agents\)" "$ACTION"' \
  "agents.md command alias is wired"
check 'grep -q "tests/docsync-guidance-contract.sh" "$LINT"' \
  "lint-actions runs this contract script"

exit "$fail"
