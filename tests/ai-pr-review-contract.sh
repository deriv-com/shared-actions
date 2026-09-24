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
GUARD="$ROOT/.github/actions/ai_review_path_guard/path-guard.js"
GUARD_TEST="$ROOT/.github/actions/ai_review_path_guard/path-guard.test.js"

# Lines of $2 between the step named $1 and the next step, for "this step
# contains X" checks that must not be satisfied by some other step.
step_body() { awk -v name="- name: $1" 'index($0, name){f=1; next} f && /^ *- name: /{exit} f' "$2"; }

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
check 'grep -F "gh-app-write[bot]" <<< "$GATE_BODY" | grep -q "exit 0"' "access gate allowlists gh-app-write[bot] on a line that exits 0"

# 2. The checkout leaves no token on disk.
check 'step_body "Checkout PR head" "$WF" | grep -q "persist-credentials: false"' "PR-head checkout sets persist-credentials: false"

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
for engine in "$KIMI" "$ANTH" "$GROK"; do
  name=$(basename "$(dirname "$engine")")
  check 'grep -qF -- "$FILE_SWEEP" "$engine"' "$name: instruction-file scrub matches symlinks"
  check 'grep -qF -- "$DIR_SWEEP" "$engine"' "$name: config-directory scrub matches symlinks"
  check '! grep -qE -- "-prune -o -type [fd] " "$engine"' "$name: no scrub keyed on a bare -type f / -type d remains"
done

# 4. The path guard: the only path control either CLI honours. Shared by the
#    Kimi and Anthropic engines, fail-closed by construction.
check '[[ -f "$GUARD" ]]' "path guard script is committed"
check '[[ -f "$GUARD_TEST" ]]' "path guard has a node --test file (run by lint-actions test-scripts)"
check 'node --check "$GUARD"' "path guard parses"
check '! grep -oE "require\(['\''\"][^'\''\"]+" "$GUARD" | grep -v "node:" | grep -q .' "path guard requires only node: builtins"
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
check 'step_body "Run AI PR review (Kimi Code)" "$KIMI" | grep -q "PATH_GUARD_LOG: \${{ runner.temp }}/" && step_body "Run AI PR review (Kimi Code)" "$KIMI" | grep -q "\[\[ ! -s \"\$PATH_GUARD_LOG\" \]\]"' "Kimi run step fails if a review was written without the guard ever running"
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
check 'grep -qE "^        allowed_bots: gh-app-write[[:space:]]*$" <<< "$ANTH_RUN"' "Anthropic: claude-code-action allowlists gh-app-write (Forge); GLM/DeepSeek use this engine"
check '! grep -qE "^        allowed_bots: ['\''\"]?\\*" <<< "$ANTH_RUN"' "Anthropic: allowed_bots is not a wildcard (Dependabot must stay out)"
check 'grep -q "^        use_commit_signing: true" <<< "$ANTH_RUN"' "Anthropic: commit-signing mode, the one prepare branch that never rewrites origin with the token"
check 'grep -q "^        GIT_CONFIG_COUNT: \"1\"" <<< "$ANTH_RUN" && grep -q "^        GIT_CONFIG_KEY_0: credential.helper" <<< "$ANTH_RUN" && grep -q "^        GIT_CONFIG_VALUE_0: .*GITHUB_TOKEN" <<< "$ANTH_RUN"' "Anthropic: the action's base-branch fetch authenticates from env-only git config, never .git/config"
check 'grep -q "mcp__github_file_ops" <<< "$ANTH_RUN"' "Anthropic: the file-ops MCP server that commit-signing mode mounts is denied by name"
check 'grep -q "\"PreToolUse\"" <<< "$ANTH_RUN" && grep -q "\"matcher\": \".\*\"" <<< "$ANTH_RUN"' "Anthropic: settings registers a match-all PreToolUse hook"
check 'grep -qF "/ai-review-path-guard/path-guard.js'\'' || exit 2\"" <<< "$ANTH_RUN"' "Anthropic: hook command maps any failure onto the deny code"
check 'grep -q "^        OUTPUT_PATH: \${{ inputs.output_path }}" <<< "$ANTH_RUN" && grep -q "^        PATH_GUARD_LOG: \${{ runner.temp }}/ai-review-path-guard/decisions.log" <<< "$ANTH_RUN"' "Anthropic: guard receives OUTPUT_PATH and the decision log path through the step env"
check 'grep -q -- "--setting-sources user" <<< "$ANTH_RUN"' "Anthropic: only the user settings file the action writes is loaded, never the checkout's"
check 'grep -q -- "--disallowedTools \"Bash," <<< "$ANTH_RUN"' "Anthropic: Bash stays disallowed"
ANTH_VERIFY="$(step_body "Verify the sandbox held and the review was written" "$ANTH")"
check 'grep -q "x-access-token" <<< "$ANTH_VERIFY" && grep -q "\.git/config" <<< "$ANTH_VERIFY"' "Anthropic: verify step re-reads .git/config for credentials after the model ran"
check 'grep -q "\[\[ ! -s \"\$PATH_GUARD_LOG\" \]\]" <<< "$ANTH_VERIFY"' "Anthropic: verify step fails if a review was written without the guard ever running"
check 'grep -q "^        PATH_GUARD_LOG: \${{ runner.temp }}/ai-review-path-guard/decisions.log" <<< "$ANTH_VERIFY"' "Anthropic: verify step reads the same decision log the hook writes"

# 5. Nothing executed after the engine comes from a path an engine can write.
check '! grep -qE "^[[:space:]]*(jq -f|source|\.|bash|sh|node) .*/tmp/[^ ]*\.(jq|sh|js)([[:space:]]|$)" "$WF"' "no step executes a program stored under /tmp (an engine-writable location)"
check '! grep -q "review_marker_filter" "$WF"' "the reap filter is no longer a /tmp file"
check 'grep -q "^      REVIEW_MARKER_FILTER: |" "$WF"' "the reap filter is job-level env"
check '[[ "$(grep -c "jq \"\$REVIEW_MARKER_FILTER\"" "$WF")" -eq 2 ]]' "capture and post steps both apply the env-held filter (same program, no intermediate file)"

# 6. The post step refuses to publish credentials — and does not refuse
#    reviews that merely talk about credential plumbing.
TOKEN_RE="$(sed -n "s/^ *token_shapes_re='\([^']*\)'.*/\1/p" "$WF" | head -1)"
CRED_RE="$(sed -n "s/^ *cred_shapes_re='\([^']*\)'.*/\1/p" "$WF" | head -1)"
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
check 'grep -q "use_commit_signing" "$README" && grep -q "restoreConfigFromBase" "$README"' "README documents why the Anthropic engine keeps origin and uses commit-signing mode instead"
check 'grep -q "REVIEW_MARKER_FILTER" "$README"' "README documents why the reap filter is env, not a file"
check 'grep -q "120000" "$README"' "README documents the tree-based symlink check"

if [[ "$fail" -ne 0 ]]; then
  echo "contract checks failed"
  exit 1
fi
echo "all contract checks passed"
