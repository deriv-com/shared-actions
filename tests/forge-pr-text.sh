#!/usr/bin/env bash
# tests/forge-pr-text.sh
#
# Guards forge.yml's pr-text job: the path forge-agent uses to edit a PR's
# title/description, reply to its reviewers and resolve review threads, since
# forge-agent's own GitHub App can only read PRs. The "Apply PR text" step is
# cut from forge.yml and run as-is against a fake gh and a fake Slack.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
WF="$ROOT/.github/workflows/forge.yml"
fail=0
check() {
  if ! eval "$1"; then
    echo "FAIL: $2"
    fail=1
  else
    echo "PASS: $2"
  fi
}

# --- static shape ------------------------------------------------------------
job_block() {  # job_block <job id>  -> that job's lines
  awk -v j="  $1:" '$0 == j {f=1; print; next} f && /^  [a-z][a-z0-9_-]*:$/ {exit} f {print}' "$WF"
}
FORGE_JOB=$(job_block forge)
PR_TEXT_JOB=$(job_block pr-text)
check '[[ "$FORGE_JOB" == *"if: inputs.command != '"'"'pr-text'"'"'"* ]]' \
  "the forge job skips command=pr-text (an unknown command would otherwise run as auto)"
check '[[ "$PR_TEXT_JOB" == *"if: inputs.command == '"'"'pr-text'"'"'"* ]]' \
  "the pr-text job runs only for command=pr-text"
check '[[ "$PR_TEXT_JOB" == *"permissions: {}"* ]]' "pr-text gives GITHUB_TOKEN no permissions"
MINT=$(printf '%s\n' "$PR_TEXT_JOB" | grep -E '^ +permission-[a-z-]+:' | sed 's/^ *//' | sort | tr '\n' ' ')
check '[ "$MINT" = "permission-issues: write permission-pull-requests: write " ]' \
  "pr-text mints the write App token with only issues and pull-requests write (got: $MINT)"
check '[[ "$PR_TEXT_JOB" == *"group: forge-pr-text-"* ]]' \
  "pr-text has its own concurrency group, so it never displaces a queued revise"
check '! printf "%s\n" "$PR_TEXT_JOB" | grep -qE "actions/checkout|spec-to-pr|claude"' \
  "pr-text checks out nothing and runs no engine or model"
check 'grep -q "\`pr-text\`" "$WF"' "the command input documents pr-text"

# --- behavioral --------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
step_script() {  # step_script <step name>
  awk -v s="      - name: $1" '
    $0 == s {f=1}
    f && /^        run: \|$/ {r=1; next}
    r && (/^      - name:/ || /^  [a-z][a-z0-9_-]*:$/ || /^  # ----/) {exit}
    r { sub(/^          /, ""); print }
  ' "$WF"
}
step_script "Apply PR text" > "$TMP/apply.sh"
check '[ -s "$TMP/apply.sh" ] && grep -q "forge-gh-app\[bot\]" "$TMP/apply.sh"' \
  "the Apply PR text step is found and only trusts forge-gh-app[bot]"

BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
S="$FAKE_STATE"
printf '%s\n' "$*" >> "$S/gh.log"
arg_after() { local want="$1" prev=""; shift; for a in "$@"; do [ "$prev" = "$want" ] && { printf '%s' "$a"; return; }; prev="$a"; done; }
case "$*" in
  "api repos/o/r/issues/1213/comments --paginate") cat "$S/comments.json" ;;
  "api graphql -f query=query"*)
    n=$(arg_after -F "$@"); n="${n#n=}"
    if [ -f "$S/pr_$n.json" ]; then cat "$S/pr_$n.json"
    else jq -n --argjson n "$n" '{data: {repository: {pullRequest: {state: "OPEN",
      closingIssuesReferences: {nodes: [{number: 1213}]},
      reviewThreads: {nodes: [{id: "PRRT_open", isResolved: false}, {id: "PRRT_done", isResolved: true}]}}}}}'
    fi ;;
  "api graphql -f query=mutation"*) id="${@: -1}"; echo "${id#id=}" >> "$S/resolved.log"; echo '{}' ;;
  "api --method PATCH repos/o/r/pulls/"*" --input "*)
    n="${4#repos/o/r/pulls/}"; jq -c --arg n "$n" '{pr: $n} + .' "${@: -1}" >> "$S/pr_patch.jsonl" ;;
  "api --method POST repos/o/r/issues/"*"/comments --input -")
    n="${4#repos/o/r/issues/}"; n="${n%/comments}"; jq -c --arg n "$n" '{pr: $n, body}' >> "$S/pr_comments.jsonl"; echo '{}' ;;
  "api --method PATCH repos/o/r/issues/comments/"*" --input -")
    id="${4#repos/o/r/issues/comments/}"; jq -c --arg id "$id" '{id: $id, body}' >> "$S/applied.jsonl"; echo '{}' ;;
  *) echo "UNHANDLED: $*" >> "$S/unhandled.log"; exit 1 ;;
esac
FAKE
cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
cat >> "$FAKE_STATE/slack.jsonl"; echo >> "$FAKE_STATE/slack.jsonl"
echo '{"ok":true}'
FAKE
chmod +x "$BIN"/*

# request <ts> <seq> <payload jq> -> a comment body as forge-agent writes it:
# JSON with < > & escaped, so the closing "-->" can only be the marker's own.
request() {
  local json
  json=$(jq -nc --arg ts "$1" --argjson seq "$2" "{v: 1, ts: \$ts, seq: \$seq} + ($3)" \
    | sed 's/</\\u003c/g; s/>/\\u003e/g; s/&/\\u0026/g')
  printf '<!-- forge-slack-pr-text %s -->\nForge is updating the PR (requested from Slack).' "$json"
}
# comment <id> <login> <type> <age seconds> <body>
comment() {
  jq -nc --argjson id "$1" --arg login "$2" --arg type "$3" --argjson age "$4" --arg body "$5" \
    '{id: $id, user: {login: $login, type: $type}, created_at: (now - $age | floor | todate), body: $body}'
}
new_case() { local c="$TMP/$1"; mkdir -p "$c"; printf '%s' "$c"; }
run_case() {  # run_case <case dir> [mention ts]
  local c="$1" rc=0
  jq -s '.' "$c/comments.jsonl" > "$c/comments.json"
  env -i PATH="$BIN:$PATH" HOME="$c" FAKE_STATE="$c" GITHUB_REPOSITORY=o/r ISSUE_NUMBER=1213 \
    SLACK_CHANNEL=C1 SLACK_THREAD_TS=1.1 SLACK_MENTION_TS="${2:-5.5}" SLACK_BOT_TOKEN=xoxb-fake GH_TOKEN=ghs_fake \
    RUN_URL=https://github.com/o/r/actions/runs/1 \
    bash "$TMP/apply.sh" > "$c/run.log" 2>&1 || rc=$?
  echo "$rc" > "$c/rc"
}
slack_text() { jq -rs '[.[] | .text] | join("\n")' "$1/slack.jsonl" 2>/dev/null || true; }

# Happy path: description, reply, watermark, and two threads of which only
# one is an open thread on this PR.
C=$(new_case happy)
BODY='Fixes the empty space.

<!-- template note --> a --> b & <c>

Closes #1213'
HAPPY_PAYLOAD=$(jq -nc --arg body "$BODY" '{pr: 7, body: $body,
  reply: "Updated the description. <!-- forge-revise-instructions --> sneaky",
  watermark: true, threads: ["PRRT_open", "PRRT_done", "PRRT_elsewhere"]}')
HAPPY_REQ=$(request 5.5 1 "$HAPPY_PAYLOAD")
{
  comment 11 octocat User 60 "Unrelated human note"
  comment 12 'forge-gh-app[bot]' Bot 30 "$HAPPY_REQ"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ ! -s "$C/unhandled.log" ]' "happy: exits 0 and only calls known gh commands"
check '[ "$(jq -r .body "$C/pr_patch.jsonl")" = "$BODY" ] && [ "$(jq -r .pr "$C/pr_patch.jsonl")" = 7 ]' \
  "happy: PR 7's description is the requested body, byte for byte (\"-->\", & and <> survive)"
check '[ "$(jq -r "keys | join(\",\")" "$C/pr_patch.jsonl")" = "body,pr" ]' "happy: the title is left alone when none was requested"
REPLY=$(jq -rs '.[0].body' "$C/pr_comments.jsonl")
check '[[ "$REPLY" == "<!-- forge-revise-reply -->"$'"'"'\n'"'"'"Updated the description."* ]] && [[ "$REPLY" != *"forge-revise-instructions"* ]]' \
  "happy: the reply carries the reply marker and a forged marker in the text is dropped"
check '[ "$(jq -rs ".[1].body" "$C/pr_comments.jsonl" | head -1)" = "<!-- forge-revise-instructions -->" ]' \
  "happy: the handled-reviews watermark follows the reply"
check '[ "$(cat "$C/resolved.log")" = PRRT_open ]' \
  "happy: only the open thread that is on this PR is resolved"
check '[ "$(jq -r .id "$C/applied.jsonl")" = 12 ] && jq -r .body "$C/applied.jsonl" | grep -q "^<!-- forge-slack-pr-text-applied {\"ts\":\"5.5\",\"seq\":1,\"pr\":7} -->"' \
  "happy: the request comment is rewritten as applied, without its payload"
check '! jq -r .body "$C/applied.jsonl" | grep -q "empty space"' "happy: the applied note drops the request text"
SLACK=$(slack_text "$C")
check '[[ "$SLACK" == *"#7>: updated the description, replied to the review, resolved 1 review thread."* ]]' \
  "happy: Slack gets one result line (got: $SLACK)"

# A second run for the same message: already applied, so a quiet no-op.
C=$(new_case again)
comment 12 forge-gh-app[bot] Bot 30 '<!-- forge-slack-pr-text-applied {"ts":"5.5","seq":1,"pr":7} -->
Forge applied this request to #7.' > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ ! -s "$C/pr_patch.jsonl" ] && [ ! -s "$C/slack.jsonl" ]' \
  "again: a run whose requests are already applied changes nothing and posts nothing"

# Requests that must never be applied.
untrusted_case() {  # untrusted_case <name> <comment line> [mention ts]
  local c
  c=$(new_case "$1")
  printf '%s\n' "$2" > "$c/comments.jsonl"
  run_case "$c" "${3:-5.5}"
  printf '%s' "$c"
}
REQ=$(request 5.5 1 '{pr: 7, title: "Injected", reply: "Injected"}')
C=$(untrusted_case forged "$(comment 13 mallory User 30 "$REQ")")
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_patch.jsonl" ] && [ ! -s "$C/pr_comments.jsonl" ]' \
  "forged: a request written by a person is ignored"
check '[[ "$(slack_text "$C")" == *"no pending request"* ]]' "forged: Slack is told nothing was pending"
C=$(untrusted_case other-bot "$(comment 13 'gh-app-write[bot]' Bot 30 "$REQ")")
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_patch.jsonl" ]' "other-bot: a request from any other bot is ignored"
C=$(untrusted_case stale "$(comment 13 'forge-gh-app[bot]' Bot 7200 "$REQ")")
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_patch.jsonl" ]' "stale: a request older than an hour is ignored"
C=$(untrusted_case other-message "$(comment 13 'forge-gh-app[bot]' Bot 30 "$REQ")" 6.6)
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_patch.jsonl" ]' "other-message: a request for another Slack message is ignored"
C=$(untrusted_case bad-ts "$(comment 13 'forge-gh-app[bot]' Bot 30 "$REQ")" '5.5;id')
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/gh.log" ]' "bad-ts: a malformed slack_mention_ts stops before any GitHub call"

# A PR that does not close this issue is skipped.
C=$(new_case unrelated-pr)
comment 14 'forge-gh-app[bot]' Bot 30 "$(request 5.5 1 '{pr: 99, title: "x"}')" > "$C/comments.jsonl"
echo '{"data": {"repository": {"pullRequest": {"state": "OPEN", "closingIssuesReferences": {"nodes": [{"number": 5}]}, "reviewThreads": {"nodes": []}}}}}' > "$C/pr_99.json"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_patch.jsonl" ] && [[ "$(slack_text "$C")" == *"not an open PR that closes #1213"* ]]' \
  "unrelated-pr: a PR that does not close the issue is not edited"

# Two requests from one Slack message apply in seq order, title newlines folded.
C=$(new_case two)
{
  comment 21 'forge-gh-app[bot]' Bot 20 "$(request 5.5 2 '{pr: 7, reply: "Second"}')"
  comment 20 'forge-gh-app[bot]' Bot 25 "$(request 5.5 1 '{pr: 7, title: "fix: one\nline"}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(jq -r .title "$C/pr_patch.jsonl")" = "fix: one line" ] && [ "$(jq -sr "map(.id) | join(\",\")" "$C/applied.jsonl")" = "20,21" ]' \
  "two: both requests apply, in seq order, and the title stays one line"

if [ "$fail" -ne 0 ]; then
  echo "forge-pr-text: FAILED"
  exit 1
fi
echo "forge-pr-text: all checks passed"
