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
check '[ "$MINT" = "permission-actions: read permission-issues: write permission-pull-requests: write " ]' \
  "pr-text mints the write App token with only issues and pull-requests write, plus actions read for stale claims (got: $MINT)"
check '[[ "$PR_TEXT_JOB" == *"group: forge-pr-text-"* ]]' \
  "pr-text has its own concurrency group, so it never displaces a queued revise"
check '! grep -E "actions/checkout|spec-to-pr|claude" <<< "$PR_TEXT_JOB" >/dev/null' \
  "pr-text checks out nothing and runs no engine or model"
COMMAND_INPUT=$(awk '/^      command:$/ {f=1; print; next} f && /^      [a-z_]+:$/ {exit} f {print}' "$WF")
COMMAND_INPUT_FLAT=$(tr -s ' \n' ' ' <<< "$COMMAND_INPUT")
check '[[ "$COMMAND_INPUT" == *"\`pr-text\`"* ]] && [[ "$COMMAND_INPUT_FLAT" == *"Any other value is rejected before anything runs, and the Slack thread is told."* ]]' \
  "the command input documents pr-text, and that any other command is rejected with a Slack reply"

# --- behavioral --------------------------------------------------------------
TMP=$(mktemp -d)
trap '[ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"' EXIT
step_script() {  # step_script <step name>
  awk -v s="      - name: $1" '
    $0 == s {f=1}
    f && /^        run: \|$/ {r=1; next}
    r && (/^      - name:/ || /^  [a-z][a-z0-9_-]*:$/ || /^  # ----/) {exit}
    r { sub(/^          /, ""); print }
  ' "$WF"
}
step_script "Apply PR text" > "$TMP/apply.sh"
check '[ -s "$TMP/apply.sh" ] && grep -xF '"'"'REQUESTER="forge-gh-app[bot]"'"'"' "$TMP/apply.sh" >/dev/null' \
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
  # A stale claim's run attempt: run_<id>_<attempt> (or run_<id>) holds its conclusion.
  "api repos/o/r/actions/runs/"*"/attempts/"*" --jq "*)
    ra="${2#repos/o/r/actions/runs/}"; id="${ra%%/*}"; at="${ra##*/}"
    cat "$S/run_${id}_${at}" 2>/dev/null || cat "$S/run_$id" 2>/dev/null || echo "" ;;
  # The per-PR read and the paginated threads read. pr_<n>.json overrides the
  # PR; forge_running labels the issue, pr_running_<n> the PR, and
  # threads_extra_<n>.jsonl adds threads from later pages.
  "api graphql -f query=query"*|"api graphql --paginate -f query=query"*)
    n=""; for a in "$@"; do case "$a" in n=*) n="${a#n=}" ;; esac; done
    if [ -f "$S/pr_$n.json" ]; then pr=$(cat "$S/pr_$n.json")
    else pr=$(jq -n '{data: {repository: {pullRequest: {state: "OPEN", title: "old title", body: "",
      closingIssuesReferences: {nodes: [{number: 1213}]},
      reviewThreads: {nodes: [{id: "PRRT_open", isResolved: false}, {id: "PRRT_done", isResolved: true}]}}}}}')
    fi
    if [ -f "$S/state_$n" ]; then export FAKE_PR_STATE; FAKE_PR_STATE=$(cat "$S/state_$n"); else unset FAKE_PR_STATE; fi
    # running_from_read_<k>: the issue gains forge:running from the k-th PR
    # read on (a Forge run that labelled after pr-text's lock).
    # review_after_watermark: a person's review shows up once the watermark
    # has been posted (it finished between the read and the watermark).
    [ "$3" = "--paginate" ] || echo read >> "$S/pr_reads"
    reads=$(wc -l < "$S/pr_reads" 2>/dev/null | tr -d ' ' || echo 0)
    issue_running=false
    [ -f "$S/forge_running" ] && issue_running=true
    for f in "$S"/running_from_read_*; do
      [ -e "$f" ] && [ "${reads:-0}" -ge "${f##*running_from_read_}" ] && issue_running=true
    done
    late_review=false
    if [ -f "$S/review_after_watermark" ] && grep -F 'forge-revise-instructions' "$S/pr_comments.jsonl" >/dev/null 2>&1; then late_review=true; fi
    # after_read_fail: the read after the watermark fails.
    if [ -f "$S/after_read_fail" ] && [ "$3" != "--paginate" ] && grep -F 'forge-revise-instructions' "$S/pr_comments.jsonl" >/dev/null 2>&1; then
      echo "gh: Server Error (HTTP 502)" >&2; exit 1
    fi
    pr=$(jq -c --argjson issue_running "$issue_running" --argjson late_review "$late_review" \
              --argjson pr_running "$([ -f "$S/pr_running_$n" ] && echo true || echo false)" '
      .data.repository.pullRequest.state = ($ENV.FAKE_PR_STATE // .data.repository.pullRequest.state)
      | .data.repository.issue.labels.nodes = (if $issue_running then [{name: "forge:running"}] else [] end)
      | .data.repository.pullRequest.labels.nodes = (if $pr_running then [{name: "forge:running"}] else [] end)
      | if $late_review then .data.repository.pullRequest.reviews.nodes += [{submittedAt: (now | todate), body: "Please change this", author: {__typename: "User", login: "rev"}}] else . end' <<< "$pr")
    if [ "$3" = "--paginate" ]; then
      jq -c '.data.repository.pullRequest.reviewThreads.nodes[]?' <<< "$pr"
      cat "$S/threads_extra_$n.jsonl" 2>/dev/null || true
    else
      printf '%s\n' "$pr"
    fi ;;
  # Labels. labels_<n> lists issue/PR n's labels; lock_fail refuses adding
  # forge:pr-text, unlock_fail removing it.
  "label create "*) echo ok ;;
  # The claim step's label read. labels_read_fail fails it; clear_after_<k>
  # drops forge:pr-text once it has been read k times.
  "api repos/o/r/issues/"*"/labels?per_page=100 --jq "*)
    n="${2#repos/o/r/issues/}"; n="${n%%/*}"; touch "$S/labels_$n"
    echo read >> "$S/label_reads"
    if [ -f "$S/labels_read_fail" ]; then echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi
    for f in "$S"/clear_after_*; do
      [ -e "$f" ] || continue
      if [ "$(wc -l < "$S/label_reads" | tr -d ' ')" -ge "${f##*clear_after_}" ]; then
        grep -vxF forge:pr-text "$S/labels_$n" > "$S/labels_$n.next" || true; mv "$S/labels_$n.next" "$S/labels_$n"
      fi
    done
    cat "$S/labels_$n" ;;
  "api --method POST repos/o/r/issues/"*"/labels -f labels[]="*|"api --method DELETE repos/o/r/issues/"*"/labels/"*)
    n="${4#repos/o/r/issues/}"; n="${n%%/*}"; touch "$S/labels_$n"
    if [ "$3" = POST ]; then op=--add-label; l="${@: -1}"; l="${l#labels[]=}"; else op=--remove-label; l="${4##*/}"; l="${l//%3A/:}"; fi
    printf '%s %s %s\n' "$op" "$n" "$l" >> "$S/labels.log"
    if [ "$op" = --add-label ]; then
      if [ -f "$S/lock_fail" ]; then echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi
      grep -qxF "$l" "$S/labels_$n" || echo "$l" >> "$S/labels_$n"
    else
      if [ -f "$S/unlock_fail" ]; then echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi
      # unlock_fail_once: only the first removal is refused.
      if [ -f "$S/unlock_fail_once" ]; then rm -f "$S/unlock_fail_once"; echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi
      grep -vxF "$l" "$S/labels_$n" > "$S/labels_$n.next" || true; mv "$S/labels_$n.next" "$S/labels_$n"
    fi ;;
  "api graphql -f query=mutation"*) id="${@: -1}"; echo "${id#id=}" >> "$S/resolved.log"; echo '{}' ;;
  "api --method PATCH repos/o/r/pulls/"*" --input "*)
    # The edit goes in as a file, a state change on stdin. patch_422: GitHub
    # refuses the change (a reopen whose branch is gone).
    n="${4#repos/o/r/pulls/}"; f="${@: -1}"; [ "$f" = - ] && f=/dev/stdin
    if [ -f "$S/patch_422" ]; then echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; fi
    jq -c --arg n "$n" '{pr: $n} + .' "$f" >> "$S/pr_patch.jsonl"
    # A state change sticks for later reads of the PR.
    st=$(jq -rs '.[-1] | select(.pr == "'"$n"'") | .state // empty | ascii_upcase' "$S/pr_patch.jsonl")
    [ -z "$st" ] || echo "$st" > "$S/state_$n" ;;
  # The watermark is removed again. wm_delete_fail: GitHub refuses.
  "api --method DELETE repos/o/r/issues/comments/"*)
    echo "${4##*/}" >> "$S/deleted.log"
    if [ -f "$S/wm_delete_fail" ]; then echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi ;;
  "api --method POST repos/o/r/issues/"*"/comments --input -"|"api --method POST repos/o/r/issues/"*"/comments --input - --jq .id")
    # reply_fail: GitHub refuses the reviewer reply (the comment with the reply marker).
    # die_on_reply: the job is cancelled (SIGTERM) while the reply is posted.
    # A comment's id is 900 plus its line in pr_comments.jsonl.
    n="${4#repos/o/r/issues/}"; n="${n%/comments}"; c=$(jq -c --arg n "$n" '{pr: $n, body}')
    if [ -f "$S/die_on_reply" ] && jq -e '.body | startswith("<!-- forge-revise-reply -->")' <<< "$c" >/dev/null; then
      kill -TERM "$PPID"; sleep 1; exit 1
    fi
    if [ -f "$S/reply_fail" ] && jq -e '.body | startswith("<!-- forge-revise-reply -->")' <<< "$c" >/dev/null; then
      echo "gh: Server Error (HTTP 502)" >&2; exit 1
    fi
    printf '%s\n' "$c" >> "$S/pr_comments.jsonl"
    if [ "${@: -1}" = .id ]; then echo "$((900 + $(wc -l < "$S/pr_comments.jsonl")))"; else echo '{}'; fi ;;
  "api --method PATCH repos/o/r/issues/comments/"*" --input -")
    # Every claim and outcome mark. claim_fail: GitHub refuses the edit.
    # claim_fail_<id>: only that comment's claim is refused.
    # applied_mark_fail: only the final "applied" mark is refused.
    if [ -f "$S/claim_fail" ]; then echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi
    id="${4#repos/o/r/issues/comments/}"; c=$(jq -c --arg id "$id" '{id: $id, body}')
    if [ -f "$S/claim_fail_$id" ] && jq -e '.body | startswith("<!-- forge-slack-pr-text-claimed ")' <<< "$c" >/dev/null; then
      echo "gh: Server Error (HTTP 502)" >&2; exit 1
    fi
    if [ -f "$S/applied_mark_fail" ] && jq -e '.body | startswith("<!-- forge-slack-pr-text-applied ")' <<< "$c" >/dev/null; then
      echo "applied" >> "$S/applied_mark_attempts"; echo "gh: Server Error (HTTP 502)" >&2; exit 1
    fi
    printf '%s\n' "$c" >> "$S/applied.jsonl"; echo '{}' ;;
  *) echo "UNHANDLED: $*" >> "$S/unhandled.log"; exit 1 ;;
esac
FAKE
cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
# slack_error: Slack answers HTTP 200 with ok:false (not_in_channel).
cat >> "$FAKE_STATE/slack.jsonl"; echo >> "$FAKE_STATE/slack.jsonl"
if [ -f "$FAKE_STATE/slack_error" ]; then echo '{"ok":false,"error":"not_in_channel"}'; else echo '{"ok":true}'; fi
FAKE
chmod +x "$BIN"/*

# request <seq> <payload jq> -> a comment body as forge-agent writes it: JSON
# with < > & escaped, so the closing "-->" can only be the marker's own, and a
# description sent raw after the body delimiter.
request() {
  local json body
  json=$(jq -nc --argjson seq "$1" "{v: 1, ts: \"5.5\", seq: \$seq, ch: \"C9\", th: \"9.9\"} + ($2)")
  body=$(jq -r 'if (.body | type) == "string" then .body else empty end' <<< "$json")
  json=$(jq -c 'if (.body | type) == "string" then .body = true else . end' <<< "$json" \
    | sed 's/</\\u003c/g; s/>/\\u003e/g; s/&/\\u0026/g')
  printf '<!-- forge-slack-pr-text %s -->\nForge is updating the PR (requested from Slack).' "$json"
  if [ -n "$body" ]; then printf '\n<!-- forge-slack-pr-text-body -->\n%s' "$body"; fi
}
# comment <id> <login> <type> <age seconds> <body>
comment() {
  jq -nc --argjson id "$1" --arg login "$2" --arg type "$3" --argjson age "$4" --arg body "$5" \
    '{id: $id, user: {login: $login, type: $type}, created_at: (now - $age | floor | todate), body: $body}'
}
# comment_edited <id> <created age> <edited age> <body>: a forge-gh-app[bot]
# comment edited after it was written (a claim).
comment_edited() {
  jq -nc --argjson id "$1" --argjson age "$2" --argjson edited "$3" --arg body "$4" \
    '{id: $id, user: {login: "forge-gh-app[bot]", type: "Bot"}, created_at: (now - $age | floor | todate), updated_at: (now - $edited | floor | todate), body: $body}'
}
# sha256 of a string, as forge-agent records a request's base.
sha() { if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1; else printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; fi; }
new_case() { local c="$TMP/$1"; mkdir -p "$c"; printf '%s' "$c"; }
# fill_base <case dir>: forge-agent always sends the sha256 of the title and
# description it read. A request here that edits one and names no base gets
# the PR's current one (pr_<n>.json, or the fake's default PR), so only the
# cases about base set it themselves.
fill_base() {
  local c="$1" line j n f t b
  : > "$c/comments.filled"
  while IFS= read -r line; do
    j=$(jq -c '(.body // "") | first(capture("^<!-- forge-slack-pr-text (?<j>[^>]*) -->") | .j) // null | try fromjson catch null' <<< "$line" 2>/dev/null || echo null)
    if jq -e 'type == "object" and (has("base") | not) and (.pr | type) == "number" and ((.title | type) == "string" or .body == true)' <<< "$j" >/dev/null 2>&1; then
      n=$(jq -r .pr <<< "$j"); f="$c/pr_$n.json"
      if [ -f "$f" ]; then
        t=$(jq -j '.data.repository.pullRequest.title // ""' "$f"); b=$(jq -j '.data.repository.pullRequest.body // ""' "$f")
      else
        t="old title"; b=""
      fi
      line=$(jq -c --arg t "$(sha "$t")" --arg b "$(sha "$b")" '
        (.body | capture("^<!-- forge-slack-pr-text (?<j>[^>]*) -->(?<rest>[\\s\\S]*)$")) as $m
        | ($m.j | fromjson) as $p
        | ($p + {base: ((if ($p.title | type) == "string" then {title: $t} else {} end) + (if $p.body == true then {body: $b} else {} end))}
           | tojson | gsub("<"; "\\u003c") | gsub(">"; "\\u003e") | gsub("&"; "\\u0026")) as $nj
        | .body = ("<!-- forge-slack-pr-text " + $nj + " -->" + $m.rest)' <<< "$line")
    fi
    printf '%s\n' "$line" >> "$c/comments.filled"
  done < "$c/comments.jsonl"
}
run_case() {  # run_case <case dir>
  local c="$1" rc=0
  fill_base "$c"
  jq -s '.' "$c/comments.filled" > "$c/comments.json"
  env -i PATH="$BIN:$PATH" HOME="$c" FAKE_STATE="$c" GITHUB_REPOSITORY=o/r ISSUE_NUMBER=1213 \
    SLACK_CHANNEL=C1 SLACK_THREAD_TS=1.1 SLACK_BOT_TOKEN=xoxb-fake GH_TOKEN=ghs_fake \
    RUN_URL=https://github.com/o/r/actions/runs/1 \
    bash "$TMP/apply.sh" > "$c/run.log" 2>&1 || rc=$?
  echo "$rc" > "$c/rc"
}
slack_text() { jq -rs '[.[] | .text] | join("\n")' "$1/slack.jsonl" 2>/dev/null || true; }
# marks <case dir> <claimed|applied|skipped> -> comma-joined comment ids marked so, in order
marks() { jq -sr --arg s "$2" '[.[] | select(.body | startswith("<!-- forge-slack-pr-text-" + $s + " ")) | .id] | join(",")' "$1/applied.jsonl" 2>/dev/null || true; }
nothing_written() { [ ! -s "$1/pr_patch.jsonl" ] && [ ! -s "$1/pr_comments.jsonl" ] && [ ! -s "$1/applied.jsonl" ]; }

# Happy path: description, reply, watermark, and two threads of which only
# one is an open thread on this PR. The result goes to the request's thread.
C=$(new_case happy)
BODY='Fixes the empty space.

a --> b & <c> "quoted" and a second line

Closes #1213'
HAPPY_PAYLOAD=$(jq -nc --arg body "$BODY" '{pr: 7, body: $body,
  reply: "Updated the description. <!-- forge-revise-instructions --> sneaky",
  watermark: true, threads: ["PRRT_open", "PRRT_done", "PRRT_elsewhere"]}')
HAPPY_REQ=$(request 1 "$HAPPY_PAYLOAD")
{
  comment 11 octocat User 60 "Unrelated human note"
  comment 12 'forge-gh-app[bot]' Bot 30 "$HAPPY_REQ"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ ! -s "$C/unhandled.log" ]' "happy: exits 0 and only calls known gh commands"
check '[ "$(jq -r .body "$C/pr_patch.jsonl")" = "$BODY" ] && [ "$(jq -r .pr "$C/pr_patch.jsonl")" = 7 ]' \
  "happy: PR 7's description is the raw body, byte for byte (\"-->\", & and <> survive)"
check '[ "$(jq -r "keys | join(\",\")" "$C/pr_patch.jsonl")" = "body,pr" ]' "happy: the title is left alone when none was requested"
REPLY=$(jq -rs '.[0].body' "$C/pr_comments.jsonl")
check '[[ "$REPLY" == "<!-- forge-revise-reply -->"$'"'"'\n'"'"'"Updated the description."* ]] && [[ "$REPLY" != *"forge-revise-instructions"* ]]' \
  "happy: the reply carries the reply marker and a forged marker in the text is dropped"
check '[ "$(jq -rs ".[1].body | split(\"\\n\")[0]" "$C/pr_comments.jsonl")" = "<!-- forge-revise-instructions -->" ]' \
  "happy: the handled-reviews watermark follows the reply"
check '[ "$(cat "$C/resolved.log")" = PRRT_open ]' \
  "happy: only the open thread that is on this PR is resolved"
check '[ "$(marks "$C" claimed)" = 12 ] && [ "$(marks "$C" applied)" = 12 ] && [ "$(jq -sr ".[0].body | split(\"\\n\")[0]" "$C/applied.jsonl")" = "<!-- forge-slack-pr-text-claimed {\"ts\":\"5.5\",\"seq\":1,\"pr\":7,\"ch\":\"C9\",\"th\":\"9.9\",\"rp\":true,\"run\":0,\"attempt\":1} -->" ]' \
  "happy: the request is claimed before the PR is touched, then marked applied, without its payload"
check '[ "$(grep -m1 "^api --method" "$C/gh.log" | cut -c1-48)" = "api --method PATCH repos/o/r/issues/comments/12 " ]' \
  "happy: the claim is the first write"
check '[[ "$(jq -r .body "$C/applied.jsonl")" != *"empty space"* ]]' "happy: the applied note drops the request text"
check '[ "$(jq -r "[.channel, .thread_ts] | join(\" \")" "$C/slack.jsonl")" = "C9 9.9" ]' \
  "happy: Slack hears back in the thread the request names, not the dispatch's"
SLACK=$(slack_text "$C")
check '[[ "$SLACK" == *"#7>: updated the description, replied to the review, resolved 1 review thread."* ]]' \
  "happy: Slack gets one result line (got: $SLACK)"

# Nothing pending (an earlier run applied it, or a cancelled run's requests
# were picked up by the next one): a quiet no-op.
C=$(new_case again)
comment 12 'forge-gh-app[bot]' Bot 30 '<!-- forge-slack-pr-text-applied {"ts":"5.5","seq":1,"pr":7} -->
Forge applied this request to #7.' > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && nothing_written "$C" && [ ! -s "$C/slack.jsonl" ]' \
  "again: a run with nothing pending changes nothing and posts nothing"

# Requests that must never be applied.
untrusted_case() {  # untrusted_case <name> <comment line>
  local c
  c=$(new_case "$1")
  printf '%s\n' "$2" > "$c/comments.jsonl"
  run_case "$c"
  printf '%s' "$c"
}
REQ=$(request 1 '{pr: 7, title: "Injected", reply: "Injected"}')
C=$(untrusted_case forged "$(comment 13 mallory User 30 "$REQ")")
check '[ "$(cat "$C/rc")" = 0 ] && nothing_written "$C"' "forged: a request written by a person is ignored"
C=$(untrusted_case other-bot "$(comment 13 'gh-app-write[bot]' Bot 30 "$REQ")")
check 'nothing_written "$C"' "other-bot: a request from any other bot is ignored"
C=$(untrusted_case stale "$(comment 13 'forge-gh-app[bot]' Bot 90000 "$REQ")")
check 'nothing_written "$C"' "stale: a request older than a day is ignored"
C=$(untrusted_case recent "$(comment 13 'forge-gh-app[bot]' Bot 7200 "$REQ")")
check '[ "$(jq -r .title "$C/pr_patch.jsonl")" = Injected ]' \
  "recent: a request that waited two hours for a busy runner is still applied"
TRUNCATED=$(request 1 '{pr: 7, body: "x"}' | sed '/forge-slack-pr-text-body/,$d')
C=$(untrusted_case truncated "$(comment 13 'forge-gh-app[bot]' Bot 30 "$TRUNCATED")")
check '[ ! -s "$C/pr_patch.jsonl" ] && [ ! -s "$C/pr_comments.jsonl" ] && [ "$(marks "$C" skipped)" = 13 ] && [[ "$(slack_text "$C")" == *"could not be read"* ]]' \
  "truncated: a request whose description section is missing never blanks the PR, and is reported"

# A PR that does not close this issue is skipped and reported.
C=$(new_case unrelated-pr)
comment 14 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 99, title: "x"}')" > "$C/comments.jsonl"
echo '{"data": {"repository": {"pullRequest": {"state": "OPEN", "body": "Refs #1213", "closingIssuesReferences": {"nodes": [{"number": 5}]}, "reviewThreads": {"nodes": []}}}}}' > "$C/pr_99.json"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_patch.jsonl" ] && [[ "$(slack_text "$C")" == *"not an open PR that closes #1213"* ]]' \
  "unrelated-pr: a PR that only mentions the issue is not edited"
check '[ "$(marks "$C" skipped)" = 14 ]' \
  "unrelated-pr: the skipped request is marked, so no later run reports or applies it again"

C=$(new_case closes-by-body)
comment 15 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 8, title: "fix: x"}')" > "$C/comments.jsonl"
echo '{"data": {"repository": {"pullRequest": {"state": "OPEN", "body": "Some text\n\nFixes #1213", "closingIssuesReferences": {"nodes": []}, "reviewThreads": {"nodes": []}}}}}' > "$C/pr_8.json"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(jq -r .pr "$C/pr_patch.jsonl")" = 8 ]' \
  "closes-by-body: a closing keyword in the description counts, as forge-agent reads it"

# Every pending request on the issue is applied, oldest first, whatever
# Slack message asked; each thread hears about its own. Only the last of
# several replies to one PR is posted, with one watermark.
C=$(new_case many)
{
  comment 21 'forge-gh-app[bot]' Bot 20 "$(request 2 '{pr: 7, reply: "Second reply", watermark: true}')"
  comment 20 'forge-gh-app[bot]' Bot 25 "$(request 1 '{pr: 7, title: "fix: one\nline", reply: "First reply", watermark: true}')"
  comment 22 'forge-gh-app[bot]' Bot 10 "$(request 1 '{pr: 7, ts: "6.6", ch: "C2", th: "2.2", title: "fix: from another message"}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(marks "$C" applied)" = "20,21,22" ]' \
  "many: every pending request is applied, oldest first"
check '[ "$(jq -sr "map(.title) | join(\"|\")" "$C/pr_patch.jsonl")" = "fix: from another message" ]' \
  "many: only the last title to a PR is written"
check '[[ "$(slack_text "$C")" == *"your title edit wasn'"'"'t applied: a newer title to #7 from Forge replaced it"* ]]' \
  "many: the request whose title was replaced is told so"
check '[ "$(jq -sr "map(.body | split(\"\n\")[0]) | join(\"|\")" "$C/pr_comments.jsonl")" = "<!-- forge-revise-reply -->|<!-- forge-revise-instructions -->" ] && [ "$(jq -sr ".[0].body | split(\"\\n\")[-1]" "$C/pr_comments.jsonl")" = "Second reply" ]' \
  "many: only the last reply to a PR is posted, with one watermark"
check '[ "$(jq -sr "map(.channel) | sort | join(\",\")" "$C/slack.jsonl")" = "C2,C9" ]' \
  "many: each Slack thread hears about its own requests"

# A reply that fails leaves the review owed: no watermark, no resolved thread.
C=$(new_case reply-fails)
comment 23 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, reply: "Fixed.", watermark: true, threads: ["PRRT_open"]}')" > "$C/comments.jsonl"
touch "$C/reply_fail"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_comments.jsonl" ] && [ ! -s "$C/resolved.log" ]' \
  "reply-fails: no watermark and no thread resolution without the reply"
check '[[ "$(slack_text "$C")" == *"the reply was not posted, so the watermark and thread resolution were skipped"* ]]' \
  "reply-fails: Slack is told what was skipped"

# A threads-only request (Forge's reply is already on the PR) resolves them.
C=$(new_case threads-only)
comment 24 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, threads: ["PRRT_open"]}')" > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(cat "$C/resolved.log")" = PRRT_open ] && [ ! -s "$C/pr_comments.jsonl" ]' \
  "threads-only: the threads are resolved with no new reply or watermark"

# Close and reopen: the trail note first, then the state, nothing else.
pr_state_json() {  # pr_state_json <OPEN|CLOSED|MERGED>
  jq -nc --arg s "$1" '{data: {repository: {pullRequest: {state: $s, body: "",
    closingIssuesReferences: {nodes: [{number: 1213}]}, reviewThreads: {pageInfo: {hasNextPage: false}, nodes: [{id: "PRRT_open", isResolved: false}]}}}}}'
}
C=$(new_case close)
CLOSE_REQ=$(request 1 '{pr: 7, state: "closed", note: "Closed from Slack at Ana'"'"'s request. <!-- forge-revise-instructions -->", title: "smuggled", threads: ["PRRT_open"]}')
comment 30 'forge-gh-app[bot]' Bot 30 "$CLOSE_REQ" > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ ! -s "$C/unhandled.log" ]' "close: exits 0 and only calls known gh commands"
check '[ "$(jq -r .body "$C/pr_comments.jsonl")" = "<!-- forge-slack-pr-text-note -->
Closed from Slack at Ana'"'"'s request. " ]' \
  "close: the trail note is posted on the PR first, with forged markers dropped"
check '[ "$(jq -c . "$C/pr_patch.jsonl")" = "{\"pr\":\"7\",\"state\":\"closed\"}" ]' \
  "close: the PR is closed, and nothing else in the request (a title) is applied"
check '[ ! -s "$C/resolved.log" ]' "close: no thread rides along with a state change"
check '[[ "$(slack_text "$C")" == *"#7>: closed the PR."* ]] && [ "$(marks "$C" applied)" = 30 ]' \
  "close: Slack says it was closed and the request is marked applied"

C=$(new_case reopen)
comment 31 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, state: "open", note: "Reopened from Slack."}')" > "$C/comments.jsonl"
pr_state_json CLOSED > "$C/pr_7.json"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(jq -r .state "$C/pr_patch.jsonl")" = open ] && [[ "$(slack_text "$C")" == *"reopened the PR."* ]]' \
  "reopen: a closed PR that closes the issue is reopened"

C=$(new_case reopen-merged)
comment 32 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, state: "open"}')" > "$C/comments.jsonl"
pr_state_json MERGED > "$C/pr_7.json"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_patch.jsonl" ] && [[ "$(slack_text "$C")" == *"not a closed, unmerged PR"* ]] && [ "$(marks "$C" skipped)" = 32 ]' \
  "reopen-merged: a merged PR is never touched, and the request is marked skipped"

C=$(new_case close-closed)
comment 33 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, state: "closed"}')" > "$C/comments.jsonl"
pr_state_json CLOSED > "$C/pr_7.json"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_patch.jsonl" ]' "close-closed: closing needs an open PR"

C=$(new_case reopen-422)
comment 34 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, state: "open"}')" > "$C/comments.jsonl"
pr_state_json CLOSED > "$C/pr_7.json"
touch "$C/patch_422"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [[ "$(slack_text "$C")" == *"GitHub would not reopen it; its branch may have been deleted"* ]]' \
  "reopen-422: a refused reopen says why"

# A superseded reply's threads move to the reply that replaces it: they close
# once, after that reply posts, and not at all if it fails.
C=$(new_case superseded-threads)
{
  comment 40 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, reply: "First", watermark: true, threads: ["PRRT_open"]}')"
  comment 41 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, reply: "Second", watermark: true}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(cat "$C/resolved.log")" = PRRT_open ] && [ "$(jq -sr ".[0].body | split(\"\\n\")[-1]" "$C/pr_comments.jsonl")" = Second ] && [ "$(wc -l < "$C/pr_comments.jsonl" | tr -d " ")" = 2 ]' \
  "superseded-threads: one reply, one watermark, and the thread closes with the reply that replaced the first"
C=$(new_case superseded-reply-fails)
cp "$TMP/superseded-threads/comments.jsonl" "$C/comments.jsonl"
touch "$C/reply_fail"
run_case "$C"
check '[ ! -s "$C/resolved.log" ] && [ ! -s "$C/pr_comments.jsonl" ]' \
  "superseded-reply-fails: no thread closes and no watermark lands when the surviving reply fails"

# A reply that is only an HTML comment is no reply: no watermark, no threads.
C=$(new_case empty-reply)
comment 42 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, reply: "<!-- addressed -->", watermark: true, threads: ["PRRT_open"]}')" > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_comments.jsonl" ] && [ ! -s "$C/resolved.log" ] && [[ "$(slack_text "$C")" == *"no reply text"* ]]' \
  "empty-reply: a reply that scrubs to nothing never posts the watermark or resolves threads"
C=$(new_case blank-reply-no-watermark)
comment 44 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, reply: "   ", threads: ["PRRT_open"]}')" > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_comments.jsonl" ] && [ ! -s "$C/resolved.log" ] && [[ "$(slack_text "$C")" == *"no reply text"* ]]' \
  "blank-reply-no-watermark: a whitespace-only reply resolves no thread, even without a watermark"

# A request that cannot be claimed is left alone: nothing is done twice.
C=$(new_case claim-fails)
comment 43 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: x", reply: "Fixed."}')" > "$C/comments.jsonl"
touch "$C/claim_fail"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_patch.jsonl" ] && [ ! -s "$C/pr_comments.jsonl" ]' \
  "claim-fails: a request that cannot be claimed is not applied, so no later run can repeat it"

# Forge's other comments on the issue (an analysis, an applied request) are
# skipped, never a parse error: the request next to them is applied.
C=$(new_case mixed-comments)
{
  comment 50 'forge-gh-app[bot]' Bot 40 '<!-- forge-analysis -->
Analysis of the issue.'
  comment 51 'forge-gh-app[bot]' Bot 35 '<!-- forge-slack-pr-text-applied {"ts":"1.1","seq":1,"pr":7} -->
Forge applied this request to #7.'
  comment 56 'forge-gh-app[bot]' Bot 34 '<!-- forge-slack-pr-text-skipped {"ts":"1.1","seq":2,"pr":7} -->
Forge skipped this request.'
  comment 57 'forge-gh-app[bot]' Bot 33 '<!-- forge-slack-pr-text-interrupted {"ts":"1.1","seq":3,"pr":7} -->
Forge stopped before it finished.'
  comment 58 'forge-gh-app[bot]' Bot 32 'A plain comment with no marker at all.'
  comment 52 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: mixed"}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(jq -r .title "$C/pr_patch.jsonl")" = "fix: mixed" ] && [ "$(marks "$C" applied)" = 52 ]' \
  "mixed-comments: Forge's other comments are skipped and the request is applied"

# A run cancelled part-way reports what it claimed but did not finish, and
# marks it interrupted, so it is neither lost silently nor applied twice.
C=$(new_case cancelled)
comment 53 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: x", reply: "Fixed.", watermark: true}')" > "$C/comments.jsonl"
touch "$C/die_on_reply"
run_case "$C"
check '[ "$(cat "$C/rc")" != 0 ] && [ "$(marks "$C" interrupted)" = 53 ] && [ -z "$(marks "$C" applied)" ]' \
  "cancelled: a claimed request the run did not finish is marked interrupted"
check '[[ "$(slack_text "$C")" == *"stopped before it finished"* ]] && [ "$(jq -rs ".[0].channel" "$C/slack.jsonl")" = C9 ]' \
  "cancelled: the request's own thread is told to check the PR"

# A claim left by a lost runner (no exit handler ran) is reported by the next
# run, not re-applied.
C=$(new_case stale-claim)
comment 54 'forge-gh-app[bot]' Bot 2000 '<!-- forge-slack-pr-text-claimed {"ts":"5.5","seq":1,"pr":7,"ch":"C9","th":"9.9"} -->
Forge is applying this request to #7.' > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(marks "$C" interrupted)" = 54 ] && [ ! -s "$C/pr_patch.jsonl" ] && [[ "$(slack_text "$C")" == *"stopped before it finished"* ]]' \
  "stale-claim: an old unfinished claim is reported as interrupted and nothing is re-applied"
C=$(new_case fresh-claim)
comment 55 'forge-gh-app[bot]' Bot 60 '<!-- forge-slack-pr-text-claimed {"ts":"5.5","seq":1,"pr":7,"ch":"C9","th":"9.9"} -->
Forge is applying this request to #7.' > "$C/comments.jsonl"
run_case "$C"
check '[ -z "$(marks "$C" interrupted)" ] && [ ! -s "$C/slack.jsonl" ]' \
  "fresh-claim: a claim a running job may still be working on is left alone"

# A closing reference to another repository's #1213 is not this issue.
C=$(new_case cross-repo-close)
comment 60 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: x"}')" > "$C/comments.jsonl"
echo '{"data": {"repository": {"pullRequest": {"state": "OPEN", "body": "Closes other/repo#1213", "closingIssuesReferences": {"nodes": [{"number": 1213, "repository": {"nameWithOwner": "other/repo"}}]}, "reviewThreads": {"nodes": []}}}}}' > "$C/pr_7.json"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_patch.jsonl" ] && [ "$(marks "$C" skipped)" = 60 ]' \
  "cross-repo-close: a PR that closes another repository's #1213 is not edited"
C=$(new_case same-repo-node)
comment 61 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: y"}')" > "$C/comments.jsonl"
echo '{"data": {"repository": {"pullRequest": {"state": "OPEN", "body": "", "closingIssuesReferences": {"nodes": [{"number": 1213, "repository": {"nameWithOwner": "O/R"}}]}, "reviewThreads": {"nodes": []}}}}}' > "$C/pr_7.json"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(jq -r .title "$C/pr_patch.jsonl")" = "fix: y" ]' \
  "same-repo-node: a closing reference to this repository (any case) counts"

# The final mark is retried once; if it still fails, Slack is told the
# request may later be called interrupted by mistake.
C=$(new_case mark-fails)
comment 62 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: z"}')" > "$C/comments.jsonl"
touch "$C/applied_mark_fail"
run_case "$C"
check '[ "$(wc -l < "$C/applied_mark_attempts" | tr -d " ")" = 2 ] && [ "$(jq -r .title "$C/pr_patch.jsonl")" = "fix: z" ]' \
  "mark-fails: the final mark is tried twice and the edit itself still lands"
check '[[ "$(slack_text "$C")" == *"I couldn'"'"'t mark the request done on #1213"* ]] && [ -z "$(marks "$C" interrupted)" ]' \
  "mark-fails: Slack is told, and the run does not call its own finished request interrupted"

# --- review round (Nijil, #214) ----------------------------------------------
# A superseded reply's watermark moves to the reply that replaces it.
C=$(new_case superseded-watermark)
{
  comment 70 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, reply: "First", watermark: true}')"
  comment 71 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, reply: "Second"}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(jq -sr "map(.body | split(\"\\n\")[0]) | join(\"|\")" "$C/pr_comments.jsonl")" = "<!-- forge-revise-reply -->|<!-- forge-revise-instructions -->" ]' \
  "superseded-watermark: the watermark the first reply asked for lands with the reply that replaced it"
check '[[ "$(slack_text "$C")" == *"your reply wasn'"'"'t posted: a newer reply to #7 from Forge replaced it"* ]]' \
  "superseded-watermark: the superseded request is told its reply was replaced, not \"nothing changed\""

# A request that cannot be claimed never takes over another one's reply.
C=$(new_case claim-fails-winner)
{
  comment 72 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, reply: "First", threads: ["PRRT_open"]}')"
  comment 73 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, reply: "Second"}')"
} > "$C/comments.jsonl"
touch "$C/claim_fail_73"
run_case "$C"
check '[ "$(jq -sr ".[0].body | split(\"\\n\")[-1]" "$C/pr_comments.jsonl")" = First ] && [ "$(cat "$C/resolved.log")" = PRRT_open ]' \
  "claim-fails-winner: the claimed request keeps its reply and threads when the later one cannot be claimed"
check '[[ "$(slack_text "$C")" == *"I couldn'"'"'t start this change"* ]] && [ -z "$(marks "$C" claimed | grep 73)" ]' \
  "claim-fails-winner: the unclaimed request's thread is told, and it stays pending"

# A close/reopen request never takes part in superseding.
C=$(new_case state-with-reply)
{
  comment 74 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, reply: "Answer", threads: ["PRRT_open"]}')"
  comment 75 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, state: "closed", note: "Closed.", reply: "Ignored", threads: ["PRRT_x"]}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(jq -sr "map(.body) | join(\"|\")" "$C/pr_comments.jsonl")" = "<!-- forge-revise-reply -->
Answer|<!-- forge-slack-pr-text-note -->
Closed." ] && [ "$(cat "$C/resolved.log")" = PRRT_open ] && [ "$(jq -r .state "$C/pr_patch.jsonl")" = closed ]' \
  "state-with-reply: the earlier reply and thread survive, and the close posts only its note"

# Slack's ok:false is a visible warning.
C=$(new_case slack-error)
comment 76 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: x"}')" > "$C/comments.jsonl"
touch "$C/slack_error"
run_case "$C"
check 'grep -q "::warning::Slack did not post the result to C9: not_in_channel" "$C/run.log"' \
  "slack-error: Slack's ok:false is reported in the log"

# An early exit still delivers the reports of requests that finished.
C=$(new_case early-exit-reports)
{
  comment 77 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, title: "fix: finished"}')"
  comment 78 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 8, reply: "Cut off."}')"
} > "$C/comments.jsonl"
jq -n '{data: {repository: {pullRequest: {state: "OPEN", body: "Closes #1213", closingIssuesReferences: {nodes: []}, reviewThreads: {pageInfo: {hasNextPage: false}, nodes: []}}}}}' > "$C/pr_8.json"
touch "$C/die_on_reply"
run_case "$C"
check '[[ "$(slack_text "$C")" == *"#7>: updated the title."* ]] && [ "$(marks "$C" interrupted)" = 78 ]' \
  "early-exit-reports: the finished request is still reported, and the cut-off one is interrupted"

# Nothing is applied while a Forge run works on the issue.
C=$(new_case forge-running)
comment 79 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: x", reply: "Fixed."}')" > "$C/comments.jsonl"
touch "$C/forge_running"
run_case "$C"
check '[ ! -s "$C/pr_patch.jsonl" ] && [ ! -s "$C/pr_comments.jsonl" ] && [ "$(marks "$C" skipped)" = 79 ]' \
  "forge-running: nothing is applied and the request is marked skipped"
check '[[ "$(slack_text "$C")" == *"a Forge run is working on #1213 right now, so nothing was changed"* ]]' \
  "forge-running: the thread is told to ask again when the run finishes"

# Threads on later pages are read too; a thread id that is not on the PR is
# never sent to GitHub.
C=$(new_case many-threads)
comment 80 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, threads: ["PRRT_far", "PRRT_done", "PRRT_foreign"]}')" > "$C/comments.jsonl"
echo '{"id":"PRRT_far","isResolved":false,"comments":{"nodes":[{"createdAt":"2020-01-01T00:00:00Z"}]}}' > "$C/threads_extra_7.jsonl"
run_case "$C"
check '[ "$(cat "$C/resolved.log")" = PRRT_far ] && grep -q "graphql --paginate" "$C/gh.log"' \
  "many-threads: a thread from a later page is resolved; a resolved one and a foreign id are not"

# Replies and notes are cleaned like the revise job's replies.
C=$(new_case scrubbed)
TOKEN="gh""p_$(printf 'Z%.0s' $(seq 1 28))"
comment 81 'forge-gh-app[bot]' Bot 30 "$(request 1 "$(jq -nc --arg t "$TOKEN" '{pr: 7, reply: ("Thanks @someone and @org/team, @channel. Token " + $t)}')")" > "$C/comments.jsonl"
run_case "$C"
POSTED=$(jq -sr ".[0].body" "$C/pr_comments.jsonl")
check '[[ "$POSTED" == *"Thanks someone and org/team, channel. Token ***"* ]] && [[ "$POSTED" != *"@"* ]]' \
  "scrubbed: mentions lose their @, @channel is dropped, and a token is masked (got: $POSTED)"

# A stale claim whose run succeeded was applied: mark it so, quietly.
C=$(new_case stale-claim-succeeded)
comment 82 'forge-gh-app[bot]' Bot 2000 '<!-- forge-slack-pr-text-claimed {"ts":"5.5","seq":1,"pr":7,"ch":"C9","th":"9.9","rp":false,"run":4242,"attempt":2} -->
Forge is applying this request to #7.' > "$C/comments.jsonl"
echo failure > "$C/run_4242_1"
echo success > "$C/run_4242_2"
run_case "$C"
check '[ "$(marks "$C" applied)" = 82 ] && [ -z "$(marks "$C" interrupted)" ] && [ ! -s "$C/slack.jsonl" ]' \
  "stale-claim-succeeded: a claim whose run succeeded is marked applied, with no false alarm"

# The shared strings and cleaning are the forge job's own, not drifting copies.
job_def() {  # job_def <job id> <first line> <last line>: that block inside the job
  # Reads to the end (no exit): an early exit would SIGPIPE job_block under pipefail.
  job_block "$1" | awk -v a="$2" -v b="$3" 'done {next} $0 == a {f=1} f {print} f && $0 == b {f=0; done=1}'
}
FORGE_CLEAN=$(job_def forge "          CLEAN_JQ='" "          '")
PRTEXT_CLEAN=$(job_def pr-text "          CLEAN_JQ='" "          '")
check '[ -n "$FORGE_CLEAN" ] && [ "$FORGE_CLEAN" = "$PRTEXT_CLEAN" ]' "pr-text's CLEAN_JQ is the forge job's, byte for byte"
FORGE_SCRUB=$(job_def forge "          scrub_secrets() {" "          }")
PRTEXT_SCRUB=$(job_def pr-text "          scrub_secrets() {" "          }")
check '[ -n "$FORGE_SCRUB" ] && [ "$FORGE_SCRUB" = "$PRTEXT_SCRUB" ]' "pr-text's scrub_secrets is the forge job's, byte for byte"
FORGE_WM=$(printf '%s\n' "$FORGE_JOB" | grep -A1 "body=\$(printf '%s\\\\n%s' '<!-- forge-revise-instructions -->'" | sed -n "s/.*'\(<[^']*\)'.*/\1/p" | tr '\n' '|')
PRTEXT_WM=$(printf '%s\n' "$PR_TEXT_JOB" | grep -A1 "WATERMARK_BODY=\$(printf" | sed -n "s/.*'\(<[^']*\)'.*/\1/p" | tr '\n' '|')
check '[ -n "$FORGE_WM" ] && [ "$FORGE_WM" = "$PRTEXT_WM" ]' "pr-text's watermark body is post_silent_watermark's (got: $PRTEXT_WM)"
FORGE_REPLY_WRITER="printf '%s\\n' '<!-- forge-revise-reply -->'"
PRTEXT_REPLY_MARKER="REPLY_MARKER='<!-- forge-revise-reply -->'"
check '[[ "$FORGE_JOB" == *"$FORGE_REPLY_WRITER"* ]] && [[ "$PR_TEXT_JOB" == *"$PRTEXT_REPLY_MARKER"* ]]' \
  "pr-text's reply marker is the one the revise reply writers post"

# --- review round 2 (Nijil, Kimi) -------------------------------------------
# A later reply that is empty once cleaned never replaces an earlier one.
C=$(new_case later-empty-reply)
{
  comment 90 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, reply: "Fixed X", threads: ["PRRT_open"], watermark: true}')"
  comment 91 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, reply: "<!-- nothing -->"}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(jq -sr ".[0].body" "$C/pr_comments.jsonl")" = "<!-- forge-revise-reply -->
Fixed X" ] && [ "$(cat "$C/resolved.log")" = PRRT_open ]' \
  "later-empty-reply: the earlier reply, watermark and thread survive a later empty reply"

# forge:running on the PR itself (a revise on the PR work item) is seen too.
C=$(new_case pr-running)
comment 92 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: x"}')" > "$C/comments.jsonl"
touch "$C/pr_running_7"
run_case "$C"
check '[ ! -s "$C/pr_patch.jsonl" ] && [ "$(marks "$C" skipped)" = 92 ] && [[ "$(slack_text "$C")" == *"a Forge run is working on #7 right now"* ]]' \
  "pr-running: a Forge run labelled on the PR stops the edit"

# Something said on the PR after the request: no watermark, the thread with
# a later comment stays open, the reply still posts.
C=$(new_case newer-review)
comment 93 'forge-gh-app[bot]' Bot 3600 "$(request 1 '{pr: 7, reply: "Fixed.", watermark: true, threads: ["PRRT_old", "PRRT_new"]}')" > "$C/comments.jsonl"
jq -n --arg recent "$(jq -nr 'now - 60 | floor | todate')" '{data: {repository: {pullRequest: {state: "OPEN", title: "t", body: "",
  closingIssuesReferences: {nodes: [{number: 1213}]},
  comments: {nodes: [{updatedAt: $recent, body: "## Claude review: request changes <!-- deriv-pr-review-claude -->"}, {updatedAt: $recent, body: "<!-- forge-revise-instructions --> mine"}]},
  reviews: {nodes: []},
  reviewThreads: {nodes: [
    {id: "PRRT_old", isResolved: false, comments: {nodes: [{createdAt: "2020-01-01T00:00:00Z"}]}},
    {id: "PRRT_new", isResolved: false, comments: {nodes: [{createdAt: $recent}]}}]}}}}}' > "$C/pr_7.json"
run_case "$C"
check '[ "$(jq -sr "map(.body | split(\"\\n\")[0]) | join(\"|\")" "$C/pr_comments.jsonl")" = "<!-- forge-revise-reply -->" ] && [ "$(cat "$C/resolved.log")" = PRRT_old ]' \
  "newer-review: the reply posts, the watermark does not, and only the quiet thread is resolved"
check '[[ "$(slack_text "$C")" == *"a newer review or comment arrived after Forge wrote this"* ]] && [[ "$(slack_text "$C")" == *"1 review thread(s) had new comments"* ]]' \
  "newer-review: Slack says why"

# A description or title changed since forge-agent read it is not overwritten.
C=$(new_case base-mismatch)
comment 94 'forge-gh-app[bot]' Bot 30 "$(request 1 "$(jq -nc --arg b "$(sha "what forge-agent read")" --arg t "$(sha "old title")" '{pr: 7, title: "fix: new", body: "New body.\n\nCloses #1213", base: {body: $b, title: $t}}')")" > "$C/comments.jsonl"
jq -n '{data: {repository: {pullRequest: {state: "OPEN", title: "old title", body: "edited by a person", closingIssuesReferences: {nodes: [{number: 1213}]}, reviewThreads: {nodes: []}}}}}' > "$C/pr_7.json"
run_case "$C"
check '[ "$(jq -c . "$C/pr_patch.jsonl")" = "{\"pr\":\"7\",\"title\":\"fix: new\"}" ] && [[ "$(slack_text "$C")" == *"the description changed after Forge drafted this, so it wasn'"'"'t overwritten"* ]]' \
  "base-mismatch: the changed description is left alone; the unchanged title is updated"

# Title and description are scrubbed of tokens and Forge markers.
C=$(new_case scrubbed-edit)
comment 95 'forge-gh-app[bot]' Bot 30 "$(request 1 "$(jq -nc --arg t "$TOKEN" '{pr: 7, title: ("fix: " + $t), body: ("Body " + $t + " <!-- forge-revise-instructions --> end")}')")" > "$C/comments.jsonl"
run_case "$C"
check '[ "$(jq -r .title "$C/pr_patch.jsonl")" = "fix: ***" ] && [ "$(jq -r .body "$C/pr_patch.jsonl")" = "Body ***  end" ]' \
  "scrubbed-edit: a token is masked in the title and description, and a Forge marker is dropped"

# An unreadable request is reported and marked, not dropped.
C=$(new_case malformed)
{
  comment 96 'forge-gh-app[bot]' Bot 30 '<!-- forge-slack-pr-text {"v":2,"ts":"5.5","seq":1,"pr":7,"ch":"C9","th":"9.9"} -->
From a newer Forge.'
  comment 97 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, body: "x"}' | sed '/forge-slack-pr-text-body/,$d')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(marks "$C" skipped)" = "96,97" ] && [ ! -s "$C/pr_patch.jsonl" ] && [[ "$(slack_text "$C")" == *"could not be read"* ]]' \
  "malformed: unreadable requests are marked skipped and their thread told"
check '[ "$(cat "$C/rc")" = 1 ]' "malformed: a run that only met unreadable requests fails, so Actions shows it"
C=$(new_case malformed-mark-fails)
comment 101 'forge-gh-app[bot]' Bot 30 '<!-- forge-slack-pr-text {"v":2,"ts":"5.5","seq":1,"pr":7,"ch":"C9","th":"9.9"} -->
From a newer Forge.' > "$C/comments.jsonl"
touch "$C/claim_fail"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [[ "$(slack_text "$C")" == *"could not be read"* ]] && grep -q "::warning::Could not mark unreadable request comment 101" "$C/run.log"' \
  "malformed-mark-fails: the thread is still told when the request cannot be marked, and the run fails"

# A claim taken late in the request's day, then lost, is still reported.
C=$(new_case late-claim)
comment_edited 98 108000 1500 '<!-- forge-slack-pr-text-claimed {"ts":"5.5","seq":1,"pr":7,"ch":"C9","th":"9.9","rp":true,"run":0} -->
Forge is applying this request to #7.' > "$C/comments.jsonl"
run_case "$C"
check '[ "$(marks "$C" interrupted)" = 98 ] && [[ "$(jq -r .body "$C/applied.jsonl")" == *"\"rp\":true"* ]]' \
  "late-claim: a claim judged by its claim time is reported, and its rp is kept"

# A superseded request that also edited the title says both.
C=$(new_case superseded-with-title)
{
  comment 99 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, title: "fix: t", reply: "First"}')"
  comment 100 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, reply: "Second"}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[[ "$(slack_text "$C")" == *"updated the title, your reply wasn'"'"'t posted: a newer reply to #7 from Forge replaced it"* ]]' \
  "superseded-with-title: the title edit and the replaced reply are both reported"

# --- review round (Ako and Kimi, #214) ---------------------------------------
# The lock: forge:pr-text goes on the issue and the PR after the claim and
# before any PR is read, and comes off on every exit.
C="$TMP/happy"
check '[ "$(cat "$C/labels.log")" = "--add-label 1213 forge:pr-text
--add-label 7 forge:pr-text
--remove-label 1213 forge:pr-text
--remove-label 7 forge:pr-text" ]' "lock: forge:pr-text is set on the issue and the PR, then removed"
FIRST_CLAIM=$(grep -n -m1 "^api --method PATCH repos/o/r/issues/comments/" "$C/gh.log" | cut -d: -f1)
FIRST_LOCK=$(grep -n -m1 "^api --method POST repos/o/r/issues/1213/labels" "$C/gh.log" | cut -d: -f1)
FIRST_READ=$(grep -n -m1 "^api graphql" "$C/gh.log" | cut -d: -f1)
check '[ "$FIRST_CLAIM" -lt "$FIRST_LOCK" ] && [ "$FIRST_LOCK" -lt "$FIRST_READ" ]' \
  "lock: taken after the claim and before the first PR read (claim $FIRST_CLAIM, lock $FIRST_LOCK, read $FIRST_READ)"
C="$TMP/cancelled"
check '! grep -xF forge:pr-text "$C/labels_1213" "$C/labels_7" >/dev/null && [ "$(grep -c -- "--remove-label" "$C/labels.log")" = 2 ]' \
  "lock: a cancelled run still removes forge:pr-text"

C=$(new_case lock-fails)
comment 110 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: x", reply: "Done."}')" > "$C/comments.jsonl"
touch "$C/lock_fail"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ ! -s "$C/pr_patch.jsonl" ] && [ ! -s "$C/pr_comments.jsonl" ] && [ "$(marks "$C" skipped)" = 110 ] && ! grep "^api graphql" "$C/gh.log" >/dev/null' \
  "lock-fails: without the lock no PR is read or written, and the request is skipped"
check '[[ "$(slack_text "$C")" == *"couldn'"'"'t take the lock"* ]]' "lock-fails: Slack is told"

C=$(new_case issue-running)
comment 111 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: x"}')" > "$C/comments.jsonl"
touch "$C/forge_running"
run_case "$C"
check '[ ! -s "$C/pr_patch.jsonl" ] && [ "$(marks "$C" skipped)" = 111 ] && ! grep -xF forge:pr-text "$C/labels_1213" >/dev/null' \
  "issue-running: pr-text backs off from a Forge run on the issue and releases its lock"

# Each request reads the PR again, so one that reopens the PR lets a later
# edit through, and one that closes it stops a later edit.
C=$(new_case reopen-then-edit)
{
  comment 112 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, state: "open", note: "Reopened."}')"
  comment 113 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, title: "fix: after reopen"}')"
} > "$C/comments.jsonl"
pr_state_json CLOSED > "$C/pr_7.json"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(jq -sr "map(.state // .title) | join(\"|\")" "$C/pr_patch.jsonl")" = "open|fix: after reopen" ] && [ "$(marks "$C" applied)" = "112,113" ]' \
  "reopen-then-edit: the edit after a reopen lands"
C=$(new_case close-then-edit)
{
  comment 114 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, state: "closed", note: "Closed."}')"
  comment 115 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, title: "fix: after close"}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(jq -sr "map(.state // .title) | join(\"|\")" "$C/pr_patch.jsonl")" = closed ] && [ "$(marks "$C" skipped)" = 115 ]' \
  "close-then-edit: an edit after a close in the same run is skipped"

# The trail note a reopen posts is Forge's own, not a newer comment: a reply
# in the same run still gets its watermark.
C=$(new_case reopen-then-reply)
{
  comment 127 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, state: "open", note: "Reopened."}')"
  comment 128 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, reply: "Fixed.", watermark: true}')"
} > "$C/comments.jsonl"
jq -n '{data: {repository: {pullRequest: {state: "CLOSED", body: "", closingIssuesReferences: {nodes: [{number: 1213}]},
  comments: {nodes: [{updatedAt: (now | todate), body: "<!-- forge-slack-pr-text-note -->\nReopened."}]}, reviewThreads: {nodes: []}}}}}' > "$C/pr_7.json"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(jq -sr "map(.body | split(\"\\n\")[0]) | join(\"|\")" "$C/pr_comments.jsonl")" = "<!-- forge-slack-pr-text-note -->|<!-- forge-revise-reply -->|<!-- forge-revise-instructions -->" ]' \
  "reopen-then-reply: Forge's own trail note does not hold back the watermark"

# Two description edits to one PR: only the last is written.
C=$(new_case two-bodies)
{
  comment 116 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, body: "first body"}')"
  comment 117 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, body: "second body"}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(jq -sr "map(.body) | join(\"|\")" "$C/pr_patch.jsonl")" = "second body" ] && [ "$(marks "$C" applied)" = "116,117" ]' \
  "two-bodies: only the last description is written"
check '[[ "$(slack_text "$C")" == *"your description edit wasn'"'"'t applied: a newer description to #7 from Forge replaced it"* ]]' \
  "two-bodies: the first request is told its edit was replaced"

# A superseded reply whose replacement fails is a failure, not "replaced".
C=$(new_case superseded-winner-fails)
{
  comment 118 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, reply: "First"}')"
  comment 119 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, reply: "Second"}')"
} > "$C/comments.jsonl"
touch "$C/reply_fail"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [[ "$(slack_text "$C")" == *"your reply wasn'"'"'t posted, and the newer reply to #7 that replaced it did not land either"* ]]' \
  "superseded-winner-fails: the replaced request reports the failure"

# Requests of the wrong shape are reported, and the others still apply.
C=$(new_case bad-shapes)
{
  comment 120 'forge-gh-app[bot]' Bot 40 '<!-- forge-slack-pr-text {"v":1,"seq":1,"pr":7,"title":"a>b"} -->
Forge is updating the PR (requested from Slack).'
  comment 121 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, reply: "x", threads: "PRRT_open"}')"
  comment 122 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, title: "t", base: "abc"}')"
  comment 123 'forge-gh-app[bot]' Bot 10 "$(request 1 '{pr: 8, title: "fix: ok"}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ "$(marks "$C" skipped)" = "120,121,122" ] && [ "$(jq -sr "map(\"\(.pr):\(.title)\") | join(\"|\")" "$C/pr_patch.jsonl")" = "8:fix: ok" ]' \
  "bad-shapes: a raw > in the JSON, a threads string and a base string are reported; the valid request applies"

# A title or description keeps the @mentions already in it; new ones lose their @.
C=$(new_case mentions)
comment 124 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "ping @carol and @dave", body: "cc @alice and @bob"}')" > "$C/comments.jsonl"
jq -n '{data: {repository: {pullRequest: {state: "OPEN", title: "for @Dave", body: "cc @alice", closingIssuesReferences: {nodes: [{number: 1213}]}, reviewThreads: {nodes: []}}}}}' > "$C/pr_7.json"
run_case "$C"
check '[ "$(jq -r .body "$C/pr_patch.jsonl")" = "cc @alice and bob" ] && [ "$(jq -r .title "$C/pr_patch.jsonl")" = "ping carol and @dave" ]' \
  "mentions: existing mentions keep their @, new ones lose it"

# A closing keyword inside an HTML comment or fenced code does not count.
C=$(new_case closes-in-comment)
comment 125 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 8, title: "fix: x"}')" > "$C/comments.jsonl"
jq -n '{data: {repository: {pullRequest: {state: "OPEN", body: "<!-- Closes #1213 -->\n```\nFixes #1213\n```\nRelated to #1213", closingIssuesReferences: {nodes: []}, reviewThreads: {nodes: []}}}}}' > "$C/pr_8.json"
run_case "$C"
check '[ ! -s "$C/pr_patch.jsonl" ] && [ "$(marks "$C" skipped)" = 125 ] && [[ "$(slack_text "$C")" == *"not an open PR that closes #1213"* ]]' \
  "closes-in-comment: a closing keyword in a comment or code block is not a closing reference"

C=$(new_case one-line-title)
comment 126 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: one\nline"}')" > "$C/comments.jsonl"
run_case "$C"
check '[ "$(jq -r .title "$C/pr_patch.jsonl")" = "fix: one line" ]' "one-line-title: a title stays one line"

# The forge job's half of the handshake: "Claim the issue" waits while
# forge:pr-text is on the issue, after setting forge:running.
CLAIM=$(step_script "Claim the issue")
check '[[ "$CLAIM" == *"forge:pr-text|"* ]]' "the claim step creates the forge:pr-text label"
check 'awk '"'"'/--add-label "forge:running"/ {a=NR} /^wait_for_pr_text$/ {w=NR} END {exit !(a && w > a)}'"'"' <<< "$CLAIM"' \
  "the claim step waits for pr-text only after setting forge:running"
awk '/^wait_for_pr_text\(\) \{$/ {f=1} f {print} f && /^}$/ {exit}' <<< "$CLAIM" > "$TMP/wait.sh"
echo wait_for_pr_text >> "$TMP/wait.sh"
wait_case() {  # wait_case <name> [setup...] -> case dir
  local c rc=0
  c=$(new_case "$1"); shift
  : > "$c/labels_1213"
  for s in "$@"; do eval "$s"; done
  env -i PATH="$BIN:$PATH" FAKE_STATE="$c" GITHUB_REPOSITORY=o/r ISSUE_NUMBER=1213 \
    PR_TEXT_WAIT_SECONDS=0 PR_TEXT_WAIT_POLLS=3 bash -euo pipefail "$TMP/wait.sh" > "$c/run.log" 2>&1 || rc=$?
  echo "$rc" > "$c/rc"
  printf '%s' "$c"
}
reads() { wc -l < "$1/label_reads" | tr -d ' '; }
C=$(wait_case wait-none)
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(reads "$C")" = 1 ] && [ ! -s "$C/labels.log" ]' "wait: no forge:pr-text, no wait"
C=$(wait_case wait-clears 'echo forge:pr-text > "$c/labels_1213"' 'touch "$c/clear_after_3"')
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(reads "$C")" = 3 ] && [ ! -s "$C/labels.log" ] && [ "$(grep -c "waiting for it to finish" "$C/run.log")" = 1 ]' \
  "wait: waits while forge:pr-text is on the issue and goes ahead once it is removed"
C=$(wait_case wait-stale 'echo forge:pr-text > "$c/labels_1213"')
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(reads "$C")" = 4 ] && [ "$(cat "$C/labels.log")" = "--remove-label 1213 forge:pr-text" ] && grep -F "::warning::forge:pr-text stayed on #1213" "$C/run.log" >/dev/null' \
  "wait: a forge:pr-text left past pr-text's timeout is removed with a warning"
C=$(wait_case wait-read-fails 'touch "$c/labels_read_fail"')
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(reads "$C")" = 4 ] && grep -F "::warning::Could not read the labels on #1213" "$C/run.log" >/dev/null' \
  "wait: a label read that fails counts as the lock still held"

# A rejected command tells the Slack thread, with the command defanged.
step_script "Check the command" > "$TMP/check.sh"
C=$(new_case rejected-command)
rc=0
env -i PATH="$BIN:$PATH" FAKE_STATE="$C" FORGE_COMMAND='pr_text`<!here>' ISSUE_NUMBER=1213 \
  SLACK_CHANNEL=C1 SLACK_THREAD_TS=1.1 SLACK_BOT_TOKEN=xoxb-fake bash -e "$TMP/check.sh" > "$C/run.log" 2>&1 || rc=$?
REJECT=$(slack_text "$C")
check '[ "$rc" = 1 ] && [[ "$REJECT" == *"Forge didn'"'"'t start on #1213: \`pr_texthere\` is not a Forge command"* ]] && [[ "$REJECT" != *"<!here>"* ]] && [ "$(jq -r .thread_ts "$C/slack.jsonl")" = 1.1 ]' \
  "rejected-command: the Slack thread is told, with the command defanged (got: $REJECT)"
C=$(new_case rejected-command-no-slack)
rc=0
env -i PATH="$BIN:$PATH" FAKE_STATE="$C" FORGE_COMMAND=bogus ISSUE_NUMBER=1213 bash -e "$TMP/check.sh" > "$C/run.log" 2>&1 || rc=$?
check '[ "$rc" = 1 ] && [ ! -e "$C/slack.jsonl" ]' "rejected-command: no Slack call without a thread"
C=$(new_case rejected-command-bad-issue)
rc=0
env -i PATH="$BIN:$PATH" FAKE_STATE="$C" FORGE_COMMAND=$'bogus\n::add-mask::x' ISSUE_NUMBER='1 <!channel>' \
  SLACK_CHANNEL=C1 SLACK_THREAD_TS=1.1 SLACK_BOT_TOKEN=xoxb-fake bash -e "$TMP/check.sh" > "$C/run.log" 2>&1 || rc=$?
REJECT=$(slack_text "$C")
check '[ "$rc" = 1 ] && [[ "$REJECT" == "Forge didn'"'"'t start: \`bogus::add-mask::x\` is not a Forge command"* ]] && [[ "$REJECT" != *"<!channel>"* ]] && ! grep "^::add-mask" "$C/run.log" >/dev/null && grep -xF "::error::Unknown command '"'"'bogus::add-mask::x'"'"'. Use auto, revise, update or pr-text (callers must pass command through from workflow_dispatch)." "$C/run.log" >/dev/null' \
  "rejected-command-bad-issue: no raw issue number in Slack and no raw command in the log (got: $REJECT)"

# A Forge run that labels after pr-text's lock is waiting for it: pr-text
# keeps going. Only the read right after the lock backs off.
C=$(new_case running-after-lock)
{
  comment 130 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, title: "fix: first"}')"
  comment 131 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, reply: "Second."}')"
} > "$C/comments.jsonl"
touch "$C/running_from_read_2"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && [ "$(marks "$C" applied)" = 130,131 ] && [ "$(jq -r .title "$C/pr_patch.jsonl")" = "fix: first" ] && [ "$(wc -l < "$C/pr_comments.jsonl" | tr -d " ")" = 1 ] && [[ "$(slack_text "$C")" != *"working on"* ]]' \
  "running-after-lock: a forge:running set after the lock does not stop pr-text"

# A reply replaced by a later one keeps rp in its final mark.
C=$(new_case rp-superseded)
{
  comment 132 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, reply: "First."}')"
  comment 133 'forge-gh-app[bot]' Bot 10 "$(request 2 '{pr: 7, reply: "Second."}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(jq -sr "[.[] | select(.id == \"132\" and (.body | startswith(\"<!-- forge-slack-pr-text-applied \")))] | length" "$C/applied.jsonl")" = 1 ] && jq -se "[.[] | select(.id == \"132\" and (.body | startswith(\"<!-- forge-slack-pr-text-applied \")))][0].body | contains(\"\\\"rp\\\":true\")" "$C/applied.jsonl" >/dev/null' \
  "rp-superseded: the replaced request's final mark keeps rp:true"

# What counts as newer activity is what the revise job would act on.
# watermark_case <name> <comments jq array> -> case dir
watermark_case() {  # watermark_case <name> <comments jq array> [reviews jq array]
  local c
  c=$(new_case "$1")
  comment 134 'forge-gh-app[bot]' Bot 3600 "$(request 1 '{pr: 7, reply: "Fixed.", watermark: true}')" > "$c/comments.jsonl"
  jq -n --arg recent "$(jq -nr 'now - 60 | floor | todate')" --arg old "$(jq -nr 'now - 7200 | floor | todate')" \
    "{data: {repository: {pullRequest: {state: \"OPEN\", title: \"t\", body: \"\", closingIssuesReferences: {nodes: [{number: 1213}]},
      comments: {nodes: $2}, reviews: {nodes: ${3:-[]}}, reviewThreads: {nodes: []}}}}}" > "$c/pr_7.json"
  run_case "$c"
  printf '%s' "$c"
}
watermarked() { jq -se 'any(.[]; .body | startswith("<!-- forge-revise-instructions -->"))' "$1/pr_comments.jsonl" >/dev/null; }
C=$(watermark_case bot-comment-newer '[{createdAt: $old, updatedAt: $recent, body: "Preview ready", author: {__typename: "Bot", login: "cloudflare-workers-and-pages"}},
  {createdAt: $recent, updatedAt: $recent, body: "Deploying a preview", author: {__typename: "Bot", login: "vercel"}},
  {createdAt: $recent, updatedAt: $recent, body: "<!-- deriv-pr-review-progress-kimi --> reviewing", author: {__typename: "Bot", login: "github-actions"}}]')
check '[ "$(cat "$C/rc")" = 0 ] && watermarked "$C"' "bot-comment-newer: a preview bot's edit or a review placeholder does not hold the watermark"
C=$(watermark_case person-comment-newer '[{createdAt: $recent, updatedAt: $recent, body: "One more thing", author: {__typename: "User", login: "ana"}}]')
check '! watermarked "$C" && [[ "$(slack_text "$C")" == *"a newer review or comment arrived"* ]]' "person-comment-newer: a person's new comment holds the watermark"
C=$(watermark_case person-comment-edited '[{createdAt: $old, updatedAt: $recent, body: "Old note, edited", author: {__typename: "User", login: "ana"}}]')
check 'watermarked "$C"' "person-comment-edited: an edit to a person's earlier comment does not count (revise goes by when it was posted)"
C=$(watermark_case ai-review-newer '[{createdAt: $old, updatedAt: $recent, body: "Request changes <!-- deriv-pr-review-kimi -->", author: {__typename: "Bot", login: "github-actions"}}]')
check '! watermarked "$C"' "ai-review-newer: an AI review that finished after the request holds the watermark"
C=$(watermark_case person-quotes-marker '[{createdAt: $recent, updatedAt: $recent, body: "see <!-- forge-revise-reply --> above", author: {__typename: "User", login: "ana"}}]')
check 'watermarked "$C"' "person-quotes-marker: a comment revise ignores (it carries a Forge marker) does not hold the watermark"

C=$(watermark_case review-empty-newer '[]' '[{submittedAt: $recent, body: "", author: {__typename: "User", login: "ana"}}]')
check 'watermarked "$C"' "review-empty-newer: a person's approval or inline-only review (no summary) does not hold the watermark, as in filter_review_bodies"
C=$(watermark_case review-body-newer '[]' '[{submittedAt: $recent, body: "Please rename this", author: {__typename: "User", login: "ana"}}]')
check '! watermarked "$C"' "review-body-newer: a person's review with a summary holds the watermark"

# A review that finishes between the read and the watermark: the watermark is
# removed again, or the run fails when it cannot be.
C=$(new_case watermark-race)
comment 135 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, reply: "Fixed.", watermark: true}')" > "$C/comments.jsonl"
touch "$C/review_after_watermark"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ "$(cat "$C/deleted.log")" = 902 ] && [[ "$(slack_text "$C")" == *"a newer review arrived while Forge marked the reviews handled, so they are still owed"* ]]' \
  "watermark-race: a review that lands just before the watermark gets it removed again"
C=$(new_case watermark-race-delete-fails)
comment 136 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, reply: "Fixed.", watermark: true}')" > "$C/comments.jsonl"
touch "$C/review_after_watermark" "$C/wm_delete_fail"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [[ "$(slack_text "$C")" == *"the marker could not be removed, so ask me to revise"* ]]' \
  "watermark-race: a watermark that cannot be removed fails the run and says what to do"

C=$(new_case watermark-read-fails)
comment 139 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, reply: "Fixed.", watermark: true}')" > "$C/comments.jsonl"
touch "$C/after_read_fail"
run_case "$C"
check '[ "$(cat "$C/rc")" = 1 ] && [ "$(cat "$C/deleted.log")" = 902 ] && [[ "$(slack_text "$C")" == *"Forge couldn'"'"'t check the PR again after marking the reviews handled, so they are still owed"* ]]' \
  "watermark-read-fails: the watermark stays only after a read that shows nothing owed"

# The review-thread pages are read only for a request that resolves threads.
C=$(new_case threads-only-when-needed)
comment 137 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: x"}')" > "$C/comments.jsonl"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && ! grep -F -- "--paginate -f query=query" "$C/gh.log" >/dev/null' \
  "threads-only-when-needed: a title edit reads no review threads"
C=$(new_case threads-when-needed)
comment 138 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, reply: "Done.", threads: ["PRRT_open"]}')" > "$C/comments.jsonl"
run_case "$C"
check '[ "$(grep -cF -- "--paginate -f query=query" "$C/gh.log")" = 1 ] && [ "$(cat "$C/resolved.log")" = PRRT_open ]' \
  "threads-when-needed: a request that resolves threads reads them once"

# A title or description edit without the sha256 of the text it replaces is
# malformed, so the guard always runs.
C=$(new_case base-missing)
{
  comment 140 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: no base", base: {}}')"
  comment 141 'forge-gh-app[bot]' Bot 25 "$(request 1 '{pr: 7, body: "no base", base: {title: "x"}}')"
  comment 142 'forge-gh-app[bot]' Bot 20 "$(request 1 '{pr: 7, title: "fix: empty base", base: {title: ""}}')"
  comment 143 'forge-gh-app[bot]' Bot 10 "$(request 1 '{pr: 8, title: "fix: ok"}')"
} > "$C/comments.jsonl"
run_case "$C"
check '[ "$(marks "$C" skipped)" = 140,141,142 ] && [ "$(marks "$C" applied)" = 143 ] && [ "$(jq -r .pr "$C/pr_patch.jsonl")" = 8 ] && [ "$(cat "$C/rc")" = 1 ]' \
  "base-missing: a title or description without a base sha256 is malformed; the valid request still applies"

# Closing keywords inside a ~~~ fence or an unclosed fence do not count.
C=$(new_case fences)
comment 144 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 8, title: "fix: x"}')" > "$C/comments.jsonl"
jq -n '{data: {repository: {pullRequest: {state: "OPEN", title: "t", body: "~~~\nFixes #1213\n~~~\n```\nCloses #1213", closingIssuesReferences: {nodes: []}, reviewThreads: {nodes: []}}}}}' > "$C/pr_8.json"
run_case "$C"
check '[ ! -s "$C/pr_patch.jsonl" ] && [ "$(marks "$C" skipped)" = 144 ]' "fences: keywords in a ~~~ fence or an unclosed fence are not closing references"
C=$(new_case fences-outside)
comment 145 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 8, title: "fix: x"}')" > "$C/comments.jsonl"
jq -n '{data: {repository: {pullRequest: {state: "OPEN", title: "t", body: "~~~\ncode\n~~~\nFixes #1213", closingIssuesReferences: {nodes: []}, reviewThreads: {nodes: []}}}}}' > "$C/pr_8.json"
run_case "$C"
check '[ "$(jq -r .title "$C/pr_patch.jsonl")" = "fix: x" ]' "fences: a keyword after a closed ~~~ fence still counts"

# Releasing the lock is retried once; the warning says who clears it.
C=$(new_case unlock-retry)
comment 146 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: x"}')" > "$C/comments.jsonl"
touch "$C/unlock_fail_once"
run_case "$C"
check '[ "$(cat "$C/rc")" = 0 ] && ! grep -F "::warning::Could not remove forge:pr-text" "$C/run.log" >/dev/null && [ "$(grep -c -- "--remove-label" "$C/labels.log")" = 3 ]' \
  "unlock-retry: a removal refused once is retried"
C=$(new_case unlock-fails)
comment 147 'forge-gh-app[bot]' Bot 30 "$(request 1 '{pr: 7, title: "fix: x"}')" > "$C/comments.jsonl"
touch "$C/unlock_fail"
run_case "$C"
check 'grep -F "::warning::Could not remove forge:pr-text from #7. A Forge run started on #7 waits up to 10 minutes, then removes it; the next pr-text run that touches #7 also clears it." "$C/run.log" >/dev/null' \
  "unlock-fails: the warning says who clears a label left on a PR"

if [ "$fail" -ne 0 ]; then
  echo "forge-pr-text: FAILED"
  exit 1
fi
echo "forge-pr-text: all checks passed"
