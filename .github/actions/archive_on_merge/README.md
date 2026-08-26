# archive_on_merge

Detects openspec change(s) completed by a merged PR, verifies every item in
each change's `tasks.md` is checked, and runs `openspec archive --yes --json`.

Prefer the reusable workflow for the full flow (detect + open archive PR):

[`archive-on-merge.yml`](../../workflows/archive-on-merge.yml)

## Composite action usage

Requires:

- **Node.js 18 or newer** — the script reads the PR's files over HTTP and uses
  global `fetch`. The reusable workflow's `node_version` input defaults to `22`;
  if you lower it below 18 the run fails with a message saying so. A shallow
  checkout is fine — nothing walks a local commit range.
- The `openspec` CLI on `PATH` (install `@fission-ai/openspec` first).
- A checkout of the consumer repo at the base branch, already containing the
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

Change names come back sorted, so the branch slug the caller derives from them
is the same whatever order the API listed the files in.

### What a declined archive reports

A change with unchecked tasks is not archived, and the run stays green — that is
correct (an unfinished change is not a failure), but it means nobody looks. So
the skip is reported three ways instead of one log line:

- **Log** — every remaining task, grouped by its `tasks.md` section, cited as
  `tasks.md:<line>`.
- **Annotation** — a `::notice::` with the count, so it appears on the run
  summary page without opening the log.
- **Job summary** — a table of the remaining tasks, each line number linked to
  the checked-out commit, so the line numbers match what the run actually read.

#### Marking a post-merge section

Tasks that can only be done *after* the merge can never be checked before the
merge that would trigger the archive, so a change holding them will never
archive automatically. The report calls this out — without it, the run just
repeats "still has incomplete tasks" on every future merge.

Mark such a section either way:

- **Explicitly** — put `[post-merge]` anywhere in the heading. Unambiguous, and
  the recommended form.
- **By phrasing** — a heading that *starts* with `Post-merge`, `Post-release`,
  `Post-deployment`, `After the merge`, `After merging`, `After deployment`, or
  `Once merged` (an optional `6.` style number may precede it).

The phrase check is anchored to the start of the heading on purpose, so the
phrase has to be the section's subject. `Pre-merge checks (do these before, not
after merging)` is *not* treated as post-merge — an unanchored match there would
tell the author the opposite of the truth. If a heading does not fit the list
above, use the `[post-merge]` marker rather than relying on the wording.

Checkboxes and headings inside fenced code blocks are ignored, so a `#` comment
or a sample `- [ ]` row in a shell snippet is not mistaken for a real section or
task. Files with CRLF, CR, or U+2028 line endings parse the same as LF.

### Failure handling

`pull_request: closed` never fires twice for the same merge, so a request lost
to a blip loses that archive for good. Each attempt is therefore capped at 30s
and retried up to 3 times with exponential backoff on network errors, timeouts,
5xx, 429, and the rate-limit flavour of 403 (identified by `retry-after` or
`x-ratelimit-remaining: 0`). A 403 without those headers is a permissions
failure — a real answer — and fails immediately rather than retrying three
times and burying the cause.

## Tests

```bash
node --test .github/actions/archive_on_merge/archive-on-merge.test.js
```

No dependencies and no `package.json` — the tests use the runner built into
Node 18+ and a stub HTTP server. CI runs them via
[`lint-actions.yml`](../../workflows/lint-actions.yml).

### Outputs

| Name | Description |
| --- | --- |
| `archived` | `'true'` when at least one change was archived, otherwise `'false'` |
| `changes` | Comma-separated kebab-case names that were archived (empty when none) |
