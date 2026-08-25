## Shared Actions Repository

This repository is dedicated to hosting reusable GitHub Actions YAML files that can be shared across different repositories. Centralizing common actions, to promote consistency and efficiency in workflows.

It holds two kinds of thing:

- **Reusable workflows** (`.github/workflows/*.yml`) — called from another repo with `jobs.<id>.uses:`
- **Composite actions** (`.github/actions/<name>/action.yml`) — called from a step with `uses:`

Everything here is consumed at `@master`, so **changes are live for every consumer as soon as they merge.** There is no release gate; the `v1`–`v4` tags are stale and referenced by nothing. Treat every change as immediately org-wide, and prefer changes that are revertable in one commit.

### Reusable workflows

| Workflow | Purpose | Docs | Status |
|---|---|---|---|
| [`ai-pr-review.yml`](.github/workflows/ai-pr-review.yml) | LLM PR review; engine selectable (`kimi` \| `anthropic` \| `grok`) | [AI_PR_REVIEW_README.md](.github/workflows/AI_PR_REVIEW_README.md) | ✅ active |
| [`claude-pr-review.yml`](.github/workflows/claude-pr-review.yml) | Claude PR review | — | ⚠️ **deprecated** → use `ai-pr-review.yml` with `engine: anthropic` |
| [`docsync-ai.yml`](.github/workflows/docsync-ai.yml) | Keeps docs in sync with code; scheduled + comment-triggered | — | ✅ active |
| [`dependonme-bot.yml`](.github/workflows/dependonme-bot.yml) | Auto-fixes Dependabot security alerts | [DEPENDONME_BOT_README.md](.github/workflows/DEPENDONME_BOT_README.md) | ✅ active |
| [`trivy-sca-autofix.yml`](.github/workflows/trivy-sca-autofix.yml) | When a consumer Trivy SCA job fails, re-scan `master` and open one JS-deps fix PR; engine selectable (`kimi` \| `anthropic` \| `grok`) | [TRIVY_SCA_AUTOFIX_README.md](.github/workflows/TRIVY_SCA_AUTOFIX_README.md) | ✅ active |
| [`qa-checklist.yml`](.github/workflows/qa-checklist.yml) | Generates a QA checklist for a PR | — | ✅ active |

### Deprecations

| Workflow | Replacement | Notes |
|---|---|---|
| `claude-pr-review.yml` | `ai-pr-review.yml` with `engine: anthropic` | **Still a standalone duplicate** — converting it into a delegating shim is a tracked follow-up. See the [migration guide](.github/workflows/AI_PR_REVIEW_README.md#migrating-from-claude-pr-reviewyml). Do not delete until consumers are migrated and deprecation telemetry has been silent for 30 days. |

Add a row here when deprecating anything. With no CHANGELOG and no release process, this table is the only coordination mechanism the repo has.

#### Example Usage

```
      - name: Post preview build comment
        id: post_preview_build_comment
        uses: "deriv-com/shared-actions/.github/actions/post_preview_build_comment@master"
        with:
          issue_number: ${{steps.pr_information.outputs.issue_number}}
          head_sha: ${{github.event.workflow_run.head_sha}}
```

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
