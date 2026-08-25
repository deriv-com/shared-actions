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

# Same sed expression the workflow must use. Follow-up context strip has to
# drop custom titles (## 🤖 GLM PR Review Complete), not only the engine list.
HEADER_STRIP='/^## 🤖 .+ PR Review Complete$/d'

check '[[ -f "$WF" ]]' "ai-pr-review.yml exists"
check '[[ -f "$README" ]]' "AI_PR_REVIEW_README.md exists"

check 'grep -q "^      review_title:" "$WF"' "review_title input is declared"
check 'awk '\''/^      review_title:/{f=1} f && /default:/{print; exit}'\'' "$WF" | grep -q "default: \"\""' "review_title defaults to empty"
check 'grep -q "REVIEW_TITLE_INPUT:" "$WF"' "resolve step reads review_title"
check 'grep -qE "^    name: .*inputs\\.review_title" "$WF"' "job name uses review_title"
check 'grep -q "REVIEW_TITLE=\"\$REVIEW_TITLE_INPUT\"" "$WF" || grep -q "REVIEW_TITLE=\"\${REVIEW_TITLE_INPUT}\"" "$WF"' "non-empty review_title overrides engine default"
check 'grep -qF "$HEADER_STRIP" "$WF"' "follow-up strip matches any * PR Review Complete heading"
check '! grep -qF "(AI|Claude|Kimi|Grok) PR Review Complete" "$WF"' "follow-up strip is not hardcoded to engine names"
check 'grep -q "review_title_re=" "$WF"' "validation holds the regex in a variable"

TITLE_RE="$(sed -n "s/.*review_title_re='\([^']*\)'.*/\1/p" "$WF" | head -1)"
check '[[ -n "$TITLE_RE" ]]' "review_title_re assignment is parseable"
check '[[ "GLM PR Review" =~ $TITLE_RE ]]' "accepts GLM PR Review"
check '[[ "Kimi PR Review" =~ $TITLE_RE ]]' "accepts Kimi PR Review"
check '[[ ! "GLM Code Audit" =~ $TITLE_RE ]]' "rejects GLM Code Audit"
check '[[ ! "GLM PR Review/" =~ $TITLE_RE ]]' "rejects trailing junk"
bs='foo\bar PR Review'
check '[[ ! "$bs" =~ $TITLE_RE ]]' "rejects a backslash in the title"

got=$(printf '%s\n' '## 🤖 GLM PR Review Complete' 'body' | sed -E -e "$HEADER_STRIP")
check '[[ "$got" == "body" ]]' "header strip drops GLM PR Review Complete"
got=$(printf '%s\n' '## 🤖 Kimi PR Review Complete' 'body' | sed -E -e "$HEADER_STRIP")
check '[[ "$got" == "body" ]]' "header strip still drops Kimi PR Review Complete"
kept=$(printf '%s\n' '## 🤖 GLM Code Audit Complete' 'body' | sed -E -e "$HEADER_STRIP")
check '[[ "$kept" == *$'\''GLM Code Audit Complete'\''* ]]' "header strip leaves headings that are not * PR Review Complete"

check 'grep -q "| \`review_title\`" "$README"' "README documents review_title"
check 'grep -q "GLM PR Review" "$README"' "README shows GLM PR Review as the caller example"
check 'grep -q "is a replacement label" "$README"' "README says review_title is a replacement label"
check 'grep -q "group is keyed only by" "$README"' "README documents same-engine concurrency cancellation"
check 'grep -q "not authoritative until the run succeeds" "$README"' "README notes invalid review_title still appears in Checks"

check 'grep -q "tests/ai-pr-review-contract.sh" "$LINT"' "lint-actions runs this contract script"
check 'grep -q "test-scripts:" "$LINT"' "lint-actions keeps master's test-scripts job"

if [[ "$fail" -ne 0 ]]; then
  echo "contract checks failed"
  exit 1
fi
echo "all contract checks passed"
