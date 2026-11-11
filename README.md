## Shared Actions Repository

This repository hosts reusable GitHub Actions workflows and composite actions shared across `deriv-com` repositories.

It holds two kinds of reusable entrypoints:

- **Reusable workflows** (`.github/workflows/*.yml`) — called from another repo with `jobs.<id>.uses:`
- **Composite actions** (`.github/actions/<name>/action.yml`) — called from a step with `uses:`

Everything here is consumed at `@master`, so **changes are live for every consumer as soon as they merge.** There is no release gate; the `v1`–`v4` tags are stale and referenced by nothing. Treat every change as immediately org-wide, and prefer changes that are revertable in one commit.

### Reusable workflows

| Workflow | Purpose | Docs | Status |
|---|---|---|---|
| [`ai-pr-review.yml`](.github/workflows/ai-pr-review.yml) | Pluggable LLM PR review (`kimi` \| `anthropic` \| `grok` \| `codex` \| `muse` \| `antigravity`) | [AI_PR_REVIEW_README.md](.github/workflows/AI_PR_REVIEW_README.md) | ✅ active |
| [`forge.yml`](.github/workflows/forge.yml) | Turns an issue into a verified PR (`auto`), or revises/updates an open PR (`revise` \| `update`) via `spec-to-pr` | [Forge](#forge-issue-to-pr) | ✅ active |
| [`docsync-ai.yml`](.github/workflows/docsync-ai.yml) | Keeps docs in sync with code; scheduled, `@docbot` comment, and `claude_md_refresh` triggers | [Agent guidance file](#docsync-ai-agent-guidance-file) | ✅ active |
| [`dependonme-bot.yml`](.github/workflows/dependonme-bot.yml) | Auto-fixes Dependabot security alerts and opens/auto-merges fix PRs | [DEPENDONME_BOT_README.md](.github/workflows/DEPENDONME_BOT_README.md) | ✅ active |
| [`qa-checklist.yml`](.github/workflows/qa-checklist.yml) | Generates a QA checklist for a PR when someone comments `@checkmaite` | [QA_CHECKLIST_README.md](.github/workflows/QA_CHECKLIST_README.md) | ✅ active |
| [`archive-on-merge.yml`](.github/workflows/archive-on-merge.yml) | Archives completed OpenSpec changes into a follow-up PR when a PR merges | [Archive on Merge](#archive-on-merge-openspec) | ✅ active |
| [`claude-pr-review.yml`](.github/workflows/claude-pr-review.yml) | Legacy standalone Claude PR review | [Migration guide](.github/workflows/AI_PR_REVIEW_README.md#migrating-from-claude-pr-reviewyml) | ⚠️ **deprecated** → use `ai-pr-review.yml` with `engine: anthropic` |

*(Repository-internal workflows [`lint-actions.yml`](.github/workflows/lint-actions.yml) and [`ai-review.yml`](.github/workflows/ai-review.yml) validate and dogfood this repo itself and are not `workflow_call` entrypoints.)*

### Deprecations

| Workflow | Replacement | Notes |
|---|---|---|
| `claude-pr-review.yml` | `ai-pr-review.yml` with `engine: anthropic` | **Still a standalone duplicate** — converting it into a delegating shim is a tracked follow-up. See the [migration guide](.github/workflows/AI_PR_REVIEW_README.md#migrating-from-claude-pr-reviewyml). Do not delete until consumers are migrated and deprecation telemetry has been silent for 30 days. |

Add a row here when deprecating anything. With no CHANGELOG and no release process, this table is the only coordination mechanism the repo has.

### Composite actions

#### Consumer-facing composite actions

| Action | Purpose | Docs |
|---|---|---|
| [`archive_on_merge`](.github/actions/archive_on_merge/) | Detects completed OpenSpec changes on a merged PR and runs `openspec archive` | [README](.github/actions/archive_on_merge/README.md) |
| [`generate_app_info`](.github/actions/generate_app_info/) | Writes `app-info.json` containing the release version tag | [README](.github/actions/generate_app_info/README.md) |
| [`npm_install`](.github/actions/npm_install/action.yml) | Restores/saves `node_modules` cache keyed on `package-lock.json` and runs `npm ci` | — |
| [`post_preview_build_comment`](.github/actions/post_preview_build_comment/action.yml) | Posts an in-progress preview build sticky comment and check run on a PR | — |
| [`post_preview_link_comment`](.github/actions/post_preview_link_comment/action.yml) | Updates the preview sticky comment and check run with deployment URL or failure status | — |
| [`publish_to_pages_branch`](.github/actions/publish_to_pages_branch/action.yml) | Deploys a compiled frontend directory to a Cloudflare Pages preview branch | — |
| [`publish_to_pages_production`](.github/actions/publish_to_pages_production/action.yml) | Deploys a compiled frontend directory to Cloudflare Pages `main` | — |
| [`send_slack_notification`](.github/actions/send_slack_notification/action.yml) | Sends a Block Kit message to a Slack incoming webhook | — |
| [`sync_crowdin_translation_with_cloudflare`](.github/actions/sync_crowdin_translation_with_cloudflare/action.yml) | Pulls Crowdin branch translations and uploads them to Cloudflare R2 | — |
| [`vercel_DR_publish`](.github/actions/vercel_DR_publish/action.yml) | Builds, deploys, and aliases a disaster-recovery deployment on Vercel | — |
| [`verify_user_in_organization`](.github/actions/verify_user_in_organization/action.yml) | Verifies that a GitHub username is an active `deriv-com` org member | — |

Example step usage in a consumer workflow:

```yaml
      - name: Post preview build comment
        id: post_preview_build_comment
        uses: "deriv-com/shared-actions/.github/actions/post_preview_build_comment@master"
        with:
          issue_number: ${{ steps.pr_information.outputs.issue_number }}
          head_sha: ${{ github.event.workflow_run.head_sha }}
```

#### Workflow-internal composite actions

The remaining directories under `.github/actions/` implement internal building blocks for the reusable workflows above (prefer calling the parent workflow rather than invoking these directly):

- **AI PR Review engines & guard** (called by [`ai-pr-review.yml`](.github/workflows/ai-pr-review.yml), documented in [AI_PR_REVIEW_README.md](.github/workflows/AI_PR_REVIEW_README.md)): [`ai_review_engine_kimi`](.github/actions/ai_review_engine_kimi/action.yml), [`ai_review_engine_anthropic`](.github/actions/ai_review_engine_anthropic/action.yml), [`ai_review_engine_grok`](.github/actions/ai_review_engine_grok/action.yml), [`ai_review_engine_codex`](.github/actions/ai_review_engine_codex/action.yml), [`ai_review_engine_muse`](.github/actions/ai_review_engine_muse/action.yml), [`ai_review_engine_antigravity`](.github/actions/ai_review_engine_antigravity/action.yml), plus [`ai_review_path_guard`](.github/actions/ai_review_path_guard/path-guard.js) (shared Node `PreToolUse` path guard script).
- **DocSync AI internals** (called by [`docsync-ai.yml`](.github/workflows/docsync-ai.yml)): [`docsync_ai`](.github/actions/docsync_ai/action.yml), [`docsync_ai_comment`](.github/actions/docsync_ai_comment/action.yml), and [`docsync_guidance_file`](.github/actions/docsync_guidance_file/action.yml).

### Forge: issue to PR

[`forge.yml`](.github/workflows/forge.yml) runs `deriv-com/spec-to-pr` against an issue (`command: auto`) or an open same-repo PR (`command: revise` | `update`), handling GitHub App token rotation, AI review wait/revise loops, base-branch updates, and optional Slack progress threads. Full caller header and input reference live at the top of [`forge.yml`](.github/workflows/forge.yml).

### DocSync AI: agent guidance file

DocSync AI updates root `README.md` plus one AI-agent guidance file. All three
triggers (`scheduled`, `comment`, `claude_md_refresh`) pick that file the same
way, through [`docsync_guidance_file`](.github/actions/docsync_guidance_file/):

| Repository has | DocSync edits |
|---|---|
| A `CLAUDE.md` with real content | `CLAUDE.md` (unchanged behaviour) |
| A `CLAUDE.md` whose only content is one import line, e.g. `@AGENTS.md` | The imported file. The shim is never edited. |
| A `CLAUDE.md` symlink | The file it links to, if that file is inside the repository |
| No `CLAUDE.md` | No guidance file (unchanged), unless `guidance_file` is set |
| A shim with several imports, or one whose target is missing, outside the repo, or another shim | No guidance file. DocSync never falls back to the shim. |

Optional inputs on `docsync-ai.yml`:

- `guidance_file` sets the file explicitly, e.g. `AGENTS.md` in a repository
  with no `CLAUDE.md`. The file must already exist and must not be a shim.
- `guidance_max_bytes` sets a byte budget for that file. The model is told the
  budget, and an update or refresh over it is dropped rather than opened as a
  PR that the repository's own CI would reject. `0` (the default) means no limit.

```yaml
    uses: deriv-com/shared-actions/.github/workflows/docsync-ai.yml@master
    with:
      trigger_type: "scheduled"
      base_branch: "master"
      guidance_max_bytes: 16384 # optional: match the repo's own size check
```

`@docbot update only claude.md …` (or `… agents.md …`) targets the resolved file.

**Limitation:** DocSync has no second, detailed-reference target. If a repository
keeps `AGENTS.md` short and moves detail to a file such as
`docs/agent-reference.md`, DocSync does not edit that file. Under a byte budget it
skips updates that don't fit.

### App info (version stamp)

[`generate_app_info`](.github/actions/generate_app_info/) creates or updates an
`app-info.json` file in the build output directory containing the production tag.
Full docs: [generate_app_info README](.github/actions/generate_app_info/README.md).

```yaml
      - name: Generate app-info.json
        uses: "deriv-com/shared-actions/.github/actions/generate_app_info@master"
        with:
          version: ${{ github.event.inputs.tag }} # the production tag
          output_dir: dist # optional, defaults to "."
```

Output file:

```json
{ "version": "<the tag passed>" }
```

### Archive on Merge (openspec)

When a PR that completes an openspec change merges, archive it and open a
follow-up PR (never pushes directly to a protected branch).

Thin caller in the consumer repo:

```yaml
name: Archive on Merge
on:
  pull_request:
    types: [closed]
    branches: [master]
permissions:
  contents: write
  pull-requests: write
jobs:
  archive:
    if: github.event.pull_request.merged == true
    uses: deriv-com/shared-actions/.github/workflows/archive-on-merge.yml@master
    with:
      # Required — must match the workflow ref in `uses:` above.
      action_ref: master
    permissions:
      contents: write
      pull-requests: write
```

Required input: `action_ref` (same ref as the workflow `uses:` pin). Optional:
`base_branch` (default `master`), `node_version` (default `22`),
`openspec_version` (default `1.6.0`).

The detect/archive script is also available as a composite action:
[`archive_on_merge`](.github/actions/archive_on_merge/).

### Local validation and testing

[`lint-actions.yml`](.github/workflows/lint-actions.yml) gates pull requests in this repository. Run the same checks locally before pushing (Node 22+ and Bash; zero `npm install` required):

```bash
# 1. Node unit tests for composite action scripts (path guards, archive-on-merge, docsync resolver)
node --test .github/actions/**/*.test.js

# 2. Workflow & composite-action contract suites
bash tests/ai-pr-review-contract.sh
bash tests/qa-checklist-contract.sh
bash tests/docsync-guidance-contract.sh
bash tests/forge-contract.sh
bash tests/forge-resolver.sh

# 3. Workflow static analysis (actionlint 1.7.12, shellcheck disabled to match CI)
actionlint -shellcheck=
```
