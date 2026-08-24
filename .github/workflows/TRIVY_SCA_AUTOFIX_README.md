# Trivy SCA Autofix

When a consumer repo runs Trivy SCA as the security gate on a feature PR, this reusable workflow fires only after that job fails (`if: failure()`). It does not scan the failing PR branch — it checks out `base_branch` (default `master`), re-scans there, and opens or updates a single remediation PR into `master`. The consumer Trivy job remains the gate; this workflow remediates the integration branch.

## Usage

Wire it as a follow-up job that runs when your Trivy SCA step fails:

```yaml
autofix:
  needs: trivy
  if: failure()
  uses: deriv-com/shared-actions/.github/workflows/trivy-sca-autofix.yml@master
  permissions:
    contents: read
    pull-requests: write
  with:
    engine: kimi          # or: anthropic | grok
    trivy_severity: HIGH,CRITICAL
    trivy_scanners: vuln
  secrets:
    LLM_API_KEY: ${{ secrets.LLM_API_KEY }}
    AUTOFIX_GITHUB_TOKEN: ${{ secrets.AUTOFIX_GITHUB_TOKEN }}
    SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

Every consumer in this org pins `@master`, so that is the documented policy — changes are live on merge. The SCA engines and `send_slack_notification` run with the LLM key in scope, and the same job later uses `AUTOFIX_GITHUB_TOKEN` for push/PR creation.

## Engines

| Engine | Runtime | Default model | Notes |
|--------|---------|---------------|-------|
| `kimi` | Kimi Code CLI `0.34.0` (npm, pinned) | `kimi-k3` | Default engine |
| `anthropic` | `anthropics/claude-code-action@fefa07e9c665b7320f08c3b525980457f22f58aa` (same SHA as PR review) | `claude-sonnet-5` | Bash denied via `disallowedTools`; `show_full_output: false` |
| `grok` | Grok Build CLI `1.0.5` (npm, pinned) | `grok-4.6` | `workspace-write` sandbox; Bash denied |

Switching engines is one input: `engine:`. To add a new engine, create `.github/actions/ai_sca_engine_<name>/action.yml`, add a `case` arm in the resolve step, and an `if:`-gated `uses:` dispatch step.

## Inputs

| Input | Description | Required | Default (empty resolves in the resolve step) |
|-------|-------------|----------|-----------------------------------------------|
| `engine` | SCA engine: `kimi`, `anthropic`, or `grok` | ❌ | `kimi` |
| `model` | Model ID as the endpoint names it | ❌ | per engine: `kimi-k3`, `claude-sonnet-5`, `grok-4.6` |
| `base_url` | LLM API base URL | ❌ | `https://litellmsa.deriv.ai/v1` |
| `max_context_size` | Context window (`kimi`, `grok` only) | ❌ | `1048576` (kimi), `500000` (grok) |
| `cli_version` | Pinned CLI version (`kimi`, `grok` only) | ❌ | `0.34.0` (kimi), `1.0.5` (grok) |
| `provider_type` | Wire dialect (`kimi` only) | ❌ | `openai` |
| `trivy_severity` | Trivy `--severity` | ❌ | `HIGH,CRITICAL` |
| `trivy_scanners` | Trivy `--scanners` | ❌ | `vuln` |
| `trivy_skip_dirs` | Extra Trivy `--skip-dirs` (always merged with `node_modules`) | ❌ | — |
| `base_branch` | Branch to check out and open the PR against | ❌ | `master` |
| `node_version` | Node.js version for package manager and CLIs | ❌ | `22` |
| `slack_users_to_tag` | Comma-separated Slack user IDs to mention | ❌ | — |

> ⚠️ **Note:** Reusable workflows run in the caller's context. Secrets must be passed from the calling workflow.

## Secrets

| Secret | Description | Required |
|--------|-------------|----------|
| `LLM_API_KEY` | LiteLLM virtual key for the selected engine | ✅ |
| `AUTOFIX_GITHUB_TOKEN` | GitHub PAT with `contents:write` and `pull-requests:write` that **triggers workflows** on the new PR — `GITHUB_TOKEN` would not. The job token only needs `contents: read`; push and PR creation use this PAT via `GH_TOKEN`. | ✅ |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook for all outcomes | ✅ |

## Behaviour

- **Loop skip** — If the run is on branch `chore/trivy-sca-autofix`, head ref `chore/trivy-sca-autofix`, or the PR has label `trivy-autofix`, the job exits early (prevents infinite loops when Trivy fails on the autofix PR itself).
- **Clean master** — When Trivy finds zero findings at the configured severity on `base_branch`, Slack reports `nothing to do` (`master` already clean) and no PR is opened.
- **Singleton branch** — All fixes land on `chore/trivy-sca-autofix`. A second failure while that PR is open force-pushes the same branch and updates the existing PR.
- **JS lockfiles** — npm, Yarn Classic, or pnpm. Every lockfile directory is installed (find prunes `.git` and `node_modules`; the shallowest lockfile is used for metadata). Yarn Berry (`.yarnrc.yml` in any of those directories) is rejected. No lockfile generation. Mixed package managers are installed per directory; this is not a full monorepo product (workspaces / Yarn Berry / generated lockfiles are out of scope).
- **Safe install** — Lockfile refresh runs with `--ignore-scripts`. pnpm uses `--no-frozen-lockfile` because GitHub sets `CI=true` and the engine has just changed `package.json`. `COREPACK_ENABLE_DOWNLOAD_PROMPT=0` is set when enabling Corepack. `node_modules` is deleted after install so it cannot leak into the allowlist or the after-scan.
- **Allowlist** — Only `package.json`, `package-lock.json`, `yarn.lock`, and `pnpm-lock.yaml` may change. Tracked files the engine stripped (for example `AGENTS.md`) are restored before the gate. Commit stages only allowlisted paths (never `git add -A`). Path enumeration uses `core.quotePath=false`.
- **Trivy cache** — Scans disable Trivy action caching and use `/tmp/trivy-cache` so cache files are not mistaken for extra repo changes. Both scans skip `node_modules` (merged with `trivy_skip_dirs`).
- **PAT isolation** — Checkout uses the job `GITHUB_TOKEN` with `persist-credentials: false` (no write PAT on fetch). Push and `gh` run under `env -i` with `/usr/bin/git` / `/usr/bin/gh` and a local `gh` credential helper.
- **Hook bypass** — Commit and push use `core.hooksPath=/dev/null` and `--no-verify` so consumer `.git/hooks` cannot run with secrets in env.
- **Labels best-effort** — PRs are created without `--label`; `trivy-autofix` and `security` are added afterward with `|| true` so missing repo labels do not fail after a force-push.
- **Force-push** — The singleton branch is pushed with `--force` (no `--force-with-lease`). This job owns that branch; a human commit on `chore/trivy-sca-autofix` will be overwritten.
- **Reduction gate** — A second Trivy scan must report **fewer** findings than the before-scan (`AFTER < BEFORE`). Unfixable CVEs may remain; the consumer Trivy job is still the merge gate. The PR title and body include both counts. If the count does not drop, the job fails and no PR is opened.
- **No auto-merge** — The workflow opens or updates a PR only; it never merges.
- **Slack** — Every outcome (skip, clean master, PR opened/updated, failure) posts to the webhook via `if: always()` on steps of a job that started. Concurrency is `cancel-in-progress: false`, so an in-flight run is not killed. A **queued** run can still be dropped when a newer one is enqueued; that dropped run never starts, so it never posts Slack.

## Manual test plan

1. **Feature PR Trivy red, `master` clean** — Trigger autofix; expect Slack `nothing to do`, no PR.
2. **Feature PR Trivy red, `master` dirty** — Expect one PR to `master` on `chore/trivy-sca-autofix` when the after-scan count is lower than before (including partial fixes); labels `trivy-autofix` and `security` are added when they exist; CI runs on the new PR (PAT must trigger workflows).
3. **Second failure while that PR is open** — Same PR updated (force-push + body edit), not a second PR.
4. **Trivy failure on the autofix PR** — Loop skip; no new remediation PR.
5. **Repeat the dirty-master case with `engine: anthropic` and `engine: grok`** — Same PR shape; engine and model appear in the PR body.

## Dogfood note

Composite action refs inside this workflow resolve `@master` even when the reusable workflow is called from a feature branch. To pilot a new engine before merge, temporarily point the dispatch `uses:` steps in `trivy-sca-autofix.yml` at `@<branch>` and revert before merging to `master`.
