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
             slack_message_ts slack_started_at \
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
check 'awk "/^      slack_message_ts:/{f=1} f && /required:/{print; exit}" "$WF" | grep -q "required: false"' \
  "input 'slack_message_ts' stays optional"
check 'awk "/^      slack_started_at:/{f=1} f && /required:/{print; exit}" "$WF" | grep -q "required: false"' \
  "input 'slack_started_at' stays optional"
check 'awk "/^      model:/{f=1} f && /default:/{print; exit}" "$WF" | grep -q "default: \"claude-sonnet-5-5\""' \
  "model default is claude-sonnet-5-5"
# Pass the LiteLLM alias through. Rewriting it to an older catalog id would
# send a different model id to the gateway. END fails closed if the Resolve
# or Preflight step names change (no vacuous pass).
check 'awk "
  /name: Resolve the LLM gateway/ {r=1}
  r && /MODEL=..FORGE_MODEL/ {m=1}
  r && /echo .ANTHROPIC_MODEL=.MODEL/ {e=1}
  r && /MODEL=.claude-sonnet-4-5/ {old=1}
  r && /name: Preflight/ {p=1; exit}
  END {exit (r && p && m && e && !old) ? 0 : 1}
" "$WF"' \
  "gateway export passes the LiteLLM alias through as ANTHROPIC_MODEL"
check 'awk "
  /name: Report outcome/ {r=1}
  r && /FAIL_SNIPPET=/ {f=1}
  r && /spec-coverage \[\(\]/ {s=1}
  r && /Verify failed/ {v=1}
  r && /unrecognized_model/ {u=1}
  r && /QUIET=.*FAIL_SNIPPET/ {q=1}
  r && /\&amp;/ {esc=1}
  END {exit (r && f && s && v && u && q && esc) ? 0 : 1}
" "$WF"' \
  "Report Failed Slack copy includes spec-coverage or Verify failed from the log"

# Run the FAIL_SNIPPET pipeline from Report outcome against a fixture log.
SNIPPET_LINE=$(awk '
  /name: Report outcome/ {r=1}
  r && /FAIL_SNIPPET=\$\(/ { sub(/^ +/, ""); print; exit }
' "$WF")
check '[ -n "$SNIPPET_LINE" ]' "FAIL_SNIPPET assignment exists in Report outcome"
TAIL=$'noise\n\033[31mVerify failed: spec-coverage (3/40 files) ping <!channel> & more\033[0m\nmore'
export TAIL
GOT=$(bash -c "${SNIPPET_LINE}"$'\n'"printf '%s' \"\$FAIL_SNIPPET\"")
check '[[ "$GOT" == *"spec-coverage (3/40 files)"* ]]' "FAIL_SNIPPET extracts the verify line"
check '[[ "$GOT" == *"&lt;!channel&gt;"* ]]' "FAIL_SNIPPET Slack-escapes angle brackets"
check '[[ "$GOT" == *"&amp; more"* ]]' "FAIL_SNIPPET Slack-escapes ampersand"
check '[[ "$GOT" != *"<!channel>"* ]]' "FAIL_SNIPPET does not leave raw <!channel>"

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
check 'grep -q "reviewThreads" "$WF"' \
  "unresolved human review threads go in the revise instruction"
check 'grep -q "github_pr_url" "$WF"' \
  "PR_URL is kept only when it is a GitHub pull URL"
check 'grep -q "produced no changes" "$WF"' \
  "dstp no-change is detected and stops the wait loop"
check 'grep -q "Nothing was committed" "$WF"' \
  "Report no-change completion does not say the PR is up"
check 'grep -q "No open PR is linked to this issue" "$WF"' \
  "a non-URL PR_URL tells the user to link an open PR, not PR is up"
check 'awk "
  /wait_for_rollup\\(\\)/ {w=1}
  w && /fetch_comments\\(\\)/ {exit (s ? 0 : 1)}
  w && /slack_progress/ {s=1}
  END { if (!w) exit 1 }
" "$WF"' \
  "wait_for_rollup chat.update the living card each 15s poll"
check 'grep -q "unsent_threads \"\$ALL_THREADS\" \"\$SENT_THREADS\"" "$WF"' \
  "a human review thread is sent to dstp once per run, not every round"
check 'grep -q "threads_remaining=\$THREAD_N" "$WF" && grep -q "human review threads were not addressed" "$WF"' \
  "Report warns about human review threads that were not addressed"
check 'grep -q "\"\$ALL_THREADS\" = \"unknown\"" "$WF"' \
  "an unreadable review-thread query is not treated as zero threads"
check 'grep -q "dstp revise reported an error" "$WF"' \
  "a dstp revise error other than no-change fails the revise"
check 'grep -q "tee /tmp/forge.log || rc=\$?" "$WF" && grep -q "read_revise_result /tmp/forge.log || return 1" "$WF"' \
  "dstp exits 1 on no-change, so its JSON is read before the exit code is used"
check 'grep -q "REASON_SLACK=" "$WF"' \
  "the no-change reason is Slack-escaped before it is posted"
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
  /name: Report outcome/ {r=1}
  r && /Took / {t=1}
  r && /chat.postMessage/ {p=1}
  r && /chat.update/ {u=1}
  r && /All CI is green/ {g=1}
  r && /AI reviewers/ {a=1}
  r && /No code change needed/ {n=1}
  r && /gh pr checks/ {c=1}
  END {exit (t && p && u && g && a && n && c) ? 0 : 1}
" "$WF"' \
  "Report updates the living card, posts Took + CI/AI facts, and treats empty pr_url success as no-code-change"
check 'awk "
  /name: Report outcome/ {r=1}
  r && /Living card: quiet chat.update/ {q=1}
  q && /chat.postMessage/ {exit (b ? 0 : 1)}
  q && /blocks:/ {b=1}
" "$WF"' \
  "Report quiet chat.update replaces living Block Kit with blocks"
check 'awk "
  /name: Report outcome/ {r=1}
  r && /ci_failing_names/ {n=1}
  r && /n<5|n < 5|head -n 5/ {c=1}
  END {exit (n && c) ? 0 : 1}
" "$WF"' \
  "ci_failing_names is capped at 5 check names from gh pr checks"
check 'awk "
  /name: Report outcome/ {r=1}
  r && /design doc and plan are committed/ {bad=1}
  r && /I.ll post the PR/ {bad=1}
  r && /Opened the PR/ {bad=1}
  END {exit bad ? 1 : 0}
" "$WF"' \
  "Report Slack body does not use kill-list templates"
check 'awk "
  /wait_for_rollup\\(\\)/ {w=1}
  w && /fetch_comments\\(\\)/ {exit 0}
  w && /gh pr checks/ {exit 1}
" "$WF"' \
  "wait loop stays on statusCheckRollup — gh pr checks is Report-only"
check 'awk "
  /reply_to_reviews\\(\\)/ {r=1}
  r && /find_open_pr\\(\\)/ {exit (p ? 1 : 0)}
  r && /chat.postMessage/ {p=1}
" "$WF"' \
  "reply_to_reviews stays on GitHub only — no Slack dump of review markdown"
check '! grep -q "GITHUB_RUN_STARTED_AT" "$WF"' \
  "Report does not use nonexistent GITHUB_RUN_STARTED_AT"
check 'awk "
  /name: Run Forge/ {f=1}
  f && /echo \"started_at=/ {s=1}
  f && /^      - name:/ && \$0 !~ /Run Forge/ {exit}
  END {exit s ? 0 : 1}
" "$WF"' \
  "Run Forge exports started_at to GITHUB_OUTPUT"
check 'awk "
  /name: Report outcome/ {r=1}
  r && /FORGE_STARTED_AT:/ {e=1}
  r && /FORGE_STARTED_AT:-/ {u=1}
  END {exit (e && u) ? 0 : 1}
" "$WF"' \
  "Report prefers FORGE_STARTED_AT over a fake env var"
check 'grep -q "permission-checks: read" "$WF"' \
  "minted App token can read check runs"
check 'awk "
  /name: Report outcome/ {r=1}
  r && /CI_STATE=/ {s=1}
  r && /CI_PENDING=/ {p=1}
  r && /CI state unknown/ {u=1}
  r && /CI still running/ {n=1}
  END {exit (s && p && u && n) ? 0 : 1}
" "$WF"' \
  "Report fails closed on pending or unreadable checks"
check 'awk "
  /name: Report outcome/ {r=1}
  r && /if CHECKS=/ {bad=1}
  END {exit bad ? 1 : 0}
" "$WF"' \
  "Report does not treat gh pr checks non-zero as unread"
check 'awk "
  /name: Report outcome/ {r=1}
  r && /-eq 8/ {e=1}
  r && /successful read/ {s=1}
  END {exit (e && s) ? 0 : 1}
" "$WF"' \
  "Report treats gh pr checks exit 8 as a successful read"
check 'grep -q "slack_requests_remaining" "$WF"' \
  "outstanding Slack change requests are exported for Report"
check 'awk "
  /name: Report outcome/ {r=1}
  r && /The log tail goes into an issue comment/ {c=1}
  END {exit c ? 0 : 1}
" "$WF"' \
  "failure-log scrub keeps its security rationale"
check 'grep -q "Replied on the PR to .* AI review comments" "$WF"' \
  "completion copy counts comments, not findings"
check 'awk "
  /name: Run Forge/ {r=1}
  r && /APP_KEY=\"\\\$WRITE_APP_KEY\"/ {c=1}
  r && /unset WRITE_APP_KEY/ {u=1}
  r && /^      - name:/ && \$0 !~ /Run Forge/ {exit}
  END {exit (c && u) ? 0 : 1}
" "$WF"' \
  "Run Forge copies WRITE_APP_KEY then unsets it before any child"
check 'awk "
  /reply_to_reviews\\(\\)/ {r=1}
  r && /find_open_pr\\(\\)/ {exit (k ? 0 : 1)}
  r && /-u WRITE_APP_KEY/ {k=1}
" "$WF"' \
  "reply pass also unsets WRITE_APP_KEY"
check 'awk "
  /while \\[ \"\\\$ROUND\"/ {l=1}
  l && /remint_write_token/ {r=1}
  l && /run_branch_revise|wait_for_rollup/ {exit (r ? 0 : 1)}
" "$WF"' \
  "remint_write_token runs at the top of every wait+revise round"
check 'awk "
  /slack_progress \"Opening the PR\"/ {s=1}
  s && /remint_write_token/ {r=1}
  s && /run_dstp/ {exit (r ? 0 : 1)}
" "$WF"' \
  "remint_write_token runs immediately before the initial run_dstp"
check 'grep -q "http.https://github.com/.extraheader" "$WF"' \
  "remint refreshes git extraheader so git push uses the new token"
check 'awk "
  /remint_write_token\\(\\)/ {r=1}
  r && /git config --local/ && /extraheader/ {l=1}
  r && /slack_progress_payload\\(\\)/ {exit (l ? 0 : 1)}
" "$WF"' \
  "remint refreshes repo-local extraheader from actions/checkout"
check 'awk "
  /name: Mint token for Report/ {m=1}
  m && /if: always\\(\\)/ {a=1}
  m && /id: report-token/ {i=1}
  END {exit (a && i) ? 0 : 1}
" "$WF"' \
  "Report mints its own token with if: always()"
check 'grep -q "GH_TOKEN: \${{ steps.report-token.outputs.token }}" "$WF"' \
  "Report uses the freshly minted token, not the job-start token"
check 'awk "
  /name: Report outcome/ {r=1}
  r && /tolower\(\\\$1\) !~ \/trivy\// {t=1}
  END {exit t ? 0 : 1}
" "$WF"' \
  "Report does not count Trivy as blocking CI"

# --- GraphQL queries must parse ---------------------------------------------
# String matches let a query GitHub cannot parse ship (8 `{`, 9 `}` in the
# review-thread query). No GraphQL parser is installed here, so this checks
# that brackets balance; forge-agent parses the same file with graphql-js.
QUERY_REPORT=$(python3 - "$WF" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
queries = re.findall(r"-f query='([^']*)'", src)
bad = []
for q in queries:
    depth = {"{": 0, "(": 0}
    pairs = {"}": "{", ")": "("}
    ok = True
    for ch in q:
        if ch in depth:
            depth[ch] += 1
        elif ch in pairs:
            depth[pairs[ch]] -= 1
            if depth[pairs[ch]] < 0:
                ok = False
    if not ok or any(depth.values()):
        bad.append(q[:80])
print(len(queries))
for b in bad:
    print("UNBALANCED: " + b)
PY
)
check '[ "$(printf "%s\n" "$QUERY_REPORT" | head -1)" -ge 3 ]' \
  "found the workflow's GraphQL queries"
check '! printf "%s\n" "$QUERY_REPORT" | grep -q UNBALANCED' \
  "every GraphQL query has balanced braces and parentheses"

# --- behavioral: workflow functions against a fake gh -----------------------
# Each function is cut from forge.yml verbatim (10-space run-block indent).
extract_fn() {
  awk -v name="$1" '
    $0 == "          " name "() {" {f=1}
    f { end = ($0 == "          }"); sub(/^          /, ""); print; if (end) exit }
  ' "$WF"
}
TMP_BEHAVIOR=$(mktemp -d)
trap 'rm -rf "$TMP_BEHAVIOR"' EXIT

READ_PR_CHECKS=$(extract_fn read_pr_checks)
check '[ -n "$READ_PR_CHECKS" ]' "Report reads checks through read_pr_checks"
pr_checks_case() {  # pr_checks_case <gh exit> <gh stdout>
  GH_RC="$1" GH_OUT="$2" bash -c "
    gh() { [ -n \"\$GH_OUT\" ] && printf '%s\n' \"\$GH_OUT\"; return \"\$GH_RC\"; }
    $READ_PR_CHECKS
    read_pr_checks https://github.com/o/r/pull/1
    printf '%s %s %s %s\n' \"\$CI_STATE\" \"\$CI_FAILING\" \"\$CI_PENDING\" \"\$CI_FAILING_NAMES\"
  "
}
CHECKS_FAIL=$'E2E smoke\tfail\t4s\thttps://x/1\t\nTrivy SCA\tfail\t1s\thttps://x/2\t\ntest\tpass\t4m\thttps://x/3\t\nlint\tfail\t9s\thttps://x/4\t'
CHECKS_PENDING=$'test\tpending\t0\thttps://x/3\t\nlint\tpass\t9s\thttps://x/4\t'
check '[ "$(pr_checks_case 1 "$CHECKS_FAIL")" = "ok 2 0 E2E smoke, lint" ]' \
  "gh pr checks exit 1 with output is a read with failures, not CI state unknown"
check '[ "$(pr_checks_case 8 "$CHECKS_PENDING")" = "ok 0 1 " ]' \
  "gh pr checks exit 8 with output is a read with pending checks"
CHECKS_GREEN=$'test\tpass\t4m\thttps://x/3\t'
check '[ "$(pr_checks_case 0 "$CHECKS_GREEN")" = "ok 0 0 " ]' \
  "gh pr checks exit 0 is a green read"
check '[ "$(pr_checks_case 1 "")" = "unknown 0 0 " ]' \
  "gh pr checks exit 1 with no output stays CI state unknown"

if [[ "$fail" -ne 0 ]]; then
  echo "❌ forge.yml contract test failed"
  exit 1
fi
echo "✅ forge.yml contract test passed"
