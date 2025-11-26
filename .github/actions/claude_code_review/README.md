# Claude Code Review Assistant

A reusable GitHub Action that uses Claude AI to review pull requests with organization member verification.

## Features

- Automated PR reviews using Claude AI
- Organization member verification before running reviews
- Customizable review prompts
- Progress tracking
- Works with forked repositories

## Usage

To use this action in your repository, create a workflow file (e.g., `.github/workflows/claude-review.yml`):

```yaml
name: Claude Code Review

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

jobs:
  claude-assistant:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest

    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
      actions: read

    # Cancel older runs when new commits arrive on the same PR
    concurrency:
      group: pr-${{ github.event.pull_request.number }}
      cancel-in-progress: true

    steps:
      - name: Run Claude Code Review
        uses: deriv-com/shared-actions/.github/actions/claude_code_review@master
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          personal_access_token: ${{ secrets.PERSONAL_ACCESS_TOKEN }}
          pr_number: ${{ github.event.pull_request.number }}
          pr_user_login: ${{ github.event.pull_request.user.login }}
          pr_head_repo: ${{ github.event.pull_request.head.repo.full_name }}
          pr_head_ref: ${{ github.event.pull_request.head.ref }}
          repository: ${{ github.repository }}
```

## Inputs

| Input                   | Description                                         | Required | Default                 |
| ----------------------- | --------------------------------------------------- | -------- | ----------------------- |
| `github_token`          | GitHub token for PR operations                      | Yes      | -                       |
| `anthropic_api_key`     | Anthropic API key for Claude                        | Yes      | -                       |
| `personal_access_token` | Personal access token for organization verification | Yes      | -                       |
| `pr_number`             | Pull request number                                 | Yes      | -                       |
| `pr_user_login`         | Pull request author username                        | Yes      | -                       |
| `pr_head_repo`          | Pull request head repository full name              | Yes      | -                       |
| `pr_head_ref`           | Pull request head ref                               | Yes      | -                       |
| `repository`            | Repository name (owner/repo)                        | Yes      | -                       |
| `review_prompt`         | Custom review prompt                                | No       | Default review criteria |

## Required Secrets

You need to configure the following secrets in your repository:

1. **`ANTHROPIC_API_KEY`**: Your Anthropic API key for Claude

   - Get it from: https://console.anthropic.com/

2. **`PERSONAL_ACCESS_TOKEN`**: GitHub Personal Access Token with `read:org` permission

   - Used for verifying organization membership
   - Create one at: https://github.com/settings/tokens

3. **`GITHUB_TOKEN`**: Automatically provided by GitHub Actions
   - No manual setup needed

## Custom Review Prompt

You can customize the review criteria by providing a `review_prompt` input:

```yaml
- name: Run Claude Code Review
  uses: deriv-com/shared-actions/.github/actions/claude_code_review@master
  with:
    # ... other inputs ...
    review_prompt: |
      Please review this pull request focusing on:
      - API design and contract changes
      - Database migration safety
      - Backward compatibility
      - Documentation updates
```

## Permissions Required

The workflow calling this action needs these permissions:

```yaml
permissions:
  contents: read # Read repository code
  pull-requests: write # Comment on PRs
  issues: write # Create/update comments
  id-token: write # For authentication
  actions: read # Read workflow information
```

## How It Works

1. **User Verification**: Verifies that the PR author is a member of the deriv-com organization
2. **Checkout**: Checks out the PR head (works with forks)
3. **Review**: Runs Claude Code Action to review the PR
4. **Feedback**: Posts inline comments and a summary on the PR

## Notes

- The action only runs for organization members (deriv-com)
- It automatically handles forked repositories
- Concurrent runs for the same PR are cancelled when new commits arrive
- Timeout is handled by the underlying Claude Code Action
