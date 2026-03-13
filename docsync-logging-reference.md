# DocSync AI — Logging, GitHub Actions Summary & Event Payloads

---

## Overview

All events are first appended to a JSONL file at `/tmp/docsync_events_${GITHUB_RUN_ID}.jsonl`. At the end of each job's **Summary** step, every event is:

1. **POSTed** to `AGENT_METRICS_API_URL/api/v1/events` (if `AGENT_METRICS_API_URL` is set), with `X-API-Key` header.
2. **Rendered** in the GitHub Actions job summary as collapsible `<details>` blocks.
3. **Deleted** from disk after rendering.

All events share this top-level envelope:

```json
{
  "agent": "DocSync AI",
  "event_type": "<see below>",
  "run_id": "<GITHUB_RUN_ID>",
  "trigger_type": "scheduled" | "comment",
  "timestamp": "<ISO 8601 UTC>",
  "payload": { ... }
}
```

---

## 1. Scheduled Trigger (`trigger_type: "scheduled"`)

### 1.1 GitHub Actions Step Summary Content

| Step | What is written to the summary |
|---|---|
| **Debug — Workflow Trigger Info** | `## Workflow Trigger Info` · Event name · Trigger Type · Base Branch · Repository |
| **Debug — Repository State** *(inside action)* | `## Repository State` · Working directory · Current branch · Latest commit (one-liner) · Any `README.md` / `CLAUDE.md` found |
| **Fetch Weekly Merged PRs** *(inside action)* | `## Weekly Merged PRs` · Repository · Since-date · PR count (excluding DocSync/automated) · Bulleted list of `- PR #N: <title>` · `### Changed Files` code block (up to 50 files, workflows excluded) |
| **Claude Sonnet 4.5 Analysis** *(inside action)* | `## Claude Sonnet 4.5 Analysis` · Model name · PR count · Large-diff detection (size, chunk count, per-chunk result) · `### Documentation File Detection` (README.md / CLAUDE.md found/not found) · Per-file progress lines (`Calling Claude API…`, `Updating X (N -> M chars)`, `No updates needed`) |
| **Check for Documentation Changes** *(inside action)* | `Documentation updates detected` or `No documentation updates needed` · `### Changed Files` code block (git cached diff) |
| **Close Existing DocSync PRs** *(inside action)* | `Closed N existing PR(s)` (if any were open) |
| **Create Documentation PR** *(inside action)* | `### Documentation PR Created: #N` · PR URL |
| **Send Slack Notification** | `### Slack Notification` · Channel · PR number · `Slack notification sent successfully` or API error + raw response |
| **Summary** | Metrics table (see below) · `### 📡 Metrics Dashboard` with POST counts · `## 📊 DocSync AI — Event Log` with all events as collapsible JSON blocks |

**Summary step metrics table:**

| Metric | Value |
|---|---|
| Trigger | Weekly Scheduled |
| Documentation PR Created | true / false |
| Status | success / failure |
| Base Branch | `<branch>` |

---

### 1.2 Events Logged — Scheduled

#### `workflow_triggered`

```json
{
  "payload": {
    "repository": "owner/repo",
    "base_branch": "master",
    "workflow_name": "docsync-ai"
  }
}
```

---

#### `prs_fetched`

Emitted after fetching merged PRs. Always emitted, even when 0 PRs found or all changes are workflow-only.

```json
{
  "payload": {
    "pr_count": 3,
    "pr_numbers": ["PR-123", "PR-124", "PR-125"],
    "period_days": 7,
    "changed_files_count": 12,
    "changed_files": ["src/api.ts", "lib/utils.py", "..."]
  }
}
```

> When 0 PRs or workflow-only changes: `pr_count: 0`, `changed_files_count: 0`, `changed_files: []`

---

#### `claude_analysis_started`

```json
{
  "payload": {
    "model": "claude-sonnet-4-5",
    "max_tokens": 16384,
    "pr_count": 3,
    "mode": "pr_analysis"
  }
}
```

---

#### `claude_api_call` — chunk summarization *(only when diff > 600,000 chars)*

Emitted once per chunk.

```json
{
  "payload": {
    "call_type": "chunk_summarization",
    "target_file": null,
    "chunk_index": 1,
    "total_chunks": 4,
    "model": "claude-sonnet-4-5",
    "input_tokens": 3200,
    "output_tokens": 512,
    "prompt_chars": 498000,
    "response_chars": 1800,
    "latency_ms": 4321,
    "http_status": "200",
    "api_error_type": null,
    "result": "updated" | "no_updates_needed" | "error"
  }
}
```

---

#### `claude_api_call` — doc update

Emitted once per documentation file processed (README.md and/or CLAUDE.md).

```json
{
  "payload": {
    "call_type": "doc_update",
    "target_file": "README.md",
    "chunk_index": null,
    "total_chunks": null,
    "model": "claude-sonnet-4-5",
    "input_tokens": 8500,
    "output_tokens": 6200,
    "prompt_chars": 32000,
    "response_chars": 24000,
    "latency_ms": 12500,
    "http_status": "200",
    "api_error_type": null,
    "result": "updated" | "no_updates_needed" | "error"
  }
}
```

---

#### `error_occurred`

Emitted whenever a Claude API call fails (invalid JSON response, API error, or missing content field).

```json
{
  "payload": {
    "step": "claude_api_call",
    "target_file": "README.md" | null,
    "error_type": "invalid_json" | "api_error",
    "error_message": "Invalid JSON response from Anthropic API during doc update",
    "http_status": "500",
    "recoverable": false,
    "continued": false
  }
}
```

> `recoverable: true / continued: true` for chunk errors (processing continues to next chunk).
> `recoverable: false / continued: false` for doc-update errors (that file is skipped).

---

#### `claude_analysis_completed`

```json
{
  "payload": {
    "status": "success",
    "skip_analysis": false,
    "reason": "Updates generated" | "No documentation changes required" | "No documentation files found",
    "input_tokens": 11700,
    "output_tokens": 6712,
    "total_tokens": 18412,
    "files_to_update": ["README.md", "CLAUDE.md"],
    "diff_size_chars": 45000,
    "diff_chunked": false,
    "total_chunks": 0,
    "doc_changes": [
      {
        "file": "README.md",
        "before_chars": 3200,
        "after_chars": 3950,
        "before_lines": 102,
        "after_lines": 118,
        "net_change_chars": 750
      }
    ]
  }
}
```

> `doc_changes` contains one entry per updated file. Empty array `[]` when no files were updated.

---

#### `doc_pr_created`

```json
{
  "payload": {
    "pr_number": "PR-456",
    "pr_title": "DocSync AI: Update Documentation",
    "pr_url": "https://github.com/owner/repo/pull/456",
    "branch": "docs/auto-update-20260311-143022-a1b2c3d4",
    "files_updated": ["README.md", "CLAUDE.md"]
  }
}
```

---

#### `slack_notification_sent`

```json
{
  "payload": {
    "status": "success" | "failed",
    "channel": "C01234ABCDE",
    "message_type": "documentation_update",
    "pr_link": "https://github.com/owner/repo/pull/456"
  }
}
```

---

#### `workflow_completed`

```json
{
  "payload": {
    "status": "success" | "failed",
    "duration_seconds": 187,
    "doc_pr_created": true,
    "changes_made": true,
    "error": null | "Job failed with status: failure"
  }
}
```

---

## 2. Comment Trigger (`trigger_type: "comment"`)

### 2.1 GitHub Actions Step Summary Content

| Step | What is written to the summary |
|---|---|
| **Acknowledge Comment with 👍** | *(no summary output — adds GitHub reaction only)* |
| **Debug — Comment Trigger Info** | `## Comment Trigger Info` · Trigger Type · PR Number · Comment ID · Repository |
| **Parse Command** *(inside action)* | `## Parsing @docbot Command` · Comment ID · `### Command: \`<type>\`` · Instruction display (first 500 chars, in a code block) |
| **Verify PR Type** *(inside action)* | `## Verifying PR` · `### PR Information` (Title · Branch · Labels) · Detection result (`DocSync PR detected` or `Regular PR detected`) |
| **Handle Revert Commands** *(inside action, if revert)* | `## Handling Revert` · Revert type · Commit found (`` `abc1234` — <message> ``) · `✅ Successfully reverted` or `❌ Revert failed` |
| **Fetch PR Diff** *(inside action, regular PRs only)* | `## Fetching PR Diff` · `### Changed Files` code block (up to 50 files) |
| **Claude Sonnet 4.5 Analysis** *(inside action)* | `## Claude Sonnet 4.5 Analysis` · Model · Target file filter (🎯 banner if `update only` command) · Doc file detection · Large diff handling · Per-file progress |
| **Commit Changes to PR** *(inside action)* | `Documentation updates detected` or `No documentation updates needed` · `### Changed Files` code block · `### Changes Committed and Comment Added` |
| **Action Summary** *(inside action)* | `## Action Summary` · Command Valid · Command · Target File · Is DocSync PR · Documentation Updated |
| **Send Slack Notification** | `### Slack Notification` · Channel · PR number · success/error |
| **Summary (workflow)** | Metrics table (see below) · `### 📡 Metrics Dashboard` · `## 📊 DocSync AI — Event Log` |

**Summary step metrics table:**

| Metric | Value |
|---|---|
| PR Number | #`<N>` |
| Valid Command | true / false |
| Command | `update` / `revert_last` / `revert_to` / `none` |
| Is DocSync PR | true / false |
| Documentation Updated | true / false |
| Status | success / failure |

---

### 2.2 Events Logged — Comment

#### `workflow_triggered`

Identical structure to scheduled, with `trigger_type: "comment"`.

```json
{
  "payload": {
    "repository": "owner/repo",
    "base_branch": "master",
    "workflow_name": "docsync-ai"
  }
}
```

---

#### `comment_detected`

Emitted as soon as the command is validated as a real `@docbot` command.

```json
{
  "payload": {
    "pr_number": "PR-789",
    "comment_author": "N/A",
    "comment_body": "@docbot update only readme.md fix the installation steps..."
  }
}
```

> `comment_body` is capped at **500 characters**. `comment_author` is always `"N/A"` — the author is not fetched from the GitHub API.

---

#### `pr_analyzed`

Emitted after fetching the diff for **regular PRs only**. Skipped entirely for DocSync PRs (those are handled by direct user instruction, no diff needed).

```json
{
  "payload": {
    "pr_number": "PR-789",
    "files_changed": 7,
    "changed_files": ["src/auth.ts", "lib/api.py", "..."]
  }
}
```

> When all changes are workflow-only: `files_changed: 0`, `changed_files: []`

---

#### `claude_analysis_started`

```json
{
  "payload": {
    "model": "claude-sonnet-4-5",
    "max_tokens": 16384,
    "mode": "pr_analysis"
  }
}
```

> Note: **no `pr_count` field** for the comment trigger (unlike scheduled).

---

#### `claude_api_call` — chunk summarization

Identical structure to scheduled, with `trigger_type: "comment"`.

---

#### `claude_api_call` — doc update

Identical structure to scheduled, with `trigger_type: "comment"`.

---

#### `error_occurred`

Identical structure to scheduled, with `trigger_type: "comment"`.

---

#### `claude_analysis_completed`

Identical structure to scheduled, with `trigger_type: "comment"` and the same `doc_changes` array.

---

#### `changes_committed`

Emitted only when documentation changes are successfully committed and pushed to the PR branch.

```json
{
  "payload": {
    "pr_number": "PR-789",
    "commit_hash": "abc1234",
    "commit_message": "DocSync AI: Apply @docbot instruction to README.md\n\nApplied documentation updates based on user command.\n\nGenerated by DocSync AI",
    "files_updated": ["README.md"]
  }
}
```

---

#### `confirmation_comment_posted`

Emitted after the bot posts its reply comment on the PR.

```json
{
  "payload": {
    "pr_number": "PR-789",
    "message": "Documentation updated with your suggestion.",
    "changes_made": true
  }
}
```

---

#### `slack_notification_sent`

Identical structure to scheduled, with `trigger_type: "comment"`.

---

#### `workflow_completed`

```json
{
  "payload": {
    "status": "success" | "failed",
    "duration_seconds": 94,
    "doc_pr_created": false,
    "changes_made": true,
    "error": null | "Job failed with status: failure"
  }
}
```

> `doc_pr_created` is **always `false`** for comment-triggered runs — the comment flow commits directly to the existing PR branch rather than opening a new PR.

---

## 3. Complete Event Type Reference

| Event Type | Scheduled | Comment | When emitted |
|---|:---:|:---:|---|
| `workflow_triggered` | ✅ | ✅ | First step of every run |
| `prs_fetched` | ✅ | — | After GitHub API call for merged PRs |
| `comment_detected` | — | ✅ | After `@docbot` command is validated |
| `pr_analyzed` | — | ✅ | After diff is fetched (regular PRs only) |
| `claude_analysis_started` | ✅ | ✅ | Before any Claude API call |
| `claude_api_call` | ✅ | ✅ | Per chunk (summarization) and per doc file (update) |
| `error_occurred` | ✅ | ✅ | On any Claude API failure |
| `claude_analysis_completed` | ✅ | ✅ | After all Claude calls for the run |
| `doc_pr_created` | ✅ | — | After new documentation PR is opened |
| `changes_committed` | — | ✅ | After commit is pushed to the PR branch |
| `confirmation_comment_posted` | — | ✅ | After bot comment is posted on the PR |
| `slack_notification_sent` | ✅ | ✅ | After Slack API call (only if tokens set) |
| `workflow_completed` | ✅ | ✅ | Final step (always runs) |

---

## 4. Key Differences: Scheduled vs Comment

| Behaviour | Scheduled | Comment |
|---|---|---|
| Scope | All PRs merged in the last 7 days | Single PR (the one commented on) |
| Output | Opens a **new documentation PR** | Commits directly to **existing PR branch** |
| `doc_pr_created` in `workflow_completed` | `true` (if PR opened) | Always `false` |
| Unique events | `prs_fetched`, `doc_pr_created` | `comment_detected`, `pr_analyzed`, `changes_committed`, `confirmation_comment_posted` |
| `claude_analysis_started` — `pr_count` field | Present | Absent |
| DocSync PR handling | N/A | Detected via label/title; applies user instruction directly without fetching a diff |
| Revert commands | Not supported | `revert_last` and `revert_to <hash>` |
| Target file filtering | Always both files (if present) | Can be filtered to README or CLAUDE only via `update only` command |
| Slack message text | "Weekly Documentation Update Ready" | "Documentation Updated via Comment" |

---

## 5. `claude_api_call` — `result` Field Values

| Value | Meaning |
|---|---|
| `updated` | Claude returned new documentation content that was written to disk |
| `no_updates_needed` | Claude returned `NO_UPDATES_NEEDED` — file unchanged |
| `error` | API call failed (see accompanying `error_occurred` event) |

---

## 6. `claude_analysis_completed` — `doc_changes` Array

Each element represents one documentation file that was **actually modified**:

| Field | Type | Description |
|---|---|---|
| `file` | string | File name (e.g. `README.md`) |
| `before_chars` | integer | Character count before Claude update |
| `after_chars` | integer | Character count after Claude update |
| `before_lines` | integer | Line count before Claude update |
| `after_lines` | integer | Line count after Claude update |
| `net_change_chars` | integer | `after_chars - before_chars` (positive = content added) |

> Only files that were **actually updated** appear here. Files where Claude returned `NO_UPDATES_NEEDED` are excluded.

---

*Generated from source: `.github/workflows/docsync-ai.yml`, `.github/actions/docsync_ai/action.yml`, `.github/actions/docsync_ai_comment/action.yml`*
