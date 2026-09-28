#!/usr/bin/env bash
# tests/forge-resolver.sh
#
# Executes forge.yml's own engine_ref resolver against a local fixture repo.
# That block decides which spec-to-pr commit runs, with a write token in scope,
# in every caller repo — so its semantics are pinned by running it, not by
# grepping for its shape. The block is extracted from the workflow verbatim, so
# this test cannot drift from what actually ships.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/forge.yml"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
fail=0

# --- extract the resolver ---------------------------------------------------
# From its section header up to (not including) the fetch that consumes
# ENGINE_SHA; the run-block indentation is stripped.
RESOLVER="$FIX/resolver.sh"
awk '/# ---- resolve engine_ref to a commit SHA/{f=1}
     /# `git clone --branch` only accepts/{f=0}
     f { sub(/^          /, ""); print }' "$WF" > "$RESOLVER"
if ! grep -q 'ENGINE_SHA=' "$RESOLVER" || ! grep -q 'Branches are not accepted' "$RESOLVER"; then
  echo "FAIL: could not extract the resolver block from forge.yml"
  exit 1
fi

# --- fixture: a fake spec-to-pr --------------------------------------------
REPO="$FIX/spec-to-pr"
git init -q "$REPO"
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.com
commit_tag() {  # commit_tag <tag> [annotated]
  git -C "$REPO" commit -q --allow-empty -m "$1"
  if [[ "${2:-}" == annotated ]]; then
    git -C "$REPO" tag -a "$1" -m "release $1"   # tag object != commit: must be peeled
  else
    git -C "$REPO" tag "$1"
  fi
}
c() { git -C "$REPO" rev-parse "$1^{commit}"; }  # the COMMIT a tag must resolve to
commit_tag v0.0.3
commit_tag v0.0.4
commit_tag v0.5.0
commit_tag v0.6.1 annotated
commit_tag v0.6.7
commit_tag v0.6.9
commit_tag v0.6.10 annotated   # numerically > 0.6.9, lexically < — needs sort -V
commit_tag v0.6.11-rc.1         # pre-release: never eligible
commit_tag v0.7.0
commit_tag v1.2.0
commit_tag v1.3.4
commit_tag v2.0.0
# A BRANCH named like an in-range release: must never be picked up.
git -C "$REPO" commit -q --allow-empty -m "unreviewed"
git -C "$REPO" branch v0.6.99

# The workflow's `origin` is spec-to-pr; point it at the fixture instead.
DIR="$FIX/engine"
git init -q "$DIR"
git -C "$DIR" remote add origin "$REPO"

# --- cases ------------------------------------------------------------------
resolve() {  # prints ENGINE_SHA on success; non-zero exit on rejection
  ( export DIR ENGINE_REF="$1"
    bash -euo pipefail -c "$(cat "$RESOLVER"); echo \"RESOLVED=\$ENGINE_SHA\"" ) 2>&1
}
expect() {  # expect <engine_ref> <want-sha>
  local out got
  if out=$(resolve "$1"); then
    got=$(printf '%s\n' "$out" | sed -n 's/^RESOLVED=//p')
    if [[ "$got" == "$2" ]]; then
      echo "PASS: $1 -> ${got:0:7}"
    else
      echo "FAIL: $1 resolved to '${got}', want '$2'"; printf '%s\n' "$out"; fail=1
    fi
  else
    echo "FAIL: $1 was rejected, want '$2'"; printf '%s\n' "$out"; fail=1
  fi
}
reject() {  # reject <engine_ref> <expected error substring>
  local out
  if out=$(resolve "$1"); then
    echo "FAIL: $1 should have been rejected, got: $out"; fail=1
  elif [[ "$out" == *"$2"* ]]; then
    echo "PASS: $1 rejected ($2)"
  else
    echo "FAIL: $1 rejected with the wrong error: $out"; fail=1
  fi
}

# Caret ranges — npm rules: the left-most non-zero component is the breaking one.
expect '^0.6.7'  "$(c v0.6.10)"   # newest 0.6.x; skips rc, 0.7.0 and the branch; peels
expect '^0.6.0'  "$(c v0.6.10)"
expect '^0.5.0'  "$(c v0.5.0)"    # 0.x: minor is the boundary, so not 0.6.x
expect '^1.2.0'  "$(c v1.3.4)"    # >=1: major is the boundary, so not 2.0.0
expect '^0.0.3'  "$(c v0.0.3)"    # 0.0.x: exact patch only
expect '^v0.6.7' "$(c v0.6.10)"   # a leading v is tolerated
reject '^0.6.11' "no spec-to-pr release tag satisfies"   # only a pre-release matches
reject '^0.8.0'  "no spec-to-pr release tag satisfies"

# Exact tags.
expect 'v0.6.1'  "$(c v0.6.1)"    # annotated: the commit, not the tag object
expect 'v0.6.7'  "$(c v0.6.7)"    # lightweight
reject 'v9.9.9'  "does not exist"

# SHAs pass through untouched (they are not looked up).
expect "$(c v0.5.0)" "$(c v0.5.0)"

# A branch named like a release is not a tag, so the exact-tag lookup misses it.
reject 'v0.6.99' "does not exist"

# Anything else is refused outright.
for bad in master '0.6.7' '~0.6.7' 'v0.6' '^0.6' 'v0.6.11-rc.1' 'abc123'; do
  reject "$bad" "Branches are not accepted"
done

if [[ "$fail" -ne 0 ]]; then
  echo "❌ forge engine_ref resolver test failed"
  exit 1
fi
echo "✅ forge engine_ref resolver test passed"
