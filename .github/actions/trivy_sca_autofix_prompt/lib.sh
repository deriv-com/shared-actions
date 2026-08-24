#!/usr/bin/env bash
# Shared SCA autofix helpers. Copied to /tmp/sca-lib.sh via github.action_path
# (reusable workflows check out the caller, so this cannot live at a path in
# the consumer repo). Sourced by trivy-sca-autofix.yml and the logic tests.

SCA_ALLOWED_BASENAME='^(package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml)$'
SCA_LOCKFILE_BASENAME='^(package-lock\.json|yarn\.lock|pnpm-lock\.yaml)$'
SCA_SKIP_DIRS_EXTRA='node_modules,**/node_modules'

is_allowlisted() {
  local base
  base="$(basename -- "$1")"
  [[ "$base" =~ $SCA_ALLOWED_BASENAME ]]
}

is_lockfile_basename() {
  local base
  base="$(basename -- "$1")"
  [[ "$base" =~ $SCA_LOCKFILE_BASENAME ]]
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
  local user_skip="${1:-}"
  if [[ -n "$user_skip" ]]; then
    printf '%s\n' "${user_skip},${SCA_SKIP_DIRS_EXTRA}"
  else
    printf '%s\n' "$SCA_SKIP_DIRS_EXTRA"
  fi
}

normalize_engine() {
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

detect_in() {
  local d="$1"
  if [[ -f "$d/pnpm-lock.yaml" ]]; then printf '%s\n' pnpm; return; fi
  if [[ -f "$d/yarn.lock" ]]; then printf '%s\n' yarn; return; fi
  if [[ -f "$d/package-lock.json" ]]; then printf '%s\n' npm; return; fi
  printf '%s\n' ""
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

discard_engine_lockfile_edits() {
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_lockfile_basename "$f" || continue
    if git -c core.quotePath=false ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
      git -c core.quotePath=false checkout -- "$f"
    else
      rm -f -- "$f"
    fi
  done < <( { git -c core.quotePath=false diff --name-only; git -c core.quotePath=false ls-files --others --exclude-standard; } | sort -u )
}
