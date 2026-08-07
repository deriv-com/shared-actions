# archive_on_merge

Detects openspec change(s) completed by a merged PR, verifies every item in
each change's `tasks.md` is checked, and runs `openspec archive --yes --json`.

Prefer the reusable workflow for the full flow (detect + open archive PR):

[`archive-on-merge.yml`](../../workflows/archive-on-merge.yml)

## Composite action usage

Requires the `openspec` CLI on `PATH` (install `@fission-ai/openspec` first)
and a checkout of the consumer repo at the base branch with full history
(`fetch-depth: 0`).

```yaml
- uses: deriv-com/shared-actions/.github/actions/archive_on_merge@master
  id: archive
  with:
    base_sha: ${{ github.event.pull_request.base.sha }}
    head_sha: ${{ github.event.pull_request.merge_commit_sha }}
```

### Inputs

| Name | Required | Description |
| --- | --- | --- |
| `base_sha` | yes | Base SHA of the merged PR (40-char hex) |
| `head_sha` | yes | Merge commit SHA (40-char hex) |

### Outputs

| Name | Description |
| --- | --- |
| `archived` | `'true'` when at least one change was archived |
| `changes` | Comma-separated kebab-case names that were archived |
