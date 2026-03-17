<pre style="color: #223f99; font-family: monospace;">
╔══════════════════════════════════════════════════════════════════════════════════════════╗
║   ____                            _                                  ____        _       ║
║  |  _ \  ___ _ __   ___ _ __   __| | ___  _ __  _ __ ___   ___      | __ )  ___ | |_     ║
║  | | | |/ _ \ '_ \ / _ \ '_ \ / _` |/ _ \| '_ \| '_ ` _ \ / _ \_____|  _ \ / _ \| __|    ║
║  | |_| |  __/ |_) |  __/ | | | (_| | (_) | | | | | | | | |  __/_____| |_) | (_) | |_     ║
║  |____/ \___| .__/ \___|_| |_|\__,_|\___/|_| |_|_| |_| |_|\___|     |____/ \___/ \__|    ║
║             |_|                                                                          ║
╚══════════════════════════════════════════════════════════════════════════════════════════╝
</pre>

A reusable GitHub Actions workflow that automatically fixes Dependabot security vulnerabilities.

## Features

- 🔍 Scans for open Dependabot alerts
- 🔧 Automatically updates vulnerable packages to latest versions
- 🔀 Creates a PR with all fixes
- 🤖 Enables auto-merge for safe changes (only `package.json` + `package-lock.json`)
- 📢 Sends Slack notifications for PR creation and failures
- ♻️ Self-healing: re-runs after merge to catch remaining alerts

## Usage

Call this reusable workflow from your repository:

```yaml
name: 🔒 Security Auto-Fix

on:
  schedule:
    - cron: '0 8 * * 1'  # Every Monday at 8am
  workflow_dispatch:

jobs:
  fix-vulnerabilities:
    uses: deriv-com/shared-action/.github/workflows/dependonme-bot.yml@<commit-hash> # pin to specific version
    with:
      slack_users_to_tag: 'U12345678,U87654321'
      base_branch: 'master'
      auto_merge: true
    secrets:
      DEPENDONME_BOT_TOKEN: ${{ secrets.DEPENDONME_BOT_TOKEN }}
      DEPENDONME_BOT_SLACK: ${{ secrets.SLACK_WEBHOOK_URL }}
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `slack_users_to_tag` | Comma-separated Slack user IDs to tag | ✅ | - |
| `base_branch` | Base branch for PR | ❌ | `master` |
| `auto_merge` | Enable auto-merge for safe PRs | ❌ | `true` |
| `dry_run` | Preview changes without creating PR | ❌ | `false` |
| `pr_labels` | Comma-separated labels for PR | ❌ | `security,dependencies` |
| `node_version` | Node.js version to use | ❌ | `20` |
| `npm_legacy_peer_deps` | Use `--legacy-peer-deps` flag | ❌ | `true` |
| `exclude_packages` | Comma-separated packages to exclude | ❌ | - |

## Secrets

| Secret | Description | Required |
|--------|-------------|----------|
| `DEPENDONME_BOT_TOKEN` | GitHub PAT for PR creation & auto-merge | ✅ |
| `DEPENDONME_BOT_SLACK` | Slack webhook URL for notifications | ✅ |

> ⚠️ **Note:** Reusable workflows run in the caller's context. Secrets must be passed from the calling workflow.

## Slack Notifications

### PR Created
```
@user1 @user2
PR #42 in `org/repo`

- axios → latest (fixes >= 0.30.2)
- webpack → latest (fixes >= 5.2.1)
- lodash → (override conflict)
```

### All Updates Failed
```
@user1 @user2 :alert_1:
1 alert in `org/repo` could not be auto-fixed

- axios → (override conflict)
```

## How It Works

1. Fetches all open Dependabot alerts via GitHub API
2. Groups alerts by package and finds minimum required version
3. Updates each package to latest version
4. Skips packages with conflicts (peer deps, overrides)
5. Verifies only `package.json` and `package-lock.json` changed
6. Creates PR with auto-merge enabled (if safe)
7. Sends Slack notification with results

