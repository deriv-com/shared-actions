# Doc Sync Agent

An intelligent GitHub Action that automatically maintains documentation (README.md and CLAUDE.md) by analyzing code changes and using Claude AI to determine if updates are needed.

## Features

- **AI-Powered Analysis**: Uses Claude AI (acting as an Architect Engineer) to intelligently decide when documentation needs updating
- **Automatic PR Creation**: Creates pull requests with updated documentation when needed
- **Smart Decision Making**: Conservative approach - only updates documentation for significant, user-facing changes
- **Slack Integration**: Sends notifications to #docsync_private channel
- **Comprehensive Error Handling**: Gracefully handles failures and always notifies the team

## How It Works

1. **Triggers on PR Merge**: Runs when code is merged to main/master branch
2. **Analyzes Changes**: Extracts the diff and understands what changed
3. **Claude AI Review**: Claude acts as an architect to determine if docs need updating
4. **Selective Updates**: Only updates README.md and/or CLAUDE.md if needed
5. **Creates PR**: Generates a pull request with the updated documentation
6. **Notifies Team**: Posts results to Slack (#docsync_private)

## Usage

### 1. Add Workflow to Your Repository

Create `.github/workflows/doc-sync.yml` in your repository:

```yaml
name: Doc Sync Agent

on:
  push:
    branches:
      - main
      - master

jobs:
  sync-docs:
    name: Sync Documentation
    runs-on: ubuntu-latest

    permissions:
      contents: write        # Required to push changes
      pull-requests: write   # Required to create PRs

    steps:
      - name: Run Doc Sync Agent
        uses: deriv-com/shared-actions/.github/actions/doc_sync_agent@master
        with:
          github_token: ${{ secrets.DOC_SYNC_PAT }}
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          slack_webhook_url: ${{ secrets.SLACK_WEBHOOK_DOCSYNC }}
          slack_users_to_tag: 'U123ABC,U456DEF'  # Optional: Slack user IDs to mention
          repository: ${{ github.repository }}
          commit_sha: ${{ github.sha }}
          base_branch: ${{ github.ref_name }}
```

### 2. Configure Required Secrets

Add these secrets to your repository (Settings → Secrets and variables → Actions):

#### `ANTHROPIC_API_KEY`
- Your Anthropic API key for Claude
- Get it from: https://console.anthropic.com/
- Requires access to Claude 3.5 Sonnet

#### `DOC_SYNC_PAT`
- GitHub Personal Access Token with the following permissions:
  - `repo` (Full control of private repositories)
  - OR at minimum: `contents:write` and `pull-requests:write`
- Create at: https://github.com/settings/tokens
- **Note**: `GITHUB_TOKEN` doesn't work because it can't trigger workflows on created PRs

#### `SLACK_WEBHOOK_DOCSYNC`
- Slack Incoming Webhook URL for the #docsync_private channel
- Get it from: https://api.slack.com/messaging/webhooks
- Format: `https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXX`

#### Finding Slack User IDs (Optional)

To mention specific users in Slack notifications:
1. In Slack, click on a user's profile
2. Click the "More" (three dots) menu
3. Select "Copy member ID"
4. Pass comma-separated IDs via `slack_users_to_tag` input

Example: `slack_users_to_tag: 'U01ABC123,U02DEF456'`

### 3. Create Initial Documentation (Optional)

If you want Claude to maintain a `CLAUDE.md` file, create it with initial content:

```markdown
# Claude Development Guide

## Project Overview
[Describe your project for AI assistants]

## Architecture
[Key architectural decisions]

## Development Guidelines
[Guidelines for AI tools working with this codebase]
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `github_token` | GitHub PAT with contents:write and pull-requests:write | Yes | - |
| `anthropic_api_key` | Anthropic API key for Claude | Yes | - |
| `slack_webhook_url` | Slack webhook URL for #docsync_private | Yes | - |
| `slack_users_to_tag` | Comma-separated Slack user IDs to mention (e.g., U123ABC,U456DEF) | No | `` |
| `repository` | Repository name (owner/repo) | Yes | - |
| `commit_sha` | Commit SHA that triggered workflow | Yes | - |
| `base_branch` | Base branch name | No | `main` |
| `docs_to_check` | Comma-separated list of docs to check | No | `README.md,CLAUDE.md` |

## Outputs

| Output | Description |
|--------|-------------|
| `pr_created` | Whether a PR was created (`true`/`false`) |
| `pr_url` | URL of the created PR (if any) |
| `pr_number` | Number of the created PR (if any) |
| `files_updated` | Comma-separated list of updated files |
| `claude_reasoning` | Claude's explanation for the decision |
| `status` | Overall status (`success`/`skipped`/`failed`) |

## When Documentation Gets Updated

### README.md Updates Triggered By:
- New features or functionality
- Changes to setup/installation instructions
- API or usage pattern changes
- Configuration changes
- Dependency changes that affect users
- New examples or getting started guides

### CLAUDE.md Updates Triggered By:
- AI/LLM integration changes
- Claude-specific workflows or prompts
- Architecture changes relevant to AI assistants
- Development guidelines for AI tools
- Context about how AI should interact with the codebase

### NOT Updated For (Conservative Approach):

Claude takes a **conservative approach** and will NOT update documentation for:

- ❌ Minor bug fixes (unless critical and user-facing)
- ❌ Small UI changes (colors, spacing, fonts, styling tweaks)
- ❌ Internal code refactoring or reorganization
- ❌ Dependency version bumps (unless they require user action)
- ❌ Code formatting, linting, or style changes
- ❌ Internal variable/function/class renames
- ❌ Performance optimizations (unless they change usage)
- ❌ Test file changes or coverage improvements
- ❌ CI/CD configuration updates
- ❌ Development tooling changes (prettier, eslint, etc.)

**Philosophy**: Documentation updates should only happen when the changes genuinely impact how users understand or interact with the project. This prevents documentation churn and ensures updates are meaningful.

## Slack Notifications

The action sends a Slack notification **only when a PR is created**.

### 📚 PR Created
```
<@U123ABC> <@U456DEF>
📚 Documentation Sync PR Created
View PR in `owner/repo`

Files Updated: README.md, CLAUDE.md
Commit: abc1234

Reasoning:
Added new authentication feature that requires documentation updates...
```

**Notes**:
- User mentions (`<@U123ABC>`) only appear if `slack_users_to_tag` is configured
- No notification is sent when no updates are needed or if the action fails
- Check workflow run logs for full details on all executions

## Advanced Usage

### Custom Documentation Files

Check different documentation files:

```yaml
- uses: deriv-com/shared-actions/.github/actions/doc_sync_agent@master
  with:
    # ... other inputs ...
    docs_to_check: 'README.md,CONTRIBUTING.md,API.md'
```

### Different Base Branch

For repositories using `master` instead of `main`:

```yaml
- uses: deriv-com/shared-actions/.github/actions/doc_sync_agent@master
  with:
    # ... other inputs ...
    base_branch: master
```

### Using Outputs

Use the outputs in subsequent steps:

```yaml
- name: Run Doc Sync Agent
  id: doc-sync
  uses: deriv-com/shared-actions/.github/actions/doc_sync_agent@master
  with:
    # ... inputs ...

- name: Comment on Original PR
  if: steps.doc-sync.outputs.pr_created == 'true'
  run: |
    echo "Documentation PR created: ${{ steps.doc-sync.outputs.pr_url }}"
```

## Troubleshooting

### PR Creation Fails

**Error**: `Failed to create PR`

**Solutions**:
1. Ensure `DOC_SYNC_PAT` has `contents:write` and `pull-requests:write` permissions
2. Check that the token hasn't expired
3. Verify the repository allows PR creation from actions

### Claude API Timeout

**Error**: `Claude API call failed or timed out`

**Solutions**:
1. Check if diff is too large (>5000 lines is filtered)
2. Verify `ANTHROPIC_API_KEY` is valid and has sufficient credits
3. Network issues - action will retry on next merge

### Invalid JSON Response

**Error**: `Invalid JSON response from Claude`

**Solutions**:
1. Usually resolves on retry (Claude occasionally returns malformed JSON)
2. Check Claude API status: https://status.anthropic.com/
3. Review workflow logs for the raw response

### No Slack Notification

**Error**: Slack notification not received

**Solutions**:
1. Verify `SLACK_WEBHOOK_DOCSYNC` is correct and active
2. Check #docsync_private channel permissions
3. Webhook may be rate-limited - check Slack app settings

## How Claude Makes Decisions

Claude analyzes your changes using:

1. **Diff Analysis**: Reviews all code changes line-by-line
2. **Current Documentation**: Reads existing README.md and CLAUDE.md
3. **Context Understanding**: Considers commit messages and PR titles
4. **Impact Assessment**: Determines if changes are user-facing
5. **Documentation Generation**: Creates complete updated files (not diffs)

Claude is prompted to:
- Preserve existing formatting and structure
- Only update when changes are meaningful
- Generate complete file content
- Provide clear reasoning for decisions

## Performance

- **Average Runtime**: 30-60 seconds
- **Claude API Call**: ~10-20 seconds
- **PR Creation**: ~5-10 seconds
- **Max Timeout**: 120 seconds for Claude API

## Security

- All secrets are handled securely via GitHub Actions secrets
- Claude AI does not store or train on your code
- Git credentials are scoped to the repository
- Slack webhooks are write-only

## Examples

See these repositories using doc_sync_agent:
- [Coming soon - add examples after deployment]

## Contributing

Found a bug or want to improve the action? Please open an issue or PR in the [shared-actions repository](https://github.com/deriv-com/shared-actions).

## License

This action is part of the Deriv shared-actions repository.

---

🤖 **Powered by Claude AI** | Built for the Deriv organization
