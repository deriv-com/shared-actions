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
check '[[ "DeepSeek V4 Pro PR Review" =~ $TITLE_RE ]]' "accepts DeepSeek V4 Pro PR Review"
check '[[ "DeepSeek V4 Flash PR Review" =~ $TITLE_RE ]]' "accepts DeepSeek V4 Flash PR Review"
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

CONCURRENCY_FORMAT="format('-{0}', inputs.review_title)"
MARKER_FORMAT="format(':{0}', inputs.review_title)"
check 'grep -qF "$CONCURRENCY_FORMAT" "$WF"' "concurrency group appends review_title when set"
check 'grep -qF "$MARKER_FORMAT" "$WF"' "canonical marker appends :review_title when set"
check 'grep -q "REVIEW_SLOT_SUFFIX" "$WF"' "resolve step exports REVIEW_SLOT_SUFFIX for append + progress"

# Match-side (job-level Actions expression on inputs.review_title) and
# append-side (bash on the validated REVIEW_TITLE) are two implementations.
# Extract the prefix each uses before {0} / ${REVIEW_TITLE}; if they drift,
# capture never sees the marker the post step just appended.
MARKER_LINE=$(grep -F 'deriv-pr-review-${{ inputs.engine }}' "$WF" | head -1)
YAML_PREFIX=$(printf '%s\n' "$MARKER_LINE" | sed -n "s/.*format('\([^']*\){0}'.*/\1/p")
BASH_PREFIX=$(sed -n 's/.*REVIEW_SLOT_SUFFIX="\(.*\)\${REVIEW_TITLE}".*/\1/p' "$WF" | head -1)
check '[[ -n "$YAML_PREFIX" ]]' "REVIEW_MARKERS format() prefix is parseable"
check '[[ -n "$BASH_PREFIX" ]]' "REVIEW_SLOT_SUFFIX assignment prefix is parseable"
check '[[ "$YAML_PREFIX" == "$BASH_PREFIX" ]]' "match-side format prefix equals append-side REVIEW_SLOT_SUFFIX prefix"
engine="anthropic"
title="GLM PR Review"
detect_side="<!-- deriv-pr-review-${engine}${YAML_PREFIX}${title} -->"
append_side="<!-- deriv-pr-review-${engine}${BASH_PREFIX}${title} -->"
check '[[ "$detect_side" == "$append_side" ]]' "rendered GLM markers agree"
check 'grep -q "printf .<!-- deriv-pr-review-%s%s -->" "$WF"' "post step appends via REVIEW_ENGINE + REVIEW_SLOT_SUFFIX"
check 'grep -q "deriv-pr-review-progress-\${REVIEW_ENGINE}\${REVIEW_SLOT_SUFFIX:-}" "$WF"' "progress marker is title-scoped"
KIMI_EMPTY_GATE="inputs.review_title == '' && inputs.engine == 'kimi'"
ANTHROPIC_EMPTY_GATE="inputs.review_title == '' && inputs.engine == 'anthropic'"
check 'grep -qF "$KIMI_EMPTY_GATE" "$WF"' "pre-split legacy marker gated on empty title (kimi)"
check 'grep -qF "$ANTHROPIC_EMPTY_GATE" "$WF"' "pre-split legacy marker gated on empty title (anthropic)"

check 'grep -q "| \`review_title\`" "$README"' "README documents review_title"
check 'grep -q "GLM PR Review" "$README"' "README shows GLM PR Review as the caller example"
check 'grep -q "empty title = one slot per engine" "$README"' "README documents empty-title per-engine slots"
check 'grep -q "set title = concurrent slot" "$README"' "README documents title-scoped concurrent slots"
check '! grep -q "group is keyed only by" "$README"' "README no longer says concurrency is engine-only"
check 'grep -q "not authoritative until the run succeeds" "$README"' "README notes invalid review_title still appears in Checks"

check 'grep -q "tests/ai-pr-review-contract.sh" "$LINT"' "lint-actions runs this contract script"
check 'grep -q "test-scripts:" "$LINT"' "lint-actions keeps master's test-scripts job"

if [[ "$fail" -ne 0 ]]; then
  echo "contract checks failed"
  exit 1
fi
echo "all contract checks passed"
