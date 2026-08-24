#!/usr/bin/env bash
# tests/trivy-sca-autofix-logic.sh — behaviour that comment-greps cannot catch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: $msg (got $(printf %q "$got"), want $(printf %q "$want"))"
    fail=1
  else
    echo "PASS: $msg"
  fi
}
assert_ok() {
  if "$@"; then
    echo "PASS: $*"
  else
    echo "FAIL: $*"
    fail=1
  fi
}
assert_fail() {
  if "$@"; then
    echo "FAIL: expected failure: $*"
    fail=1
  else
    echo "PASS: rejected $*"
  fi
}

allowed='^(package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml)$'
is_allowlisted() {
  local base
  base="$(basename "$1")"
  [[ "$base" =~ $allowed ]]
}

under_node_modules() {
  local f="$1"
  [[ "$f" == node_modules || "$f" == node_modules/* || "$f" == */node_modules || "$f" == */node_modules/* ]]
}

should_loop_skip() {
  local ref="$1" head_ref="$2" labels="$3" branch="$4"
  [[ "$ref" == "refs/heads/${branch}" || "$head_ref" == "$branch" || ",${labels}," == *",trivy-autofix,"* ]]
}

merge_trivy_skip_dirs() {
  local user_skip="$1"
  local extra="node_modules"
  if [[ -n "$user_skip" ]]; then
    printf '%s\n' "${user_skip},${extra}"
  else
    printf '%s\n' "$extra"
  fi
}

resolve_engine() {
  local engine="${1:-kimi}"
  case "$engine" in
    kimi|anthropic|grok) printf '%s\n' "$engine" ;;
    *) return 1 ;;
  esac
}

should_open_pr() {
  local before="$1" after="$2"
  [[ "$after" =~ ^[0-9]+$ ]] || return 1
  [[ "$before" =~ ^[0-9]+$ ]] || return 1
  [[ "$after" -lt "$before" ]]
}

collect_lockfile_dirs() {
  find . \( -name .git -o -name node_modules \) -prune -o -type f \
    \( -name pnpm-lock.yaml -o -name yarn.lock -o -name package-lock.json \) -print |
    sed 's|^\./||' |
    awk 'NF { n=split($0, a, "/"); printf "%d\t%s\n", n, $0 }' |
    sort -n -k1,1 -k2,2 |
    cut -f2- |
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      dirname -- "$f"
    done |
    awk 'NF && !seen[$0]++'
}

assert_ok is_allowlisted package.json
assert_ok is_allowlisted packages/app/package.json
assert_ok is_allowlisted yarn.lock
assert_ok is_allowlisted pnpm-lock.yaml
assert_ok is_allowlisted package-lock.json
assert_fail is_allowlisted CLAUDE.md
assert_fail is_allowlisted AGENTS.md
assert_fail is_allowlisted node_modules/.package-lock.json

assert_ok under_node_modules node_modules
assert_ok under_node_modules node_modules/.package-lock.json
assert_ok under_node_modules apps/web/node_modules/foo/package-lock.json
assert_fail under_node_modules package-lock.json
assert_fail under_node_modules apps/web/package.json

BRANCH="chore/trivy-sca-autofix"
assert_ok should_loop_skip "refs/heads/${BRANCH}" "" "" "$BRANCH"
assert_ok should_loop_skip "refs/heads/feature" "$BRANCH" "" "$BRANCH"
assert_ok should_loop_skip "refs/heads/feature" "feature" "security,trivy-autofix" "$BRANCH"
assert_fail should_loop_skip "refs/heads/feature" "feature" "security" "$BRANCH"

assert_eq "$(merge_trivy_skip_dirs "")" "node_modules" "skip-dirs default is node_modules"
assert_eq "$(merge_trivy_skip_dirs "vendor,dist")" "vendor,dist,node_modules" "skip-dirs appends node_modules"

assert_eq "$(resolve_engine "")" "kimi" "empty engine defaults in caller; helper sees kimi only when passed"
assert_eq "$(resolve_engine kimi)" "kimi" "engine kimi"
assert_eq "$(resolve_engine anthropic)" "anthropic" "engine anthropic"
assert_eq "$(resolve_engine grok)" "grok" "engine grok"
if resolve_engine nope >/dev/null; then
  echo "FAIL: unknown engine should fail"
  fail=1
else
  echo "PASS: unknown engine rejected"
fi

assert_ok should_open_pr 12 3
assert_ok should_open_pr 1 0
assert_fail should_open_pr 5 5
assert_fail should_open_pr 5 6
assert_fail should_open_pr 0 0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.git" "$TMP/node_modules/dep" "$TMP/apps/web" "$TMP/apps/api"
touch "$TMP/package-lock.json"
touch "$TMP/.git/package-lock.json"
touch "$TMP/node_modules/dep/package-lock.json"
touch "$TMP/apps/web/pnpm-lock.yaml"
touch "$TMP/apps/api/yarn.lock"
GOT="$(cd "$TMP" && collect_lockfile_dirs | paste -s -d, -)"
assert_eq "$GOT" ".,apps/api,apps/web" "lockfile dirs prune .git/node_modules and prefer shallowest first"

if [[ "$fail" -ne 0 ]]; then
  echo "logic checks failed"
  exit 1
fi
echo "all logic checks passed"
