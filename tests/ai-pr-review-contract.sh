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
check 'awk '\''/^      review_title:/{f=1} f && /default:/{print; exit}'\'' "$WF" | grep -c "default: \"\"" >/dev/null' "review_title defaults to empty"
check 'grep -q "REVIEW_TITLE_INPUT:" "$WF"' "resolve step reads review_title"
check 'grep -qE "^    name: .*inputs\\.review_title" "$WF"' "job name uses review_title"
check 'grep -q "REVIEW_TITLE=\"\$REVIEW_TITLE_INPUT\"" "$WF" || grep -q "REVIEW_TITLE=\"\${REVIEW_TITLE_INPUT}\"" "$WF"' "non-empty review_title overrides engine default"
check 'grep -qF "$HEADER_STRIP" "$WF"' "follow-up strip matches any * PR Review Complete heading"
check '! grep -qF "(AI|Claude|Kimi|Grok) PR Review Complete" "$WF"' "follow-up strip is not hardcoded to engine names"
check 'grep -q "review_title_re=" "$WF"' "validation holds the regex in a variable"

TITLE_RE="$(sed -n "s/.*review_title_re='\([^']*\)'.*/\1/p" "$WF" | awk 'NR==1')"
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
MARKER_LINE=$(grep -m1 -F 'deriv-pr-review-${{ inputs.engine }}' "$WF")
YAML_PREFIX=$(printf '%s\n' "$MARKER_LINE" | sed -n "s/.*format('\([^']*\){0}'.*/\1/p")
BASH_PREFIX=$(sed -n 's/.*REVIEW_SLOT_SUFFIX="\(.*\)\${REVIEW_TITLE}".*/\1/p' "$WF" | awk 'NR==1')
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
check 'grep -q "| \`effort\`" "$README"' "README documents effort"
check 'grep -q "GLM PR Review" "$README"' "README shows GLM PR Review as the caller example"
check 'grep -q "empty title = one slot per engine" "$README"' "README documents empty-title per-engine slots"
check 'grep -q "set title = concurrent slot" "$README"' "README documents title-scoped concurrent slots"
check '! grep -q "group is keyed only by" "$README"' "README no longer says concurrency is engine-only"
check 'grep -q "not authoritative until the run succeeds" "$README"' "README notes invalid review_title still appears in Checks"
check 'grep -q "stale progress" "$README"' "README documents orphaned progress comments after a title-slot change"

check 'grep -q "tests/ai-pr-review-contract.sh" "$LINT"' "lint-actions runs this contract script"
check 'grep -q "test-scripts:" "$LINT"' "lint-actions keeps master's test-scripts job"


# ---------------------------------------------------------------------------
# HackerOne #4037167 — the controls that close the GITHUB_TOKEN exfiltration
# chain. Each one is independent; each must stay. A refactor that drops one
# should fail here, not in a HackerOne report.
# ---------------------------------------------------------------------------
KIMI="$ROOT/.github/actions/ai_review_engine_kimi/action.yml"
ANTH="$ROOT/.github/actions/ai_review_engine_anthropic/action.yml"
GROK="$ROOT/.github/actions/ai_review_engine_grok/action.yml"
CODEX="$ROOT/.github/actions/ai_review_engine_codex/action.yml"
MUSE="$ROOT/.github/actions/ai_review_engine_muse/action.yml"
GUARD="$ROOT/.github/actions/ai_review_path_guard/path-guard.js"
GUARD_TEST="$ROOT/.github/actions/ai_review_path_guard/path-guard.test.js"

# Lines of $2 between the step named $1 and the next step, for "this step
# contains X" checks that must not be satisfied by some other step.
step_body() { awk -v name="- name: $1" 'index($0, name){f=1; next} f && /^ *- name: /{exit} f' "$2"; }
# Step body with backslash-continuations joined into single lines, for greps
# that must see a multi-line command (env prefix + invocation) as one line.
joined_step_body() { step_body "$1" "$2" | awk '/\\$/ { sub(/\\$/, ""); buf = buf $0 " "; next } { print buf $0; buf = "" }'; }

# This script runs under `set -o pipefail`. A reader that quits early (`head`,
# `grep -q`, `awk ... {exit}`) can SIGPIPE the writer before it finishes, and
# pipefail turns that into exit 141: outside check() it kills the script, inside
# check() it flips the result. Readers on a pipe must consume all input: use
# `grep -c ... >/dev/null` instead of `grep -q`, `awk 'NR==1'` instead of
# `head -1`, and a done-flag instead of `exit` in awk. This applies only to the
# reader end of a pipe: a command that reads a file or `<<<` input directly
# (e.g. `grep -q PATTERN "$WF"`, `grep -m1 ... "$WF"`) may exit early, since
# there is no writer to kill.

# Verdict marker: the post step derives a machine-readable verdict from the
# mandated Recommendation line and appends it next to the engine marker, so
# downstream consumers (Forge) never parse prose. Behavioural: run the
# extracted block against fixture reviews.
check 'grep -q "deriv-pr-review-verdict: %s; findings=%s" "$WF"' "post step appends the deriv-pr-review-verdict marker"
check 'grep -qF "gh-app-write[bot]" "$WF"' "acknowledge scan accepts Forge's write-App identity"
# The awk must stop after the marker-append line (the "} >> $REVIEW_OUTPUT_FILE"
# line): an earlier version set done after printing, so the block ran on into
# the step's posting code and a local run of this suite posted every fixture
# to the PR as a real comment. The gh check below plus the emptied tokens in
# verdict_of keep that impossible even if the step grows new side effects.
VERDICT_BLOCK=$(step_body "Post review as single PR comment" "$WF" | awk '/verdict_token="unknown"/{f=1} !done && f{print} f && />> "\$REVIEW_OUTPUT_FILE"/{done=1}' | sed 's/^ *//')
check '[[ -n "$VERDICT_BLOCK" ]] && ! grep -qE "gh (pr comment|api)" <<< "$VERDICT_BLOCK"' "the extracted verdict block stops at the marker append and contains no gh call"
verdict_of() {
  local fixture marker
  fixture=$(mktemp)
  printf '%s\n' "$1" > "$fixture"
  GH_TOKEN= GITHUB_TOKEN= REVIEW_OUTPUT_FILE="$fixture" CURRENT_SHA=abc REVIEW_ENGINE=claude REVIEW_SLOT_SUFFIX="" bash -c "$VERDICT_BLOCK" >/dev/null 2>&1
  marker=$(grep -o 'deriv-pr-review-verdict: [a-z-]*; findings=[0-9]*' "$fixture" | awk 'NR==1')
  rm -f "$fixture"
  printf '%s' "$marker"
}
check '[[ "$(verdict_of "**Recommendation:** APPROVE")" == "deriv-pr-review-verdict: approve; findings=0" ]]' "an APPROVE review gets verdict approve with zero findings"
check '[[ "$(verdict_of "**Recommendation:** REQUEST CHANGES

## Findings

1. **One** — a.ts:1 — Block
2. **Two** — b.ts:2 — Change")" == "deriv-pr-review-verdict: request-changes; findings=2" ]]' "a REQUEST CHANGES review counts its Findings entries"
check '[[ "$(verdict_of "**Recommendation:** BLOCK MERGE")" == "deriv-pr-review-verdict: block-merge; findings=0" ]]' "a BLOCK MERGE review gets verdict block-merge"
check '[[ "$(verdict_of "No recommendation line here.")" == "deriv-pr-review-verdict: unknown; findings=0" ]]' "a review with no readable Recommendation gets verdict unknown, never a silent approval"

# 1. Fork PRs never reach the privileged job. Same-repo Forge
#    (gh-app-write[bot]) is the only *[bot] exception: wrap the skip, do not
#    delete it. A bare allow-all-bots if: is a regression. Presence greps
#    alone would stay green if the wrap parentheses were dropped; the
#    structure grep requires the exception inside that group and the
#    same-repo clause &&-ed outside it.
check 'grep -qE "^    if: .*github\.event\.pull_request\.head\.repo\.full_name == github\.repository" "$WF"' "job-level if: skips PRs whose head repo is not the base repo"
check 'grep -qE "^    if: .*!endsWith\(github\.actor, .\[bot\].\)" "$WF"' "job-level if: still skips *[bot] actors (not a bare allow-all-bots)"
check 'grep -qE "^    if: .*gh-app-write\[bot\]" "$WF"' "job-level if: allowlists gh-app-write[bot]"
check 'grep -qE "^    if: .*\(!endsWith\(github\.actor, .\[bot\].\) *\|\| *github\.actor == .gh-app-write\[bot\].\).*&& *github\.event\.pull_request\.head\.repo\.full_name == github\.repository" "$WF"' "job-level if: scopes the gh-app-write[bot] exception inside the bot check, with the same-repo clause outside"
GATE_BODY="$(step_body "Security Check - Validate User Access" "$WF")"
check 'grep -F "gh-app-write[bot]" <<< "$GATE_BODY" | grep -c "exit 0" >/dev/null' "access gate allowlists gh-app-write[bot] on a line that exits 0"

# 2. The checkout leaves no token on disk.
check 'step_body "Checkout PR head" "$WF" | grep -c "persist-credentials: false" >/dev/null' "PR-head checkout sets persist-credentials: false"

# 3. Symlinks: rejected up front, and swept by every engine's scrub.
check 'grep -q "name: Reject symlinks introduced by the PR" "$WF"' "symlink rejection step exists"
check 'awk '\''/- name: Checkout PR head/{c=NR} /- name: Reject symlinks introduced by the PR/{s=NR} /END ENGINE DISPATCH/{d=NR; exit} END{exit !(c && s && d && c<s && s<d)}'\'' "$WF"' "symlink step runs after checkout and before the engines"
SYMLINK_STEP="$(step_body "Reject symlinks introduced by the PR" "$WF")"
check 'grep -q "git ls-tree -r -z HEAD" <<< "$SYMLINK_STEP"' "symlink step enumerates the checked-out tree with git (complete, NUL-safe), not the PR files API"
check 'grep -q "\"120000\"" <<< "$SYMLINK_STEP"' "symlink step keys on mode 120000"
check '! grep -q "pulls/\$PR_NUMBER/files" <<< "$SYMLINK_STEP"' "symlink step no longer depends on the PR files API (branch-tip semantics)"
check 'grep -q "BASE_SHA: \${{ github.event.pull_request.base.sha }}" <<< "$SYMLINK_STEP"' "symlink step pins the base side to the event's base SHA"
check 'grep -q "git/trees/" <<< "$SYMLINK_STEP" && grep -qF ".mode == \"120000\") | .sha" <<< "$SYMLINK_STEP" && grep -qF "[[ \"\$blob\" == \"\$sha\" ]]" <<< "$SYMLINK_STEP"' "symlink step compares path AND blob against the base tree (a retargeted link counts as new)"
check '! grep -q "recursive=1" <<< "$SYMLINK_STEP"' "symlink step walks non-recursive tree listings (the recursive form truncates silently)"
FILE_SWEEP='-o \( -type f -o -type l \)'
DIR_SWEEP='-o \( -type d -o -type l \)'
for engine in "$KIMI" "$ANTH" "$GROK" "$CODEX" "$MUSE"; do
  name=$(basename "$(dirname "$engine")")
  check 'grep -qF -- "$FILE_SWEEP" "$engine"' "$name: instruction-file scrub matches symlinks"
  check 'grep -qF -- "$DIR_SWEEP" "$engine"' "$name: config-directory scrub matches symlinks"
  check '! grep -qE -- "-prune -o -type [fd] " "$engine"' "$name: no scrub keyed on a bare -type f / -type d remains"
done

# ---------------------------------------------------------------------------
# Codex engine — the fourth engine. The "adding an engine is N edits" contract
# (header, enum case arm, dispatch gate, job name, outputs) plus the inputs the
# user asked for (reasoning_effort), plus the one place this engine DEVIATES
# from Kimi/Anthropic: it cannot wire the shared path guard, so its sandbox is
# the enforcement and that must stay. These checks fail if a refactor drops the
# codex arm, un-wires reasoning_effort, or relaxes the sandbox controls.
# ---------------------------------------------------------------------------
check '[[ -f "$CODEX" ]]' "codex engine action.yml is committed"

# Enum: resolve-step case arm, unknown-engine error list, and job name all name codex.
check 'grep -qE "^            codex\)" "$WF"' "resolve step has a codex case arm"
check 'grep -q "kimi, anthropic, grok, codex, muse" "$WF"' "unknown-engine error lists codex and muse"
check 'grep -qF "inputs.engine == '\''codex'\'' && '\''Codex PR Review'\''" "$WF"' "job name resolves codex to Codex PR Review"
check 'grep -q "DEFAULT_MODEL=\"gpt-6.1-sol\"" "$WF"' "codex arm pins DEFAULT_MODEL=gpt-6.1-sol"
check 'grep -q "METRICS_AGENT=\"codex_review\"" "$WF"' "codex arm pins METRICS_AGENT=codex_review"
check 'grep -q "ARTIFACT_PREFIX=\"codex-review\"" "$WF"' "codex arm pins ARTIFACT_PREFIX=codex-review"

# Anthropic default model. Every live copy of the alias must match, so a bump
# that misses one fails here instead of shipping to every consumer. The copies:
# the resolve-step arm and the `model` input description in ai-pr-review.yml,
# the engine action's own default, the README engines table, and the two
# copies in the deprecated claude-pr-review.yml (input default and the
# CLAUDE_MODEL env fallback).
ANTH_DEFAULT_MODEL="claude-sonnet-5-5"
DEPRECATED_WF="$ROOT/.github/workflows/claude-pr-review.yml"
check 'grep -q "DEFAULT_MODEL=\"${ANTH_DEFAULT_MODEL}\"" "$WF"' "anthropic arm pins DEFAULT_MODEL=${ANTH_DEFAULT_MODEL}"
check 'grep -qF "anthropic -> ${ANTH_DEFAULT_MODEL}," "$WF"' "model input description names ${ANTH_DEFAULT_MODEL} for anthropic"
check 'grep -qF "default: \"${ANTH_DEFAULT_MODEL}\"" "$ANTH"' "anthropic engine action defaults model to ${ANTH_DEFAULT_MODEL}"
# Match only the anthropic cell (second column), so a kimi bump cannot fail it.
check 'grep -qE "^\| Default model \|[^|]*\| \`${ANTH_DEFAULT_MODEL}\` \|" "$README"' "README engines table lists ${ANTH_DEFAULT_MODEL} for anthropic"
check 'grep -qF "default: \"${ANTH_DEFAULT_MODEL}\"" "$DEPRECATED_WF"' "deprecated claude-pr-review.yml defaults claude_model to ${ANTH_DEFAULT_MODEL}"
check 'grep -qF "inputs.claude_model || '\''${ANTH_DEFAULT_MODEL}'\''" "$DEPRECATED_WF"' "deprecated claude-pr-review.yml falls back to ${ANTH_DEFAULT_MODEL}"

# Kimi CLI version. Every live copy of the pin must match, so a bump that
# misses one fails here instead of shipping to every consumer. The copies:
# the resolve-step arm in ai-pr-review.yml, the engine action's own default,
# and the README inputs table. Each check is scoped to its own copy (the kimi
# arm, the cli_version input block, the kimi cell) with fixed-string matches,
# so another engine's copy, a commented-out line, or a near-miss version
# cannot satisfy it.
KIMI_CLI_VERSION="2.3.2"
KIMI_ARM="$(awk '/^            kimi\)/{f=1} f{print} f && /;;/{exit}' "$WF")"
check 'grep -qxF "              DEFAULT_CLI_VERSION=\"${KIMI_CLI_VERSION}\"" <<< "$KIMI_ARM"' "kimi arm pins DEFAULT_CLI_VERSION=${KIMI_CLI_VERSION}"
KIMI_CLI_INPUT="$(awk '/^  cli_version:/{f=1; next} f && /^  [a-z_]+:/{exit} f' "$KIMI")"
check 'grep -qxF "    default: \"${KIMI_CLI_VERSION}\"" <<< "$KIMI_CLI_INPUT"' "kimi engine action defaults cli_version to ${KIMI_CLI_VERSION}"
# Match only the kimi cell (first column of the per-engine list), so a grok or
# codex bump cannot satisfy or fail it.
check 'grep -qF "per engine (\`${KIMI_CLI_VERSION}\` kimi," "$README"' "README inputs table lists ${KIMI_CLI_VERSION} for kimi"

# Dispatch: an if-gated step referencing the codex engine by absolute @master path.
check 'grep -q "if: steps.engine.outputs.engine == '\''codex'\''" "$WF"' "codex dispatch step is if-gated on the engine output"
check 'grep -q "ai_review_engine_codex@master" "$WF"' "codex dispatch references the engine by absolute @master path"
check 'awk '\''/if: steps.engine.outputs.engine == .codex./{g=1} g && /timeout-minutes: 60/{print; exit}'\'' "$WF" | grep -c "timeout-minutes: 60" >/dev/null' "codex dispatch step carries timeout-minutes: 60"

# reasoning_effort: declared input (default empty), resolve-step validation,
# emitted on the step outputs, and passed to the codex dispatch step.
check 'grep -q "^      reasoning_effort:" "$WF"' "reasoning_effort input is declared"
check 'awk '\''/^      reasoning_effort:/{f=1} f && /default:/{print; exit}'\'' "$WF" | grep -c "default: \"\"" >/dev/null' "reasoning_effort defaults to empty"
check 'grep -q "REASONING_EFFORT_INPUT:" "$WF"' "resolve step reads reasoning_effort"
check 'grep -q "minimal|low|medium|high|xhigh" "$WF"' "resolve step validates reasoning_effort against minimal|low|medium|high|xhigh"
check 'grep -q "echo \"reasoning_effort=\$REASONING_EFFORT\"" "$WF"' "resolve step emits reasoning_effort on the step outputs"
check 'grep -q "reasoning_effort: \${{ steps.engine.outputs.reasoning_effort }}" "$WF"' "codex dispatch step passes reasoning_effort through"
# Engine side: accepts the input and only overrides when non-empty.
check 'grep -q "^  reasoning_effort:" "$CODEX"' "codex engine declares the reasoning_effort input"
check 'grep -q "model_reasoning_effort" "$CODEX"' "codex engine maps reasoning_effort onto model_reasoning_effort"
check 'grep -qE "if \[\[ -n \"\\\$REASONING_EFFORT\" \]\]" "$CODEX"' "codex engine applies reasoning_effort only when non-empty"

# effort: anthropic-only, same dual-validation pattern as reasoning_effort.
check 'grep -q "^      effort:" "$WF"' "effort input is declared"
check 'awk '\''/^      effort:/{f=1} f && /default:/{print; exit}'\'' "$WF" | grep -c "default: \"\"" >/dev/null' "effort defaults to empty"
check 'grep -qE "^[[:space:]]+EFFORT_INPUT:" "$WF"' "resolve step reads effort"
check 'grep -q "echo \"effort=\$EFFORT\"" "$WF"' "resolve step emits effort on the step outputs"
check 'grep -q "effort: \${{ steps.engine.outputs.effort }}" "$WF"' "anthropic dispatch step passes effort through"
check 'grep -q "^  effort:" "$ANTH"' "anthropic engine declares the effort input"

# --- Anthropic recover/retry: behaviour pins, scoped to the step or script
# that owns them so a comment elsewhere cannot satisfy them. ---
ANTH_RECOVER="$ROOT/.github/actions/ai_review_engine_anthropic/recover-review.sh"
check '[[ -f "$ANTH_RECOVER" ]]' "the recovery logic ships as one script in the anthropic engine"
check '[[ $(grep -c "bash \"\$ACTION_PATH/recover-review.sh\"" "$ANTH") -eq 2 ]]' "both recovery steps call the shared recovery script"
check 'grep -qF "select(.type == \"assistant\")" "$ANTH_RECOVER"' "recovery extracts the final assistant text from the session transcript"
ANTH_RECOVER_CODE="$(grep -vE '^[[:space:]]*#' "$ANTH_RECOVER")"
check 'grep -qF "if length == 1 and (.[0]|type) == \"array\"" "$ANTH_RECOVER" && grep -qF "select(.type == \"assistant\")" "$ANTH_RECOVER"' "recovery slurps the transcript, flattening a single JSON array, and takes the final assistant text"
check 'grep -qF '"'"'^\*\*Recommendation:\*\*[[:space:]]+(APPROVE|REQUEST CHANGES|BLOCK MERGE)'"'"' <<< "$ANTH_RECOVER_CODE" && grep -qF "> \"\$OUTPUT_PATH\"" <<< "$ANTH_RECOVER_CODE" && grep -qF "echo \"still_missing=\$missing\"" <<< "$ANTH_RECOVER_CODE"' "recovery only writes a complete review (anchored Recommendation verdict) and reports still_missing"
check 'step_body "Recover the retry'"'"'s review from the session transcript" "$ANTH" | grep -cF "bash \"\$ACTION_PATH/recover-review.sh\"" >/dev/null' "the retry recovery step has its own name and calls the same script"
check 'grep -qF "steps.claude.outputs.execution_file" "$ANTH" && grep -qF "steps.claude-retry.outputs.execution_file" "$ANTH"' "recovery reads each attempt's transcript through the action's declared execution_file output, not a hardcoded path"
check 'step_body "Claude Code PR review (retry after an empty first attempt)" "$ANTH" | grep -cF "if: steps.recover.outputs.still_missing == '"'"'true'"'"'" >/dev/null && step_body "Claude Code PR review (retry after an empty first attempt)" "$ANTH" | grep -c "uses: anthropics/claude-code-action@" >/dev/null' "the retry gate sits on the claude-code-action retry step itself"
check '[[ $(grep -c "uses: anthropics/claude-code-action@5eb090f3" "$ANTH") -eq 2 ]]' "exactly two pinned claude-code-action invocations exist (attempt and retry)"
check 'step_body "Reset the path-guard log for the retry" "$ANTH" | grep -cF ": > \"\$PATH_GUARD_LOG\"" >/dev/null && step_body "Reset the path-guard log for the retry" "$ANTH" | grep -c "still_missing" >/dev/null' "the path-guard log is wiped, gated on still_missing, before the retry so verify judges the producing attempt"
check 'step_body "Verify the sandbox held and the review was written" "$ANTH" | grep -cF "echo \"❌ Anthropic engine: claude-code-action finished but wrote no review to \$OUTPUT_PATH\"" >/dev/null' "verify fails closed, in its own step body, when no review exists"

# Behavioural: run the shipped recovery script against fixture transcripts.
RECOVER_TMP=$(mktemp -d)
RECOVERY_REVIEW='## Summary

A perfectly serviceable review body with enough prose to clear the two
hundred character completeness threshold recovery requires before it will
trust a transcript over the fail-closed verify step.

**Recommendation:** APPROVE'
jq -n --arg t "$RECOVERY_REVIEW" '[{type:"user",message:{content:[{type:"text",text:"review this"}]}},{type:"assistant",message:{content:[{type:"text",text:$t}]}}]' > "$RECOVER_TMP/array.json"
{ jq -cn --arg t "Let me read the context file first, then the diff, and gather my thoughts before writing anything up." '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'
  jq -cn --arg t "$RECOVERY_REVIEW" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'
} > "$RECOVER_TMP/stream.ndjson"
jq -n '[{type:"assistant",message:{content:[{type:"text",text:"## Summary\n\nPartial ans"}]}}]' > "$RECOVER_TMP/truncated.json"
jq -n --arg t "This draft quotes the mandated line mid-sentence, the format is **Recommendation:** APPROVE when the review is finished, and then keeps talking for a good while longer so the length threshold is comfortably cleared as well." '[{type:"assistant",message:{content:[{type:"text",text:$t}]}}]' > "$RECOVER_TMP/midline.json"
recover_fixture() {
  local d
  d=$(mktemp -d)
  if [[ -n "${2:-}" ]]; then printf '%s' "$2" > "$d/out.txt"; fi
  OUTPUT_PATH="$d/out.txt" EXECUTION_FILE="$1" GITHUB_OUTPUT="$d/gh.txt" bash "$ANTH_RECOVER" >/dev/null 2>&1
  printf '%s' "$d"
}
d=$(recover_fixture "$RECOVER_TMP/array.json")
check 'grep -qF "still_missing=false" "$d/gh.txt" && grep -qF "**Recommendation:** APPROVE" "$d/out.txt"' "recovery recovers a complete review from a JSON-array transcript"
d=$(recover_fixture "$RECOVER_TMP/stream.ndjson")
check 'grep -qF "still_missing=false" "$d/gh.txt" && grep -qF "**Recommendation:** APPROVE" "$d/out.txt" && ! grep -qF "Let me read the context file" "$d/out.txt"' "recovery takes only the final assistant text from a stream-json transcript, never earlier preambles"
d=$(recover_fixture "$RECOVER_TMP/truncated.json")
check 'grep -qF "still_missing=true" "$d/gh.txt" && [[ ! -s "$d/out.txt" ]]' "recovery leaves a truncated transcript unrecovered"
d=$(recover_fixture "$RECOVER_TMP/midline.json")
check 'grep -qF "still_missing=true" "$d/gh.txt" && [[ ! -s "$d/out.txt" ]]' "recovery does not recover a mid-line quote of the Recommendation format"
d=$(recover_fixture "$RECOVER_TMP/array.json" "EXISTING REVIEW KEEP ME")
check 'grep -qF "still_missing=false" "$d/gh.txt" && [[ "$(cat "$d/out.txt")" == "EXISTING REVIEW KEEP ME" ]]' "recovery never overwrites a review the engine did write"
rm -rf "$RECOVER_TMP"

# The retry is a copy of attempt 1 by design (a step cannot run twice). Pin
# the copies together: with comments, the id, the gate and the three retry
# prompt lines removed, the bodies must be byte-identical, so the sandbox and
# credential config (settings hook, claude_args, allowed_non_write_users,
# GIT_CONFIG_*, the SHA) cannot drift between attempts.
normalised_engine_step() {
  step_body "$1" "$ANTH" \
    | grep -vE '^[[:space:]]*#' \
    | grep -vE '^[[:space:]]*id: ' \
    | grep -vF 'if: steps.recover.outputs.still_missing' \
    | grep -vF 'A first attempt at this review already ended without writing the file;' \
    | grep -vF 'this is the retry. Make that Write call before you finish, even if the' \
    | grep -vF 'review is short.' \
    | awk 'NF'
}
check 'diff <(normalised_engine_step "Claude Code PR review") <(normalised_engine_step "Claude Code PR review (retry after an empty first attempt)") >/dev/null' "retry step matches attempt 1 modulo name, gate, comments and the retry prompt lines"
check 'grep -qF -- '"'"'--model ${{ inputs.model }} ${{ steps.effort.outputs.flag }}'"'"' "$ANTH"' "anthropic engine maps effort onto claude_args via the resolve-effort step"
check 'grep -qE "if \[\[ -n \"\\\$EFFORT\" \]\]" "$ANTH"' "anthropic engine applies effort only when non-empty"

# thinking_effort: kimi-only, same dual-validation pattern as effort.
check 'grep -q "^      thinking_effort:" "$WF"' "thinking_effort input is declared"
check 'awk '\''/^      thinking_effort:/{f=1} f && /default:/{print; exit}'\'' "$WF" | grep -c "default: \"\"" >/dev/null' "thinking_effort defaults to empty"
check 'grep -q "THINKING_EFFORT_INPUT:" "$WF"' "resolve step reads thinking_effort"
check 'grep -qF "low|high|max) ;;" "$WF"' "resolve step validates thinking_effort against low|high|max"
check 'grep -q "echo \"thinking_effort=\$THINKING_EFFORT\"" "$WF"' "resolve step emits thinking_effort on the step outputs"
check 'grep -q "thinking_effort: \${{ steps.engine.outputs.thinking_effort }}" "$WF"' "kimi dispatch step passes thinking_effort through"
check 'grep -q "^  thinking_effort:" "$KIMI"' "kimi engine declares the thinking_effort input"
check 'grep -qF "export KIMI_MODEL_THINKING_EFFORT=\"\$THINKING_EFFORT\"" "$KIMI"' "kimi engine maps thinking_effort onto KIMI_MODEL_THINKING_EFFORT"
check 'grep -qE "if \[\[ -n \"\\\$THINKING_EFFORT\" \]\]" "$KIMI"' "kimi engine applies thinking_effort only when non-empty"
check 'grep -q "unset KIMI_MODEL_THINKING_EFFORT" "$KIMI"' "kimi engine unsets KIMI_MODEL_THINKING_EFFORT when thinking_effort is empty"

# Posted **Effort:** line: resolved once, printed under **Model:**, stripped on follow-up.
check 'grep -q "REVIEW_EFFORT_DISPLAY=" "$WF"' "resolve exports REVIEW_EFFORT_DISPLAY"
check 'grep -qF "model default (no override sent)" "$WF"' "kimi empty effort display is model default (no override sent)"
check '[[ "$(grep -cF "printf '\''\`%s\` (default)'\'' medium" "$WF")" -eq 2 ]]' "anthropic and codex empty effort display is medium (default)"
check 'grep -qF "n/a (this engine has no effort override)" "$WF"' "grok effort display is n/a"
effort_under_model() {
  awk '/printf '\''\*\*Model:\*\*/{m=NR} /printf '\''\*\*Effort:\*\*/{e=NR} END{exit !(m && e && e==m+1)}' <<< "$1"
}
PROGRESS_BODY="$(step_body "Post progress comment" "$WF")"
POST_BODY="$(step_body "Post review as single PR comment" "$WF")"
FAILED_BODY="$(step_body "Mark progress comment failed" "$WF")"
check 'effort_under_model "$PROGRESS_BODY"' "progress comment prints Effort immediately after Model"
check 'effort_under_model "$POST_BODY"' "posted review prints Effort immediately after Model"
check 'effort_under_model "$FAILED_BODY"' "failed progress comment prints Effort immediately after Model"
check 'grep -qF "/^\\*\\*Effort:\\*\\*/d" "$WF"' "follow-up sed drops the Effort header"
check 'grep -qF "a **Effort:** line" "$WF"' "prompt forbids an Effort line"
check 'grep -q "| \*\*effort\*\*" "$WF"' "job summary has an effort row"
check 'grep -qF "**Effort:**" "$README"' "README documents Model then Effort on the posted comment"

# This engine CANNOT wire the shared path guard (Codex's hook contract uses
# Bash/apply_patch tool names and tool_input.command, not Read/Write + a path),
# so the sandbox is the enforcement boundary. These are its load-bearing
# controls; a refactor must not quietly remove them.
check 'grep -q -- "--sandbox workspace-write" "$CODEX"' "codex engine also pins the sandbox on the CLI (config regression cannot relax it)"
check 'grep -q "sandbox_workspace_write.network_access=false" "$CODEX"' "codex engine also pins network_access=false on the CLI"
check '! step_body "Run AI PR review (Codex)" "$CODEX" | grep -cE "^ *(GITHUB_TOKEN|GH_TOKEN):" >/dev/null' "codex engine run step env holds no GitHub token"
check 'grep -q "path guard" "$CODEX"' "codex engine documents why it has no path guard"
# review_file_ok in the run step still fails closed if no review landed at the /tmp output.
check 'grep -q "no review written to \$OUTPUT_PATH" "$CODEX"' "codex engine fails if no review was written"
check 'grep -qF -- "$FILE_SWEEP" "$CODEX"' "codex engine instruction-file scrub matches symlinks"
check 'grep -qF -- "$DIR_SWEEP" "$CODEX"' "codex engine config-directory scrub matches symlinks"
check 'grep -q "actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020" "$CODEX"' "codex engine pins setup-node to the shared SHA"
# Added in review: fail fast if the Landlock sandbox cannot exist on the runner
# (mirrors the Grok engine's bubblewrap userns probe), scrub the LLM key from
# the env of model-spawned commands, and catch the base64 encoding of the key
# in the shared post-step exfiltration guard.
check 'grep -q "is older than 5.13 (no Landlock)" "$CODEX"' "codex engine fails fast on a kernel older than 5.13"
# Smoke test: Codex runs commands through bubblewrap and dies without a
# userns-capable bwrap; the pristine config copy survives Codex rewriting
# config.toml between attempts.
nc_fixed() { grep -vE '^[[:space:]]*#' "$CODEX" | grep -cF -- "$1" >/dev/null; }
check 'nc_fixed "bwrap --unshare-user --unshare-net"' "codex engine probes bubblewrap user+net namespaces before running"
check 'nc_fixed "apparmor_parser -r"' "codex engine loads a bwrap userns AppArmor profile"
check 'nc_fixed "cp -f -- \"\$CONFIG_PRISTINE\" \"\$CODEX_HOME/config.toml\""' "codex restores config.toml from the pristine copy before each attempt"
check 'grep -q "\[shell_environment_policy\]" "$CODEX"' "codex engine scrubs the LLM key from model-spawned command env"
# The config.toml heredoc is unquoted (so ${MODEL}/${BASE_URL} expand). A
# backtick or $( anywhere in its body is command substitution: a comment that
# quoted `env` once dumped the runner environment into config.toml and the CLI
# refused to start. Keep the body free of both, and of comments altogether.
CODEX_TOML_BODY=$(awk '/cat > "\$CODEX_HOME\/config.toml" <<EOF/{f=1;next} f&&/^ *EOF$/{f=0} f' "$CODEX")
check '[[ -n "$CODEX_TOML_BODY" ]]' "codex config.toml heredoc located by the contract test"
check '! printf "%s\n" "$CODEX_TOML_BODY" | grep -c -E "\`|\\\$\(" >/dev/null' "codex config.toml heredoc has no command substitution"
check '! printf "%s\n" "$CODEX_TOML_BODY" | grep -c -E "^[[:space:]]*#" >/dev/null' "codex config.toml heredoc has no comment lines"
# Codex CLI 0.160.0 refuses wire_api = "chat" at startup (found by the smoke
# test), so both the config and the CLI pin must say "responses".
check '[[ $(grep -vE "^[[:space:]]*#" "$CODEX" | grep -c "wire_api = \"responses\"") -eq 1 ]]' "codex config pins wire_api = responses"
check '[[ $(grep -vE "^[[:space:]]*#" "$CODEX" | grep -cF "wire_api=\"responses\"") -eq 1 ]]' "codex CLI pins wire_api=responses"
check '[[ $(grep -vE "^[[:space:]]*#" "$CODEX" | grep -c "\"chat\"") -eq 0 ]]' "codex engine never sets wire_api chat"
check 'grep -vE "^[[:space:]]*#" "$WF" | grep -cF "b64_key_in \"\$REVIEW_OUTPUT_FILE\"" >/dev/null && grep -q "base64-encoded LLM_API_KEY" "$WF"' "post-step refuses a base64-encoded LLM API key (shell-engine exfil hardening)"

# Sandbox and key-routing controls. Greps below go through ncgrep, which
# ignores lines whose first non-space character is '#', so a commented-out
# control fails.
ncgrep() { grep -vE '^[[:space:]]*#' "$2" | grep -cE -- "$1" >/dev/null; }
check 'ncgrep "^ *sandbox_mode = \"workspace-write\"$" "$CODEX"' "codex config.toml runs under the workspace-write sandbox"
check 'ncgrep "^ *network_access = false$" "$CODEX"' "codex config.toml disables sandbox network access for model commands"
check 'ncgrep "^ *approval_policy = \"never\"$" "$CODEX"' "codex config.toml forbids escalation out of the sandbox"
check 'ncgrep "^ *web_search = false$" "$CODEX"' "codex config.toml disables web search (no outbound tool)"
check 'ncgrep "\"\\\$\{PIN_ARGS\[@\]\}\"" "$CODEX"' "codex passes PIN_ARGS to codex exec"
check 'step_body "Configure review CLI (Codex)" "$CODEX" | grep -vE "^[[:space:]]*#" | grep -cE "^ +/tmp/\*\) ;;$" >/dev/null' "codex output_path guard accepts /tmp/* (the only allowed arm)"
check 'ncgrep "model contains characters not allowed" "$CODEX" && ncgrep "base_url must be an http\(s\) URL" "$CODEX"' "codex rejects model/base_url values that could break out of a TOML string"
check 'ncgrep "KMIN=\"\\\$\{KMIN%%\[\^0-9\]\*\}\"" "$CODEX"' "codex kernel probe strips -rc style suffixes"
# The strip sweep exists once (a script under runner.temp) and is re-run,
# hash-checked, before every attempt.
check 'ncgrep "STRIP_SCRIPT: \\\$\{\{ runner\.temp \}\}/codex-engine-bin/" "$CODEX"' "codex strip script lives under runner.temp"
check '[[ $(grep -vE "^[[:space:]]*#" "$CODEX" | grep -cE "bash -euo pipefail \"\\\$STRIP_SCRIPT\"") -eq 2 ]]' "codex runs the same strip script in the strip step and before each attempt"
check 'ncgrep "strip script changed since the strip step" "$CODEX"' "codex verifies the strip script hash before each attempt"
check '[[ $(grep -vE "^[[:space:]]*#" "$CODEX" | grep -cE "iname .agents\.md." ) -eq 1 ]]' "codex has one copy of the instruction-file sweep"
# After the run, the review must be a regular singly-linked file still under /tmp.
check 'ncgrep "is not a regular file \(symlink or special file\)" "$CODEX" && ncgrep "has more than one hard link" "$CODEX"' "codex refuses a symlinked or hard-linked review file"
check 'ncgrep "if ! review_file_ok; then" "$CODEX"' "codex final check goes through review_file_ok"
# Live CLI output is wrapped in a random ::stop-commands:: token.
check 'step_body "Run AI PR review (Codex)" "$CODEX" | grep -vE "^[[:space:]]*#" | awk "/stop-commands::\\\$LIVE_TOKEN/{a=1} a && /codex exec/{b=1} b && /\"::\\\$LIVE_TOKEN::\"/{c=1} END{exit !c}"' "codex wraps live codex exec output in ::stop-commands::"
check '! ncgrep "no exfiltration" "$CODEX"' "codex engine makes no 'no exfiltration' claim (contradicts its residual-risk note)"
check '! grep -q "neither a shell tool nor network access" "$CODEX"' "codex pr_diff_path description does not claim the model has no shell"
check '! grep -q "exactly 3 edits" "$WF"' "orchestrator header no longer claims exactly 3 edits"
# Post step: private no-follow copy of the review; no /tmp scratch files.
check 'ncgrep "POST_DIR=\"\\\$\(mktemp -d \"\\\$RUNNER_TEMP/" "$WF" && ncgrep "cp -P -- \"\\\$REVIEW_OUTPUT_FILE\"" "$WF"' "post step copies the review into a private dir without following links"
check '! step_body "Post review as single PR comment" "$WF" | grep -vE "^[[:space:]]*#" | grep -cE "[> ]/tmp/[a-z_]+\.(txt|json|md)" >/dev/null' "post step keeps no scratch files in /tmp"
# Behavioural: the base64 key check catches printf, echo and wrapped encodings,
# and the key encoded inside a longer string at every byte alignment.
B64_FN=$(step_body "Post review as single PR comment" "$WF" | awk '!d && /^ +b64_key_in\(\) \{/{f=1} f && !d{print} f && !d && /^ +\}$/{d=1}' | sed 's/^          //')
b64_hit() { LLM_API_KEY="$1" bash -c "$B64_FN"$'\n''b64_key_in "$0"' "$2"; }
B64_TMP=$(mktemp -d); FAKE_KEY="sk-fake-$(printf 'a%.0s' {1..60})"
printf 'x %s y\n' "$(printf '%s' "$FAKE_KEY" | base64 -w0)" > "$B64_TMP/printf"
printf 'x %s y\n' "$(echo "$FAKE_KEY" | base64 -w0)" > "$B64_TMP/echo"
printf '%s\n' "$FAKE_KEY" | base64 -w 76 > "$B64_TMP/wrapped"
printf 'an ordinary review\n' > "$B64_TMP/clean"
for pfx in "K=" "KEY=" "LLM_KEY="; do
  printf 'x %s y\n' "$(printf 'HOME=/x\n%s%s\nPATH=/y\n' "$pfx" "$FAKE_KEY" | base64 -w0)" > "$B64_TMP/env-${#pfx}"
done
check '[[ -n "$B64_FN" ]] && b64_hit "$FAKE_KEY" "$B64_TMP/printf" && b64_hit "$FAKE_KEY" "$B64_TMP/echo" && b64_hit "$FAKE_KEY" "$B64_TMP/wrapped"' "post-step base64 check catches printf, echo and 76-column wrapped encodings"
check 'b64_hit "$FAKE_KEY" "$B64_TMP/env-2" && b64_hit "$FAKE_KEY" "$B64_TMP/env-4" && b64_hit "$FAKE_KEY" "$B64_TMP/env-8"' "post-step base64 check catches the key inside env | base64 output at all three alignments"
check '! b64_hit "$FAKE_KEY" "$B64_TMP/clean"' "post-step base64 check does not fire on a clean review"
rm -rf "$B64_TMP"
# Blocking: CODEX_HOME must not sit in a sandbox-writable root, or a model
# could edit config.toml (e.g. base_url) for the retry to load.
check '! grep -qE "CODEX_HOME: */tmp" "$CODEX"' "codex CODEX_HOME is not under /tmp (sandbox-writable)"
check '[[ $(grep -cE "^ +CODEX_HOME: \\$\\{\\{ runner\\.temp \\}\\}/codex-engine-home$" "$CODEX") -eq 3 ]]' "codex CODEX_HOME is runner.temp in all three steps"
check 'ncgrep "is inside a sandbox-writable root" "$CODEX"' "codex configure step refuses a CODEX_HOME inside a writable root"
check 'ncgrep "exclude_tmpdir_env_var = true" "$CODEX"' "codex sandbox excludes \$TMPDIR from writable roots"
check 'ncgrep "config_sha256=" "$CODEX" && ncgrep "config.toml changed since the configure step" "$CODEX"' "codex verifies the config hash before starting the CLI"
check 'step_body "Run AI PR review (Codex)" "$CODEX" | grep -vE "^[[:space:]]*#" | awk "/for attempt in 1 2/{f=1} f && /pre_attempt_guard\$/{n++} END{exit !n}"' "codex runs the pre-attempt guard inside the retry loop"
# Every setting that routes the key or relaxes the sandbox is pinned on the CLI.
for pin in "--sandbox workspace-write" "model=\\\"\${MODEL}\\\"" "model_provider=\"litellm\"" "model_providers.litellm.base_url=" "model_providers.litellm.env_key=" "model_providers.litellm.wire_api=" "approval_policy='\"never\"'" "sandbox_workspace_write.network_access=false" "sandbox_workspace_write.exclude_tmpdir_env_var=true" "tools.web_search=false"; do
  check 'grep -vE "^[[:space:]]*#" "$CODEX" | grep -cF -- "$pin" >/dev/null' "codex pins on the CLI: $pin"
done
# output_path is resolved before the /tmp check, and /var/tmp is not accepted.
check 'ncgrep "OUTPUT_REAL=\"\\$\\(realpath -m" "$CODEX"' "codex resolves output_path with realpath before checking it"
check '! step_body "Configure review CLI (Codex)" "$CODEX" | grep -cE "^ *[^#]*/var/tmp/\\*\\)" >/dev/null' "codex output_path guard no longer accepts /var/tmp"
check '! awk "/^  output_path:/{f=1;next} f && /^  [a-z_]+:/{exit} f" "$CODEX" | grep -cE "/tmp or /var/tmp|under temp" >/dev/null' "codex output_path input description matches the /tmp-only guard"
# Failure-path log dump reads only CODEX_HOME and blocks workflow commands.
check '! ncgrep "find \"\\\$CODEX_HOME\" /tmp" "$CODEX"' "codex log dump does not search the model-writable /tmp"
check 'ncgrep "::stop-commands::" "$CODEX"' "codex log dump is wrapped in ::stop-commands::"
# The shared prompt no longer tells every engine it has no shell.
check '! grep -q "You have no shell tool" "$WF"' "shared review procedure does not claim 'no shell tool' (false for codex)"
check '! grep -q "Exactly three edits" "$ROOT/.github/workflows/AI_PR_REVIEW_README.md"' "README 'Adding an engine' no longer claims exactly three edits"
# ---------------------------------------------------------------------------
# Muse engine — the fifth engine (Meta Muse Code). Same "adding an engine"
# contract, plus the controls that make a *read-only* toolset safe to run
# against LiteLLM: no shell/write tools at all (review = captured stdout),
# settings-pinned endpoint_transport + model_catalog, and a CLI pinned by
# version assertion because Meta ships no pinnable package.
# ---------------------------------------------------------------------------
check '[[ -f "$MUSE" ]]' "muse engine action.yml is committed"
check 'grep -qE "^            muse\)" "$WF"' "resolve step has a muse case arm"
check 'grep -qF "inputs.engine == '\''muse'\'' && '\''Muse PR Review'\''" "$WF"' "job name resolves muse to Muse PR Review"
check 'grep -q "DEFAULT_MODEL=\"meta-muse-wonder-1.0\"" "$WF"' "muse arm pins DEFAULT_MODEL=meta-muse-wonder-1.0"
check 'grep -q "METRICS_AGENT=\"muse_review\"" "$WF"' "muse arm pins METRICS_AGENT=muse_review"
check 'grep -q "ARTIFACT_PREFIX=\"muse-review\"" "$WF"' "muse arm pins ARTIFACT_PREFIX=muse-review"
check 'grep -q "DEFAULT_CLI_VERSION=\"1.4.13\"" "$WF"' "muse arm pins DEFAULT_CLI_VERSION=1.4.13"
check 'grep -q "if: steps.engine.outputs.engine == '\''muse'\''" "$WF"' "muse dispatch step is if-gated on the engine output"
check 'grep -q "ai_review_engine_muse@master" "$WF"' "muse dispatch references the engine by absolute @master path"
check 'awk '\''/if: steps.engine.outputs.engine == .muse./{g=1} g && /timeout-minutes: 60/{print; exit}'\'' "$WF" | grep -c "timeout-minutes: 60" >/dev/null' "muse dispatch step carries timeout-minutes: 60"
check 'grep -q "^      muse_reasoning_effort:" "$WF"' "muse_reasoning_effort input is declared"
check 'awk '\''/^      muse_reasoning_effort:/{f=1} f && /default:/{print; exit}'\'' "$WF" | grep -c "default: \"\"" >/dev/null' "muse_reasoning_effort defaults to empty"
check 'grep -qF "MUSE_REASONING_EFFORT_INPUT: \${{ inputs.muse_reasoning_effort }}" "$WF"' "resolve step reads muse_reasoning_effort from the workflow input"
check 'grep -q "echo \"muse_reasoning_effort=\$MUSE_REASONING_EFFORT\"" "$WF"' "resolve step emits muse_reasoning_effort on the step outputs"
check 'grep -q "muse_reasoning_effort: \${{ steps.engine.outputs.muse_reasoning_effort }}" "$WF"' "muse dispatch step passes muse_reasoning_effort through"
check 'grep -q "^  muse_reasoning_effort:" "$MUSE"' "muse engine declares the muse_reasoning_effort input"
check 'grep -qF "EFFORT_ARGS=(--reasoning-effort \"\$MUSE_REASONING_EFFORT\")" "$MUSE"' "muse engine maps muse_reasoning_effort onto --reasoning-effort"
check 'grep -qE "if \[\[ -n \"\\\$MUSE_REASONING_EFFORT\" \]\]" "$MUSE"' "muse engine applies muse_reasoning_effort only when non-empty"
check 'grep -qF "(default)'\'' high" "$WF"' "muse empty effort display is high (default)"
# Confinement: the dangerous relaxations must never appear as active flags.
check '! grep -vE "^[[:space:]]*#" "$MUSE" | grep -cE -- "--yolo|--disable-sandbox|--trust-workspace" >/dev/null' "muse engine never passes --yolo, --disable-sandbox or --trust-workspace"
check '! step_body "Run AI PR review (Muse Code)" "$MUSE" | grep -vE "^[[:space:]]*#" | grep -cE -- "--base-url" >/dev/null' "muse engine never routes via --base-url (the CLI withholds its key); settings endpoint_transport is the only route"
for flag in "--disable-shell" "--disable-write" "--disable-web-tools" "--disable-reminders" "--disable-approval" "--contributor-mode off" "--no-session-log" "--sandbox-network restricted" "--max-model-steps 200"; do
  check 'grep -vE "^[[:space:]]*#" "$MUSE" | grep -cF -- "$flag" >/dev/null' "muse engine passes $flag"
done
check 'grep -q "endpoint_transport: { base_url: \$base_url, auth: \"bearer\" }" "$MUSE"' "muse settings pin endpoint_transport with bearer auth"
check 'grep -q "model_catalog" "$MUSE" && grep -qF "profile_id: \"tbh\"" "$MUSE"' "muse settings register the LiteLLM alias in model_catalog (profile tbh)"
check 'grep -q "META_API_KEY: \${{ inputs.api_key }}" "$MUSE"' "muse run step maps api_key to META_API_KEY"
check '! step_body "Run AI PR review (Muse Code)" "$MUSE" | grep -cE "^ *(GITHUB_TOKEN|GH_TOKEN):" >/dev/null' "muse engine run step env holds no GitHub token"
check 'step_body "Run AI PR review (Muse Code)" "$MUSE" | grep -cE "^ +MUSE_NO_AUTO_UPDATE: \"1\"" >/dev/null' "muse run step freezes the launcher self-update"
check 'step_body "Install review CLI (Muse Code)" "$MUSE" | grep -cE "^ +MUSE_NO_AUTO_UPDATE: \"1\"" >/dev/null' "muse install step freezes the launcher self-update"
check 'grep -q "installer delivered Muse Code" "$MUSE" && grep -q "cli_version pins" "$MUSE"' "muse engine asserts the installed version equals cli_version"
check 'grep -q "no review written to \$OUTPUT_PATH" "$MUSE"' "muse engine fails if no review was written"
check 'ncgrep "strip script changed since the strip step" "$MUSE"' "muse verifies the strip script hash before each attempt"
check '! joined_step_body "Install review CLI (Muse Code)" "$MUSE" | grep -cE "rm .*[$][{]?MUSE_ENGINE_WORK[}]?([\";]|/[\";]|:[^\"]*[\";]| |$)" >/dev/null' "muse install step never rm's the strip script's directory (any single command, continuations joined)"
check 'grep -qF "`muse` (Meta Muse Code CLI)" "$WF"' "engine input description names muse"
check 'grep -qF "meta-muse-wonder-1.0" "$README" && grep -qF "muse_review" "$README" && grep -qF "muse-review-summary-" "$README"' "README documents the muse engine"
check 'grep -qE "^\| \`muse_reasoning_effort\`" "$README"' "README inputs table documents muse_reasoning_effort"

# The reasoning_effort, effort and thinking_effort enums are each duplicated
# on purpose (the engines can be called directly). Extract Codex arms by the
# `minimal|` prefix, Claude arms by the trailing `|max`, and Kimi arms as the
# exact `low|high|max` (do not key Kimi on a Codex/Claude-only token).
ENUM_WF=$(grep -vE '^[[:space:]]*#' "$WF" | grep -oE '^ +minimal\|[a-z|]*xhigh[a-z|]*\) ;;' | grep -v '|max' | tr -d ' ;)' | sort -u)
ENUM_CODEX=$(grep -vE '^[[:space:]]*#' "$CODEX" | grep -oE '^ +minimal\|[a-z|]*xhigh[a-z|]*\) ;;' | tr -d ' ;)' | sort -u)
check '[[ -n "$ENUM_WF" && "$ENUM_WF" == "$ENUM_CODEX" ]]' "reasoning_effort case arms match in the orchestrator and the engine ($ENUM_WF)"
ENUM_LIST="${ENUM_WF//|/, }"
check 'grep -qF -- "${ENUM_LIST%, *}" "$WF" && grep -qF -- "${ENUM_LIST%, *}" "$CODEX"' "reasoning_effort input descriptions list the same values as the case arms"
ENUM_WF_ANTH=$(grep -vE '^[[:space:]]*#' "$WF" | grep -oE '^ +low\|medium\|high\|xhigh\|max\) ;;' | tr -d ' ;)' | sort -u)
ENUM_ANTH=$(grep -vE '^[[:space:]]*#' "$ANTH" | grep -oE '^ +low\|medium\|high\|xhigh\|max\) ;;' | tr -d ' ;)' | sort -u)
check '[[ -n "$ENUM_WF_ANTH" && "$ENUM_WF_ANTH" == "$ENUM_ANTH" ]]' "effort case arms match in the orchestrator and the anthropic engine ($ENUM_WF_ANTH)"
ENUM_ANTH_LIST="${ENUM_WF_ANTH//|/, }"
check 'grep -qF -- "${ENUM_ANTH_LIST%, *}" "$WF" && grep -qF -- "${ENUM_ANTH_LIST%, *}" "$ANTH"' "effort input descriptions list the same values as the case arms"
ENUM_WF_MUSE=$(grep -vE '^[[:space:]]*#' "$WF" | grep -oE '^ +minimal\|low\|medium\|high\|xhigh\|max\) ;;' | tr -d ' ;)' | sort -u)
ENUM_MUSE=$(grep -vE '^[[:space:]]*#' "$MUSE" | grep -oE '^ +minimal\|low\|medium\|high\|xhigh\|max\) ;;' | tr -d ' ;)' | sort -u)
check '[[ -n "$ENUM_WF_MUSE" && "$ENUM_WF_MUSE" == "$ENUM_MUSE" ]]' "muse_reasoning_effort case arms match in the orchestrator and the engine ($ENUM_WF_MUSE)"
ENUM_MUSE_LIST="${ENUM_WF_MUSE//|/, }"
check 'grep -qF -- "${ENUM_MUSE_LIST%, *}" "$WF" && grep -qF -- "${ENUM_MUSE_LIST%, *}" "$MUSE"' "muse_reasoning_effort input descriptions list the same values as the case arms"
ENUM_WF_KIMI=$(grep -vE '^[[:space:]]*#' "$WF" | grep -oE '^ +low\|high\|max\) ;;' | tr -d ' ;)' | sort -u)
ENUM_KIMI=$(grep -vE '^[[:space:]]*#' "$KIMI" | grep -oE '^ +low\|high\|max\) ;;' | tr -d ' ;)' | sort -u)
check '[[ -n "$ENUM_WF_KIMI" && "$ENUM_WF_KIMI" == "$ENUM_KIMI" ]]' "thinking_effort case arms match in the orchestrator and the kimi engine ($ENUM_WF_KIMI)"
check 'grep -qF "low, high, or max" "$WF" && grep -qF "low, high, or max" "$KIMI" && grep -qF "low, high, or max" "$README"' "thinking_effort input descriptions list the same values as the case arms"
# Every other copy (descriptions, error messages, comments, README) sits on a
# line that names xhigh. Case-arm lines are already locked by the extractors
# above. Remaining xhigh lines are classified as Codex or Claude so the two
# enums cannot demand each other's values. Kimi prose must not name that
# token — a reject-list sentence would land unclassified here.
is_case_arm() { [[ "$1" =~ \)[[:space:]]*\;\;[[:space:]]*$ ]]; }
is_codex_effort_line() {
  [[ "$1" =~ reasoning_effort ]] || [[ "$1" =~ model_reasoning_effort ]] || [[ "$1" =~ Codex\ CLI ]] || [[ "$1" =~ (^|[^a-z])minimal([^a-z]|$) ]]
}
is_claude_effort_line() {
  [[ "$1" =~ --effort ]] || [[ "$1" =~ output_config ]] || [[ "$1" =~ engine-specific:\ anthropic ]] || [[ "$1" =~ Anthropic\ engine:\ effort ]] || [[ "$1" =~ Invalid\ effort ]] || [[ "$1" =~ \*\*\[anthropic\]\*\* ]]
}
is_muse_effort_line() {
  [[ "$1" =~ muse_reasoning_effort ]] || [[ "$1" =~ --reasoning-effort ]] || [[ "$1" =~ MUSE_REASONING_EFFORT ]] || [[ "$1" =~ engine-specific:\ muse ]] || [[ "$1" =~ Muse\ engine:\ muse_reasoning_effort ]] || [[ "$1" =~ \*\*\[muse\]\*\* ]] || [[ "$1" =~ Muse\ Code\ default ]] || [[ "$1" =~ Invalid\ muse_reasoning_effort ]]
}
enum_prose_ok() {
  local f line v enum
  for f in "$WF" "$CODEX" "$ANTH" "$MUSE" "$README"; do
    while IFS= read -r line; do
      is_case_arm "$line" && continue
      if is_muse_effort_line "$line"; then
        enum="$ENUM_WF_MUSE"
      elif is_codex_effort_line "$line"; then
        enum="$ENUM_WF"
      elif is_claude_effort_line "$line"; then
        enum="$ENUM_WF_ANTH"
      else
        echo "  unclassified xhigh line in $(basename "$f"): ${line:0:120}"
        return 1
      fi
      for v in ${enum//|/ }; do
        [[ "$line" =~ (^|[^a-z])$v([^a-z]|$) ]] || { echo "  missing '$v' in $(basename "$f"): ${line:0:100}"; return 1; }
      done
    done < <(grep -E '(^|[^a-z])xhigh([^a-z]|$)' "$f")
  done
}
check 'enum_prose_ok' "every reasoning_effort or effort description, error and doc line lists all of its case-arm values"
# Behavioural: run each engine's own validation block against good and bad values.
EFFORT_BLOCK=$(step_body "Run AI PR review (Codex)" "$CODEX" | awk '/REASONING_ARGS=\(\)/{f=1} f{print} f && /^ +fi$/{f=0; done=1} done{next}' | sed 's/^        //')
effort_ok() { REASONING_EFFORT="$1" bash -c "$EFFORT_BLOCK" >/dev/null 2>&1; }
check 'effort_ok "" && effort_ok xhigh && effort_ok minimal' "codex engine accepts empty, minimal and xhigh"
check '! effort_ok max && ! effort_ok ultra && ! effort_ok bogus' "codex engine rejects max, ultra and unknown values"
CLAUDE_EFFORT_BLOCK=$(step_body "Resolve effort override" "$ANTH" | awk '/FLAG=""/ {f=1} f{print} f && /^ +fi$/{f=0; done=1} done{next}' | sed 's/^        //')
claude_effort_ok() { EFFORT="$1" bash -c "$CLAUDE_EFFORT_BLOCK" >/dev/null 2>&1; }
check 'claude_effort_ok "" && claude_effort_ok low && claude_effort_ok max' "anthropic engine accepts empty, low and max"
check '! claude_effort_ok minimal && ! claude_effort_ok ultracode && ! claude_effort_ok bogus' "anthropic engine rejects minimal, ultracode and unknown values"
KIMI_THINKING_BLOCK=$(step_body "Run AI PR review (Kimi Code)" "$KIMI" | awk '/thinking_effort is dual-validated here/{f=1} f{print} f && /^ +fi$/{f=0; done=1} done{next}' | sed 's/^        //')
kimi_thinking_ok() { THINKING_EFFORT="$1" bash -c "$KIMI_THINKING_BLOCK" >/dev/null 2>&1; }
MUSE_EFFORT_BLOCK=$(step_body "Run AI PR review (Muse Code)" "$MUSE" | awk '/EFFORT_ARGS=\(\)/{f=1} f{print} f && /^ +fi$/{f=0; done=1} done{next}' | sed 's/^        //')
muse_effort_ok() { MUSE_REASONING_EFFORT="$1" bash -c "$MUSE_EFFORT_BLOCK" >/dev/null 2>&1; }
check 'muse_effort_ok "" && muse_effort_ok minimal && muse_effort_ok max' "muse engine accepts empty, minimal and max"
check '! muse_effort_ok none && ! muse_effort_ok ultra && ! muse_effort_ok bogus' "muse engine rejects none, ultra and unknown values"
# The orchestrator's copy of the same validation must behave identically,
# not just grep-match: run it too.
WF_MUSE_BLOCK=$(step_body "Resolve and validate engine" "$WF" | awk '/MUSE_REASONING_EFFORT="\$\{MUSE_REASONING_EFFORT_INPUT:-\}"/{f=1} f{print} f && /^ +fi$/{f=0; done=1} done{next}' | sed 's/^ *//')
wf_muse_effort_ok() { MUSE_REASONING_EFFORT_INPUT="$1" bash -c "$WF_MUSE_BLOCK" >/dev/null 2>&1; }
check 'wf_muse_effort_ok "" && wf_muse_effort_ok minimal && wf_muse_effort_ok max' "orchestrator muse validation accepts empty, minimal and max"
check '! wf_muse_effort_ok none && ! wf_muse_effort_ok ultra && ! wf_muse_effort_ok bogus' "orchestrator muse validation rejects none, ultra and unknown values"
# The strip script only exists as a heredoc until a live run writes it;
# prove the extracted body at least parses.
check 'awk "/cat > \"\\\$STRIP_SCRIPT\" <<.STRIP_EOF./{f=1;next} f && /^ *STRIP_EOF/{exit} f" "$MUSE" | sed "s/^ *//" | bash -n' "muse strip script heredoc parses as bash"
# Installer: never piped into bash, HTTPS-pinned, hash logged.
check '! grep -vE "^[[:space:]]*#" "$MUSE" | grep -cF "install.sh |" >/dev/null' "muse installer is never piped into bash"
check 'grep -qF -- "--proto '\''=https'\''" "$MUSE" && grep -q "Muse Code installer sha256" "$MUSE"' "muse installer fetch pins HTTPS and logs the script hash"
check 'joined_step_body "Install review CLI (Muse Code)" "$MUSE" | grep -F "bash \"\$INSTALLER\"" | grep -cF "HOME=\"\$MUSE_ENGINE_HOME\" XDG_CONFIG_HOME=\"\$MUSE_ENGINE_HOME/.config\"" >/dev/null' "muse installer invocation runs with the isolated HOME/XDG, not the runner's real home"
check 'grep -qF "MUSE_INSTALLER_DIR: \${{ runner.temp }}/muse-engine-installer" "$MUSE" && grep -qF "INSTALLER=\"\$MUSE_INSTALLER_DIR/install.sh\"" "$MUSE" && joined_step_body "Install review CLI (Muse Code)" "$MUSE" | grep -F "rm -rf" | grep -cF "\"\$MUSE_INSTALLER_DIR\"" >/dev/null' "muse installer script lives in its own wiped directory, not the install dir"
check 'kimi_thinking_ok "" && kimi_thinking_ok low && kimi_thinking_ok max' "kimi engine accepts empty, low and max"
check '! kimi_thinking_ok medium && ! kimi_thinking_ok xhigh && ! kimi_thinking_ok bogus' "kimi engine rejects medium, xhigh and unknown values"

# Ako round 3 nits.
check 'nc_fixed "base_url_re='"'"'^https?://" && nc_fixed "[[ ! \$BASE_URL =~ \$base_url_re ]]"' "codex base_url check uses a quoted pattern variable (no bracket escapes)"
check 'nc_fixed "MODEL: \${{ steps.configure.outputs.model }}" && nc_fixed "echo \"model=\$MODEL\""' "codex run step uses the model value the configure step validated"
check '! step_body "Run AI PR review (Codex)" "$CODEX" | grep -vE "^[[:space:]]*#" | grep -cF "inputs.model" >/dev/null' "codex run step never reads raw inputs.model"
check 'nc_fixed "setsid --wait codex exec" && nc_fixed "pkill -KILL -s \"\$CODEX_PID\""' "codex exec runs in its own session, killed before commands resume"
# Smoke test: Codex 0.160.0 only WARNS on an unknown config key and runs on,
# so a misspelled control would be silently off. The warning must be fatal.
check 'nc_fixed "grep -cF \"unrecognized configuration setting\" \"\$CLI_LOG\"" && ncgrep "the CLI ignored a config setting" "$CODEX"' "codex refuses the review when the CLI ignored a config setting"
check 'nc_fixed "\"\$REVIEW_PROMPT\" > \"\$CLI_LOG\" 2>&1 < /dev/null &" && nc_fixed "CLI_LOG: \${{ runner.temp }}/"' "codex CLI output goes to a runner.temp log, not the live step log"

# 4. The path guard: the only path control either CLI honours. Shared by the
#    Kimi and Anthropic engines, fail-closed by construction.
check '[[ -f "$GUARD" ]]' "path guard script is committed"
check '[[ -f "$GUARD_TEST" ]]' "path guard has a node --test file (run by lint-actions test-scripts)"
check 'node --check "$GUARD"' "path guard parses"
check '! grep -oE "require\(['\''\"][^'\''\"]+" "$GUARD" | grep -v "node:" | grep -c . >/dev/null' "path guard requires only node: builtins"
check 'grep -q "is not permitted in this review" "$GUARD"' "path guard denies any tool it does not know"
check 'grep -q "a \`path\` argument is required" "$GUARD"' "path guard denies Read/Write without a path instead of waving them through"
check 'grep -q "file_path" "$GUARD"' "path guard accepts Claude Code's file_path argument"
check 'grep -q "PATH_GUARD_LOG" "$GUARD"' "path guard writes the decision log the engines verify"
# Kimi wiring
check 'grep -q "cp \"\$ACTION_PATH/../ai_review_path_guard/path-guard.js\" \"\$HOME/.kimi-code/path-guard.js\"" "$KIMI"' "Kimi configure step installs the committed guard"
check 'grep -q "ACTION_PATH: \${{ github.action_path }}" "$KIMI"' "Kimi configure step resolves the action path"
check 'grep -q "^        event = \"PreToolUse\"" "$KIMI"' "Kimi guard is registered as a PreToolUse hook"
check 'grep -qF "matcher = \".*\"" "$KIMI"' "Kimi hook matcher is match-all (a renamed tool cannot slip past it)"
check 'grep -qF "enabled = [\"Read\", \"Write\", \"Grep\", \"Glob\"]" "$KIMI"' "Kimi tool surface has no Bash"
check 'grep -qF "/.kimi-code/path-guard.js'\'' || exit 2\"" "$KIMI"' "Kimi hook command maps any failure onto the deny code"
check 'grep -q "^        timeout = 600" "$KIMI"' "Kimi hook timeout is the schema maximum"
check 'grep -q "node --check \"\$HOME/.kimi-code/path-guard.js\"" "$KIMI"' "Kimi guard is syntax-checked before the run step"
check 'grep -q "kimi doctor config" "$KIMI" && grep -q "salvageConfigData" "$KIMI"' "Kimi action runs kimi doctor config and documents why it is load-bearing"
check 'grep -q "not applied in \`-p\` mode\|not apply \`\[\[permission.rules\]\]\`\|are not applied" "$KIMI" || grep -qi "permission.rules.*not" "$KIMI"' "Kimi action documents that permission.rules are not enforcement"
check 'step_body "Run AI PR review (Kimi Code)" "$KIMI" | grep -c "PATH_GUARD_LOG: \${{ runner.temp }}/" >/dev/null && step_body "Run AI PR review (Kimi Code)" "$KIMI" | grep -c "\[\[ ! -s \"\$PATH_GUARD_LOG\" \]\]" >/dev/null' "Kimi run step fails if a review was written without the guard ever running"
# Anthropic wiring
check 'awk '\''/- name: Install path guard \(Claude Code\)/{i=NR} /uses: anthropics\/claude-code-action@/{a=NR} /- name: Verify the sandbox held/{v=NR} END{exit !(i && a && v && i<a && a<v)}'\'' "$ANTH"' "Anthropic: guard install runs before claude-code-action, sandbox verification after"
ANTH_INSTALL="$(step_body "Install path guard (Claude Code)" "$ANTH")"
check 'grep -q "cp \"\$ACTION_PATH/../ai_review_path_guard/path-guard.js\"" <<< "$ANTH_INSTALL" && grep -q "node --check" <<< "$ANTH_INSTALL"' "Anthropic: installs and syntax-checks the shared guard outside the checkout"
# The pinned action's restoreConfigFromBase runs `git fetch origin <base>` on
# every PR event with no try/catch; removing the remote fails the run before
# the model starts (it took out every engine: anthropic review in a consumer).
check '! grep -q "git remote remove origin" "$ANTH" && ! grep -q "git remote rm origin" "$ANTH"' "Anthropic: the origin remote is NOT removed (the action's base-branch restore fetches through it)"
check 'grep -q "git remote get-url origin" <<< "$ANTH_INSTALL" && grep -q "x-access-token" <<< "$ANTH_INSTALL"' "Anthropic: install step asserts origin exists and .git/config is credential-free going in"
ANTH_RUN="$(step_body "Claude Code PR review" "$ANTH")"
check 'grep -q "uses: anthropics/claude-code-action@5eb090f3c3afd701a0672cd32981197ca27688f6" "$ANTH"' "Anthropic: claude-code-action pinned to v1.0.253 SHA (CLI 2.1.303)"
check 'grep -qE "^        allowed_bots: gh-app-write[[:space:]]*$" <<< "$ANTH_RUN"' "Anthropic: claude-code-action allowlists gh-app-write (Forge); GLM/DeepSeek use this engine"
check '! grep -qE "^        allowed_bots: ['\''\"]?\\*" <<< "$ANTH_RUN"' "Anthropic: allowed_bots is not a wildcard (Dependabot must stay out)"
check 'grep -q "^        use_commit_signing: true" <<< "$ANTH_RUN"' "Anthropic: commit-signing mode still set (skips configureGitAuth user/email; file-ops stays denied)"
check 'grep -q "^        allowed_non_write_users: \"_never\"" <<< "$ANTH_RUN"' "Anthropic: allowed_non_write_users is _never so origin stays token-free"
check '! grep -qE "^        allowed_non_write_users: ['\''\"]?\\*" <<< "$ANTH_RUN"' "Anthropic: allowed_non_write_users is not a wildcard"
check 'grep -q "^        GIT_CONFIG_COUNT: \"1\"" <<< "$ANTH_RUN" && grep -q "^        GIT_CONFIG_KEY_0: credential.helper" <<< "$ANTH_RUN" && grep -q "^        GIT_CONFIG_VALUE_0: .*GITHUB_TOKEN" <<< "$ANTH_RUN"' "Anthropic: the action's base-branch fetch authenticates from env-only git config, never .git/config"
check 'grep -q "mcp__github_file_ops" <<< "$ANTH_RUN"' "Anthropic: the file-ops MCP server that commit-signing mode mounts is denied by name"
check 'grep -q "\"PreToolUse\"" <<< "$ANTH_RUN" && grep -q "\"matcher\": \".\*\"" <<< "$ANTH_RUN"' "Anthropic: settings registers a match-all PreToolUse hook"
check 'grep -qF "/ai-review-path-guard/path-guard.js'\'' || exit 2\"" <<< "$ANTH_RUN"' "Anthropic: hook command maps any failure onto the deny code"
check 'grep -q "^        OUTPUT_PATH: \${{ inputs.output_path }}" <<< "$ANTH_RUN" && grep -q "^        PATH_GUARD_LOG: \${{ runner.temp }}/ai-review-path-guard/decisions.log" <<< "$ANTH_RUN"' "Anthropic: guard receives OUTPUT_PATH and the decision log path through the step env"
check 'grep -q -- "--setting-sources user" <<< "$ANTH_RUN"' "Anthropic: only the user settings file the action writes is loaded, never the checkout's"
check 'grep -q -- "--disallowedTools \"Bash," <<< "$ANTH_RUN"' "Anthropic: Bash stays disallowed"
ANTH_VERIFY="$(step_body "Verify the sandbox held and the review was written" "$ANTH")"
check 'grep -q "x-access-token" <<< "$ANTH_VERIFY" && grep -q "\.git/config" <<< "$ANTH_VERIFY"' "Anthropic: verify step re-reads .git/config for credentials after the model ran"
check 'grep -q "_actions/anthropics/claude-code-action" <<< "$ANTH_VERIFY"' "Anthropic: verify allows only the pinned action's helper under _actions/"
check 'grep -q "\[\[ ! -s \"\$PATH_GUARD_LOG\" \]\]" <<< "$ANTH_VERIFY"' "Anthropic: verify step fails if a review was written without the guard ever running"
check 'grep -q "^        PATH_GUARD_LOG: \${{ runner.temp }}/ai-review-path-guard/decisions.log" <<< "$ANTH_VERIFY"' "Anthropic: verify step reads the same decision log the hook writes"

# 5. Nothing executed after the engine comes from a path an engine can write.
check '! grep -qE "^[[:space:]]*(jq -f|source|\.|bash|sh|node) .*/tmp/[^ ]*\.(jq|sh|js)([[:space:]]|$)" "$WF"' "no step executes a program stored under /tmp (an engine-writable location)"
check '! grep -q "review_marker_filter" "$WF"' "the reap filter is no longer a /tmp file"
check 'grep -q "^      REVIEW_MARKER_FILTER: |" "$WF"' "the reap filter is job-level env"
check '[[ "$(grep -c "jq \"\$REVIEW_MARKER_FILTER\"" "$WF")" -eq 2 ]]' "capture and post steps both apply the env-held filter (same program, no intermediate file)"

# 6. The post step refuses to publish credentials — and does not refuse
#    reviews that merely talk about credential plumbing.
TOKEN_RE="$(sed -n "s/^ *token_shapes_re='\([^']*\)'.*/\1/p" "$WF" | awk 'NR==1')"
CRED_RE="$(sed -n "s/^ *cred_shapes_re='\([^']*\)'.*/\1/p" "$WF" | awk 'NR==1')"
check '[[ -n "$TOKEN_RE" && -n "$CRED_RE" ]]' "exfiltration guard regexes are parseable"
check 'grep -q "grep -oE \"\$token_shapes_re\"" "$WF"' "post step applies the token-shape regex"
check 'grep -q "grep -oiE \"\$cred_shapes_re\"" "$WF"' "post step applies the credential-shape regex case-insensitively"
check 'grep -q "grep -qF -- \"\$GH_TOKEN\"" "$WF"' "post step refuses the literal job token"
check '! grep -q "grep -qF -- \"\$GITHUB_TOKEN\"" "$WF"' "post step has no dead GITHUB_TOKEN branch (GH_TOKEN is the job token; it is not in that step's env)"
check 'grep -q "grep -qF -- \"\$LLM_API_KEY\"" "$WF"' "post step still refuses the literal LLM API key"
tok() { grep -qE "$TOKEN_RE" <<< "$1"; }
cred() { grep -qiE "$CRED_RE" <<< "$1"; }
# Token fixtures are split the same way (prefix and body on separate words).
TOKEN_BODY="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
check 'tok "leaked ghp_${TOKEN_BODY} here"' "token regex: classic ghp_ token"
check 'tok "ghs_${TOKEN_BODY}"' "token regex: ghs_ installation token"
check 'tok "github_pat_${TOKEN_BODY}_0123"' "token regex: fine-grained PAT"
check 'tok "url = https://x-access-token:ghs_${TOKEN_BODY}@github.com/o/r.git"' "token regex: the plaintext remote URL claude-code-action writes"
check '! tok "ghp_short and github_pat_ alone"' "token regex: ignores bare prefixes"
# Fixtures mirror what actions/checkout v6 writes (src/git-auth-helper.ts) but
# are assembled from fragments, so a review that quotes THIS file does not
# itself trip the guard — the same reason lint-actions builds its expression
# delimiter from bytes.
B64="eC1hY2Nlc3Mt""dG9rZW46Z2hzX0ZBS0VUT0tFTkZBS0U="
CRED_LINE=$'\t'"extraheader = ""AUTHORIZATION: basic $B64"
INCLUDE_LINE="[includeIf \"""gitdir:/home/runner/work/repo/repo/.git\"]"
PATH_LINE=$'\t'"path = /home/runner/work/_temp/git-credentials-""0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b.config"
URL_LINE="url = https://x-access-token"":v1.${TOKEN_BODY}@github.com/o/r.git"
check 'cred "$CRED_LINE"' "cred regex: the credentials file's extraheader line"
check 'cred "$INCLUDE_LINE"' "cred regex: the .git/config includeIf section"
check 'cred "$PATH_LINE"' "cred regex: the credentials file name"
check 'cred "$B64"' "cred regex: bare base64 of x-access-token: plus token"
check 'cred "$URL_LINE"' "cred regex: an x-access-token remote URL carrying a token of any shape"
check '! cred "the includeIf directive and the extraheader key are documented in git-config(1)"' "cred regex: prose about the plumbing still posts"
check '! cred "uses Authorization: Basic auth against the proxy, see extraheader"' "cred regex: Authorization: Basic without a credential blob still posts"
check '! cred "claude-code-action rewrites origin to https://x-access-token:<token>@github.com/owner/repo.git"' "cred regex: prose naming the x-access-token URL shape without a token still posts"
check '! cred "grep -qiE '\''authorization: *basic|extraheader|git-credentials|includeIf'\''"' "cred regex: a quoted bare-word guard (the old one) still posts"
check '! grep -rqiE "$CRED_RE" "$ROOT/.github" "$ROOT/tests"' "cred regex: nothing in this repo's own text trips it, so reviews of this repo can post"
check '! grep -rqE "$TOKEN_RE" "$ROOT/.github" "$ROOT/tests"' "token regex: nothing in this repo's own text trips it"

# 7. README keeps the why, so nobody simplifies the controls away.
check 'grep -q "ai_review_path_guard/path-guard.js" "$README"' "README names the shared path guard"
check 'grep -q "type l" "$README"' "README explains why the scrubs match symlinks"
check 'grep -q "persist-credentials: false" "$README"' "README documents the credential-free checkout"
check 'grep -qi "fork" "$README"' "README documents the fork skip"
check 'grep -q "use_commit_signing" "$README" && grep -q "restoreConfigFromBase" "$README" && grep -q "_never" "$README"' "README documents restoreConfigFromBase, commit-signing, and _never"
check '! grep -q "the one prepare branch that never rewrites origin" "$README" && ! grep -q "the one prepare branch that skips that" "$README"' "README does not claim signing alone skips origin rewrite"
check 'grep -q "REVIEW_MARKER_FILTER" "$README"' "README documents why the reap filter is env, not a file"
check 'grep -q "120000" "$README"' "README documents the tree-based symlink check"

# The review prompt lives in-repo. The procedure must not tell the model to
# read every dependency, which overrides the prompt because it is appended last.
PROMPT="$ROOT/.github/prompts/ai-pr-review.md"
check '[[ -f "$PROMPT" ]]' "review prompt file exists"
check 'grep -q "If that text contradicts the code in the same diff, or two parts of it contradict each other, that is a Change." "$PROMPT"' "prompt treats a spec contradiction in the diff as a Change"
check 'grep -q "{{AUTO_FIX_URL}}" "$PROMPT"' "prompt leaves the Click2Fix placeholder"
check 'grep -q "Under 500 words." "$PROMPT"' "prompt caps the review at 500 words"
# grep -q must not be the reader on a pipe. The workflow is larger than a
# pipe buffer, so an early exit SIGPIPEs the writer and pipefail fails the check.
WF_CODE="$(grep -vE '^[[:space:]]*#' "$WF")"
# The fetch-step labels must be satisfied by that step, not by another copy
# of the same command elsewhere in the workflow.
FETCH_BODY="$(step_body "Fetch prompt template" "$WF" | grep -vE '^[[:space:]]*#')"
check 'grep -qF "printf '\''%s'\'' \"\$PROMPT_B64\" | base64 -d > /tmp/prompt_template.txt" <<< "$FETCH_BODY"' "fetch step decodes the inlined prompt"
check 'grep -qF "curl -sfL \"\$PROMPT_GIST_URL\"" <<< "$FETCH_BODY"' "override still fetches prompt_gist_url"
check 'sed -n "s/^          PROMPT_B64: //p" "$WF" | tr -d "[:space:]" | python3 -c "import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read()))" | cmp -s - "$PROMPT"' "inlined prompt matches .github/prompts/ai-pr-review.md"
check 'grep -qF "When there are no findings, omit Findings and Auto Fix. On a follow-up, still write Previous issues." "$PROMPT"' "prompt keeps Previous issues when there are no findings"
check 'grep -qF "List each Spec Change under Findings as well, marked Change." "$PROMPT"' "a Spec Change is also listed under Findings"
check '! grep -q "Do not begin with a heading" "$WF"' "output rule does not forbid the Summary heading"
check 'grep -q "Start with the Summary section." <<< "$WF_CODE"' "output rule tells the model to start with Summary"
check '! grep -q "Read its dependencies" "$WF"' "procedure does not tell the model to read every dependency"
check 'grep -q "A contradiction between them is a Change under Spec." <<< "$WF_CODE"' "procedure files a spec contradiction under Spec"
check 'grep -q "Do not read further for that assumption." <<< "$WF_CODE"' "procedure stops extra reading at one assumption"
check '! grep -q "it was not touched" "$WF"' "incremental diff does not treat an absent pattern as untouched"
check 'grep -q ".github/prompts/ai-pr-review.md" "$README"' "README documents the in-repo prompt"
check '! grep -q "edit the gist" "$README"' "README no longer tells people to edit the gist"

if [[ "$fail" -ne 0 ]]; then
  echo "contract checks failed"
  exit 1
fi
echo "all contract checks passed"
