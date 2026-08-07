## Shared Actions Repository

This repository is dedicated to hosting reusable GitHub Actions YAML files that can be shared across different repositories. Centralizing common actions, to promote consistency and efficiency in workflows.

#### Example Usage

```
      - name: Post preview build comment
        id: post_preview_build_comment
        uses: "deriv-com/shared-actions/.github/actions/post_preview_build_comment@master"
        with:
          issue_number: ${{steps.pr_information.outputs.issue_number}}
          head_sha: ${{github.event.workflow_run.head_sha}}
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
    permissions:
      contents: write
      pull-requests: write
```

Optional inputs: `base_branch` (default `master`), `node_version` (default
`22`), `openspec_version` (default `1.6.0`), `action_ref` (default `master` —
keep in sync with the workflow ref you call).

The detect/archive script is also available as a composite action:
[`archive_on_merge`](.github/actions/archive_on_merge/).
