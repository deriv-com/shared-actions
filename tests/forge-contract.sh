#!/usr/bin/env bash
# tests/forge-contract.sh
#
# Guards the caller-facing contract of .github/workflows/forge.yml. Callers live
# in other repositories, so a rename here breaks them at run time with no local
# signal — actionlint validates syntax but knows nothing about which input names
# downstream repos depend on.
#
# It also pins the two invariants the workflow's own comments promise but that
# nothing else enforces: the engine ref is never a branch (a range or tag
# resolves against vX.Y.Z tags; a SHA is used as-is), and no caller-relative `uses: ./` creeps in (such a path resolves
# against the CALLER, so it would work in one repo and break in every other).
# The resolver's behaviour itself is exercised by tests/forge-resolver.sh.
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

WF="$ROOT/.github/workflows/forge.yml"

check '[[ -f "$WF" ]]' "forge.yml exists"

# --- it must stay a reusable workflow -------------------------------------
check 'grep -q "^  workflow_call:" "$WF"' "declared as workflow_call"
check '! grep -qE "^  (issues|pull_request|push|schedule):" "$WF"' \
  "no direct triggers — callers own those"

# --- inputs callers pass by name ------------------------------------------
for input in issue_number slack_channel slack_thread_ts requested_by \
             analysis_brief command \
             node_version install_command model runner_group engine_ref \
             fast_lane timeout_minutes; do
  check "grep -q '^      ${input}:' \"\$WF\"" "input '${input}' is declared"
done

check 'awk "/^      issue_number:/{f=1} f && /required:/{print; exit}" "$WF" | grep -q "required: true"' \
  "issue_number stays required"
check 'awk "/^      analysis_brief:/{f=1} f && /required:/{print; exit}" "$WF" | grep -q "required: false"' \
  "input 'analysis_brief' stays optional"
check 'awk "/^      command:/{f=1} f && /required:/{print; exit}" "$WF" | grep -q "required: false"' \
  "input 'command' stays optional"
check 'awk "/^      command:/{f=1} f && /default:/{print; exit}" "$WF" | grep -q "default: \"auto\""' \
  "input 'command' defaults to auto"

# The lane decides whether a run fits inside timeout_minutes, so it must stay a
# caller decision. Hardcoding --fast onto the command line would silently strip
# the planner and reviewer from a caller that asked for the full pipeline.
check '! grep -qE "auto .*--fast" "$WF"' \
  "--fast is not hardcoded onto the auto invocation"
check 'grep -q "ARGS+=(--fast)" "$WF"' \
  "--fast is appended conditionally, from the fast_lane input"

# --- secrets callers must forward -----------------------------------------
for secret in CLIENT_ID_GHAPP_WRITE PRIVATE_KEY_GHAPP_WRITE \
              CLIENT_ID_GHAPP PRIVATE_KEY_GHAPP FORGE_API_KEY; do
  check "grep -q '^      ${secret}:' \"\$WF\"" "secret '${secret}' is declared"
  check "awk '/^      ${secret}:/{f=1} f && /required:/{print; exit}' \"\$WF\" | grep -q 'required: true'" \
    "secret '${secret}' stays required"
done

# Optional by design: a missing Slack token degrades to a warning, the
# gateway URL falls back to the deriv default, and DSTP_FORGE_SERVICE_KEY
# stays optional so existing callers do not 422 before they pass it. dstp
# 0.8.0 still refuses to start in Actions without the key.
for secret in FORGE_SLACK_BOT_TOKEN LITELLM_API_URL DSTP_FORGE_SERVICE_KEY; do
  check "grep -q '^      ${secret}:' \"\$WF\"" "secret '${secret}' is declared"
  check "awk '/^      ${secret}:/{f=1} f && /required:/{print; exit}' \"\$WF\" | grep -q 'required: false'" \
    "secret '${secret}' stays optional"
done

# Scoped to the Run Forge step. The empty-key guard also assigns
# secrets.DSTP_FORGE_SERVICE_KEY, so a file-wide grep would still pass if
# the env were dropped from the dstp invocation.
check 'awk "
  \$0 ~ /name: Run Forge/ {f=1}
  f && /DSTP_FORGE_TRIGGER: forge_ci/ {t=1}
  f && /secrets.DSTP_FORGE_SERVICE_KEY/ {k=1}
  f && /^      - name:/ && \$0 !~ /Run Forge/ {exit}
  END {exit (t && k) ? 0 : 1}
" "$WF"' \
  "Run Forge sets DSTP_FORGE_TRIGGER=forge_ci and the CI service key"
check '! grep -q "DSTP_FORGE_API_URL:" "$WF"' \
  "DSTP_FORGE_API_URL is unset — dstp 0.8.0 refuses any override"
check 'grep -q "DSTP_FORGE_SERVICE_KEY is empty" "$WF"' \
  "empty CI service key fails before dstp starts"
check 'awk "
  /name: Claim the issue/ {c=NR}
  /name: Require the Forge CI service key/ {r=NR}
  END {exit (c && r && r>c) ? 0 : 1}
" "$WF"' \
  "empty-key guard runs after claim so Report can post and free the forge label"
check 'grep -q "s/fk_\[A-Za-z0-9_-\]{20,}/\*\*\*/g" "$WF"' \
  "failure-log scrub covers Forge CI keys (fk_)"

# --- portability ----------------------------------------------------------
# A relative `uses:` inside a reusable workflow resolves against the caller, so
# any caller-local composite action makes this workflow non-portable.
# Matches both `uses: ./` and the list-item form `- uses: ./`. The leading `#`
# of a comment cannot match, so the header's prose about this rule is safe.
check '! grep -qE "^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*\./" "$WF"' \
  "no caller-relative 'uses: ./' — toolchain stays parameterised"

check 'grep -q "install_command" "$WF"' \
  "dependency install is still an input, not a hardcoded action"

# --- supply chain ---------------------------------------------------------
# The engine runs with a write token in scope, so tracking a branch would let
# any push to spec-to-pr execute in every caller repo. The default may be a caret
# range (resolved against vX.Y.Z tags only) or a 40-char SHA (which bypasses the
# tag list entirely). Anchored: the whole quoted value must be one of the two.
check 'awk "/^      engine_ref:/{f=1} f && /default:/{print; exit}" "$WF" | grep -qE "^ +default: \"(\^[0-9]+\.[0-9]+\.[0-9]+|[0-9a-f]{40})\"$"' \
  "engine_ref default is exactly a caret range or a full 40-char SHA, not a branch"
check 'grep -q "Branches are not accepted" "$WF"' \
  "engine_ref resolver rejects anything that is not a range, release tag or SHA"

# Every third-party action pinned by SHA (the repo-wide rule this workflow must
# not be an exception to).
check '! grep -nE "^\s+uses: [a-zA-Z0-9_.-]+/[^@]+@(v?[0-9]+(\.[0-9]+)*|main|master)\s*$" "$WF"' \
  "all actions pinned by commit SHA"

# --- guards the workflow's own comments claim ------------------------------
check 'grep -q "gh label create" "$WF"' \
  "labels are created idempotently so a new caller repo needs no manual setup"

check 'grep -qE "ISSUE_NUMBER\" =~ \^\[0-9\]\+\\$" "$WF"' \
  "issue_number is validated as numeric before any API call"

check 'grep -q "s/sk-\[A-Za-z0-9_-\]{20,}/\*\*\*/g" "$WF"' \
  "failure-log scrub covers gateway keys (sk-), not only sk-ant-"

check 'grep -q "xox\[abposr\]-" "$WF"' \
  "failure-log scrub covers Slack tokens"

check 'grep -q -- "--max-time" "$WF"' \
  "the Slack call is time-bounded"

# --- revise loop: N AI reviews, no leaked prompt, no --fast, AI reply -----
check 'grep -q "run_branch_revise" "$WF"' \
  "review loop uses branch-form dstp revise"
check 'grep -q "reply_to_reviews" "$WF"' \
  "a second claude pass replies to AI reviews after revise"
check 'grep -q '\''"$CLAUDE_BIN" -p --output-format text'\'' "$WF"' \
  "review reply uses the same claude binary as the engine"
check '! awk "/reply_to_reviews\\(\\)/,/find_open_pr\\(\\)/" "$WF" | grep -q "dangerously-skip-permissions"' \
  "the reply pass does not skip Claude permissions"
check 'grep -q "env -u GH_TOKEN -u GITHUB_TOKEN -u SLACK_BOT_TOKEN -u DSTP_FORGE_SERVICE_KEY" "$WF"' \
  "the reply pass unsets write tokens and secrets"
check 'grep -q "<!-- forge-revise-reply -->" "$WF"' \
  "AI replies are tagged so they are not re-ingested as findings"
check 'grep -q "<!-- forge-slack-revise -->" "$WF"' \
  "human Slack notes on the issue are included in the revise instruction"
check 'grep -q "120000" "$WF"' \
  "an oversized instruction fails loudly instead of E2BIG"
check 'grep -q "capture(\"reviewed-commit" "$WF"' \
  "reviewed-commit SHA extraction uses per-body capture"
check 'awk "
  /while \\[ \"\\\$ROUND\"/ {l=1}
  l && /run_branch_revise/ {r=NR}
  l && /post_silent_watermark/ {w=NR}
  END {exit (r && w && r<w) ? 0 : 1}
" "$WF"' \
  "watermark is posted only after a successful dstp revise"
check 'grep -q "gh pr comment \"\$PR_URL\" --body-file" "$WF"' \
  "AI reply is posted from a file, not an inline prompt"
check '! grep -q "gh pr comment \"\$PR_URL\" --body \"\$(cat <<" "$WF"' \
  "the revise instruction is never a gh pr comment body"
check '! awk "/gh pr comment/{c=1} c && /^[[:space:]]*EOF[[:space:]]*$/{c=0; next} c{print}" "$WF" | grep -q "Address remaining CI failures"' \
  "Address remaining CI failures is not posted as a gh pr comment"
check 'grep -q "sub\" = \"auto\"" "$WF" && grep -q "ARGS+=(--fast)" "$WF"' \
  "--fast is appended only when dstp subcommand is auto"
check '! grep -qE "revise .*--fast" "$WF"' \
  "--fast is not passed to dstp revise"
check 'grep -q "test(\"<!-- deriv-pr-review-\")" "$WF"' \
  "findings match every deriv-pr-review- engine, not a hardcoded pair"
check 'grep -q "test(\"<!-- deriv-pr-review-progress-\") | not" "$WF"' \
  "progress markers are not treated as review findings"
check 'grep -q "minimizeComment" "$WF"' \
  "the watermark comment is minimized"
check 'grep -q "body='\''<!-- forge-revise-instructions -->'\''" "$WF"' \
  "watermark body is the HTML marker only"
check 'grep -q "slack_progress" "$WF"' \
  "Slack progress updates a living message"
check 'grep -q "chat.update" "$WF"' \
  "Slack progress uses chat.update"
check 'grep -q "slack_progress_ts" "$WF"' \
  "the living Slack message ts is passed to Report"
check 'awk "
  /SLACK_PROGRESS_TS/ {s=1}
  s && /chat.update/ {u=1}
  s && /chat.postMessage/ {p=1}
  END {exit (u && p) ? 0 : 1}
" "$WF"' \
  "Report updates the progress message when a ts exists, otherwise posts once"

if [[ "$fail" -ne 0 ]]; then
  echo "❌ forge.yml contract test failed"
  exit 1
fi
echo "✅ forge.yml contract test passed"
