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
    contents: write
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

Every consumer in this org pins `@master`, so that is the documented policy — changes are live on merge.

## Engines

| Engine | Runtime | Default model | Notes |
|--------|---------|---------------|-------|
| `kimi` | Kimi Code CLI `0.34.0` (npm, pinned) | `kimi-k3` | Default engine |
| `anthropic` | `anthropics/claude-code-action@fefa07e9c665b7320f08c3b525980457f22f58aa` (same SHA as PR review) | `claude-sonnet-5` | Bash denied via `disallowedTools` |
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
| `trivy_skip_dirs` | Optional Trivy `--skip-dirs` | ❌ | — |
| `base_branch` | Branch to check out and open the PR against | ❌ | `master` |
| `node_version` | Node.js version for package manager and CLIs | ❌ | `22` |
| `slack_users_to_tag` | Comma-separated Slack user IDs to mention | ❌ | — |

> ⚠️ **Note:** Reusable workflows run in the caller's context. Secrets must be passed from the calling workflow.

## Secrets

| Secret | Description | Required |
|--------|-------------|----------|
| `LLM_API_KEY` | LiteLLM virtual key for the selected engine | ✅ |
| `AUTOFIX_GITHUB_TOKEN` | GitHub PAT with `contents:write` and `pull-requests:write` that **triggers workflows** on the new PR — `GITHUB_TOKEN` would not | ✅ |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook for all outcomes | ✅ |

## Behaviour

- **Loop skip** — If the run is on branch `chore/trivy-sca-autofix`, head ref `chore/trivy-sca-autofix`, or the PR has label `trivy-autofix`, the job exits early (prevents infinite loops when Trivy fails on the autofix PR itself).
- **Clean master** — When Trivy finds zero findings at the configured severity on `base_branch`, Slack reports `nothing to do` (`master` already clean) and no PR is opened.
- **Singleton branch** — All fixes land on `chore/trivy-sca-autofix`. A second failure while that PR is open force-pushes the same branch and updates the existing PR.
- **JS only** — npm, Yarn Classic, or pnpm lockfiles. Yarn Berry (`.yarnrc.yml`) is rejected. No lockfile generation.
- **Safe install** — Lockfile refresh runs with `--ignore-scripts`.
- **Allowlist** — Only `package.json`, `package-lock.json`, `yarn.lock`, and `pnpm-lock.yaml` may change.
- **Fail closed** — A second Trivy scan must pass before a PR is opened. If findings remain, the job fails and Slack reports the count.
- **No auto-merge** — The workflow opens or updates a PR only; it never merges.
- **Slack** — Every outcome (skip, clean master, PR opened/updated, failure) posts to the webhook via `if: always()`.

## Manual test plan

1. **Feature PR Trivy red, `master` clean** — Trigger autofix; expect Slack `nothing to do`, no PR.
2. **Feature PR Trivy red, `master` dirty** — Expect one PR to `master` on `chore/trivy-sca-autofix` with labels `trivy-autofix` and `security`; CI runs on the new PR (PAT must trigger workflows).
3. **Second failure while that PR is open** — Same PR updated (force-push + body edit), not a second PR.
4. **Trivy failure on the autofix PR** — Loop skip; no new remediation PR.
5. **Repeat the dirty-master case with `engine: anthropic` and `engine: grok`** — Same PR shape; engine and model appear in the PR body.

## Dogfood note

Composite action refs inside this workflow resolve `@master` even when the reusable workflow is called from a feature branch. To pilot a new engine before merge, temporarily point the dispatch `uses:` steps in `trivy-sca-autofix.yml` at `@<branch>` and revert before merging to `master`.
