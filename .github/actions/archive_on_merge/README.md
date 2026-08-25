# archive_on_merge

Detects openspec change(s) completed by a merged PR, verifies every item in
each change's `tasks.md` is checked, and runs `openspec archive --yes --json`.

Prefer the reusable workflow for the full flow (detect + open archive PR):

[`archive-on-merge.yml`](../../workflows/archive-on-merge.yml)

## Composite action usage

Requires the `openspec` CLI on `PATH` (install `@fission-ai/openspec` first)
and a checkout of the consumer repo at the base branch, already containing the
merge.

```yaml
- uses: deriv-com/shared-actions/.github/actions/archive_on_merge@master
  id: archive
  with:
    pr_number: ${{ github.event.pull_request.number }}
    github_token: ${{ secrets.GITHUB_TOKEN }}
```

### Inputs

| Name | Required | Description |
| --- | --- | --- |
| `pr_number` | yes | Number of the merged PR whose files are inspected |
| `github_token` | yes | Token with `pull-requests: read` to list the PR's files |
| `repository` | no | `owner/repo` the PR belongs to (default `github.repository`) |

### Which files count as "touched"

The changed-file list comes from the GitHub API (`GET /repos/{repo}/pulls/{n}/files`),
not from a local `git diff`. `base.sha..merge_commit_sha` is *not* the PR's own
diff — for a PR opened against an older base it also contains every commit
merged in between, so an unrelated PR merged afterwards would appear to touch a
change some earlier PR had completed and would archive it a second time. Asking
the API is exact and works the same for merge, squash, and rebase merges.

### Outputs

| Name | Description |
| --- | --- |
| `archived` | `'true'` when at least one change was archived, otherwise `'false'` |
| `changes` | Comma-separated kebab-case names that were archived (empty when none) |
