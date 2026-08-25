#!/usr/bin/env bash
# tests/trivy-sca-autofix-logic.sh — behaviour of the shipped lib, not a fork of it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../.github/actions/trivy_sca_autofix_prompt/lib.sh
source "$ROOT/.github/actions/trivy_sca_autofix_prompt/lib.sh"
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

assert_ok is_allowlisted package.json
assert_ok is_allowlisted packages/app/package.json
assert_ok is_allowlisted yarn.lock
assert_ok is_allowlisted pnpm-lock.yaml
assert_ok is_allowlisted package-lock.json
assert_fail is_allowlisted CLAUDE.md
assert_fail is_allowlisted AGENTS.md
assert_fail is_allowlisted node_modules/.package-lock.json

assert_ok is_lockfile_basename package-lock.json
assert_ok is_lockfile_basename apps/web/yarn.lock
assert_fail is_lockfile_basename package.json

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

assert_eq "$(merge_trivy_skip_dirs "")" "node_modules,**/node_modules" "skip-dirs default includes nested node_modules"
assert_eq "$(merge_trivy_skip_dirs "vendor,dist")" "vendor,dist,node_modules,**/node_modules" "skip-dirs appends nested node_modules"

assert_eq "$(normalize_engine "")" "kimi" "empty engine defaults to kimi"
assert_eq "$(normalize_engine kimi)" "kimi" "engine kimi"
assert_eq "$(normalize_engine anthropic)" "anthropic" "engine anthropic"
assert_eq "$(normalize_engine grok)" "grok" "engine grok"
if normalize_engine nope >/dev/null; then
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
assert_fail should_open_pr "" 3
assert_fail should_open_pr 12 "not-a-number"

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

GITTMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$GITTMP"' EXIT
git init -q "$GITTMP"
git -C "$GITTMP" config user.email "test@example.com"
git -C "$GITTMP" config user.name "test"
printf '%s\n' '{"name":"app"}' > "$GITTMP/package.json"
printf '%s\n' '{"lockfileVersion":2}' > "$GITTMP/package-lock.json"
git -C "$GITTMP" add package.json package-lock.json
git -C "$GITTMP" commit -q -m init
printf '%s\n' '{"name":"app","version":"2"}' > "$GITTMP/package.json"
printf '%s\n' '{"lockfileVersion":2,"truncated":true}' > "$GITTMP/package-lock.json"
printf '%s\n' 'untracked' > "$GITTMP/yarn.lock"
( cd "$GITTMP" && discard_engine_lockfile_edits )
if grep -q truncated "$GITTMP/package-lock.json"; then
  echo "FAIL: tracked lockfile was not restored"
  fail=1
else
  echo "PASS: tracked lockfile restored before install"
fi
if grep -q '"version":"2"' "$GITTMP/package.json"; then
  echo "PASS: package.json edit kept"
else
  echo "FAIL: package.json should not be reverted"
  fail=1
fi
if [[ -f "$GITTMP/yarn.lock" ]]; then
  echo "FAIL: untracked lockfile should be removed"
  fail=1
else
  echo "PASS: untracked lockfile removed"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "logic checks failed"
  exit 1
fi
echo "all logic checks passed"
