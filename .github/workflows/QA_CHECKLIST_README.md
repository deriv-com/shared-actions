# QA Checklist Generator (`qa-checklist.yml`)

Posts an end-user testing checklist on a pull request when someone comments `@checkmaite`. Claude Code (`anthropics/claude-code-action`) reads the PR diff and writes a checklist scoped to what changed.

## Calling it

The caller listens for `issue_comment` and gates on the commenter before calling, because the shared workflow's per-PR concurrency group cancels an in-progress run as soon as a new run is scheduled:

```yaml
name: QA Checklist Generator (@checkmaite)

on:
  issue_comment:
    types: [created]

jobs:
  generate-checklist:
    if: |
      github.event.issue.pull_request &&
      contains(fromJSON('["OWNER","MEMBER","COLLABORATOR"]'), github.event.comment.author_association) &&
      contains(github.event.comment.body, '@checkmaite')
    uses: deriv-com/shared-actions/.github/workflows/qa-checklist.yml@master
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
      actions: read
    with:
      anthropic_base_url: https://litellmsa.deriv.ai
      # Leave the fallback to the shared workflow: an unset variable passes an
      # empty string, and the shared workflow then uses its own default.
      claude_model: ${{ vars.QA_CHECKLIST_MODEL }}
    secrets:
      ANTHROPIC_AUTH_TOKEN: ${{ secrets.FORGE_API_KEY }}
```

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `anthropic_base_url` | yes | | Gateway base URL without the trailing `/v1`. Claude Code appends `/v1/messages` itself. |
| `claude_model` | no | `claude-sonnet-5-5` | Must be an alias the gateway fronts. An unknown alias surfaces as a LiteLLM 500. An empty string also falls back to the default. A caller that hard-codes its own fallback (`vars.X \|\| 'claude-sonnet-5'`) keeps that model when the default here changes. |

| Secret | Required | Notes |
|---|---|---|
| `ANTHROPIC_AUTH_TOKEN` | yes | Bearer token for the gateway. |

## What it checks before running

- The commenter must be a `deriv-com` org member or a collaborator on the calling repo.
- PRs from forks are refused.

## Output

- A PR comment with the checklist. Its footer names the model the workflow requested, for example `Model: claude-sonnet-5-5`. That is the alias sent to the gateway. If the gateway maps the alias to another model, the footer does not show it. The footer is part of the prompt template, so it appears when Claude follows the template.
- A run summary table with trigger, PR, actor, model and status.
- An event-log artifact (`qa-checklist-event-log-<run_id>`, kept 90 days). Its `workflow_completed` event carries `payload.model`.
