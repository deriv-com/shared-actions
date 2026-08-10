<pre style="color: #223f99; font-family: monospace;">
╔══════════════════════════════════════════════════════════════════════════════════════════╗
║        _    ___   ____  ____    ____            _                                        ║
║       / \  |_ _| |  _ \|  _ \  |  _ \ _____   _(_) _____      __                         ║
║      / _ \  | |  | |_) | |_) | | |_) / _ \ \ / / |/ _ \ \ /\ / /                          ║
║     / ___ \ | |  |  __/|  _ <  |  _ <  __/\ V /| |  __/\ V  V /                           ║
║    /_/   \_\___| |_|   |_| \_\ |_| \_\___| \_/ |_|\___| \_/\_/                            ║
║                                                                                          ║
╚══════════════════════════════════════════════════════════════════════════════════════════╝
</pre>

A reusable GitHub Actions workflow that reviews pull requests with an LLM. The
engine is pluggable: pick `kimi` or `anthropic` with one input.

## Features

- 🤖 Full-context review — reads changed files whole, plus their imports, types, callers and tests
- 🔄 Follow-up mode — on re-push, feeds the previous review plus an incremental diff so fixed items are not re-reported
- 🧹 Exactly one review comment per PR, ever — old ones are captured and deleted first
- 🔌 Pluggable engine (`kimi` | `anthropic`), each a composite action with its own CLI and sandbox
- 🔒 The model gets **no shell tool** and no GitHub token — it cannot comment, and PR-supplied agent config is stripped before it starts
- ✅ Respects `Click2Fix - Acknowledge` comments — acknowledged suggestions are never raised again
- 📊 Emits events to the OneAboveAll metrics dashboard, and always to the job summary

## Usage

```yaml
name: AI PR Review

on:
  pull_request_target:
    types: [opened, synchronize, reopened, ready_for_review]

jobs:
  ai-review:
    uses: deriv-com/shared-actions/.github/workflows/ai-pr-review.yml@master
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
      actions: write
    with:
      engine: kimi          # or: anthropic
    secrets:
      LLM_API_KEY: ${{ secrets.LLM_API_KEY }}
      AGENT_METRICS_API_URL: ${{ secrets.AGENT_METRICS_API_URL }}
      AGENT_METRICS_API_KEY: ${{ secrets.AGENT_METRICS_API_KEY }}
```

Every consumer in this org pins `@master`, so that is the documented policy —
changes are live on merge. The `permissions` block is not optional: a reusable
workflow may not request more scopes than its caller grants, so a caller
granting less than the list above fails the run outright.

**Always set `engine` explicitly.** The default is `kimi`, so a repo migrating
from `claude-pr-review.yml` that omits it would silently switch LLM vendor.

## Engines

| | `kimi` | `anthropic` |
|---|---|---|
| Runtime | `@moonshot-ai/kimi-code` CLI (npm, pinned) | `anthropics/claude-code-action` (pinned by SHA) |
| Default model | `k3` | `claude-sonnet-5` |
| `base_url` sent | proxy origin **+ `/v1`** | proxy origin, **`/v1` stripped** |
| Tools granted | `Read`, `Write`, `Grep`, `Glob` | `Read`, `Write` |
| Shell | none (absent from `enabled` **and** denied by rule) | none (`--allowedTools` omits Bash) |
| Config stripped | `CLAUDE.md`, `AGENTS.md`, `KIMI.md`, `.kimi-code/` | `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.mcp.json`, `.claude/`, `.claude-plugin/` |
| Applicable inputs | all, incl. `max_context_size`, `cli_version` | all except `max_context_size`, `cli_version` |
| `agent` reported | `ai_review` | `claude_review` |
| Artifact | `ai-review-summary-*` | `claude-review-summary-*` |

**On the `/v1` asymmetry:** `base_url` is one engine-neutral input. The Kimi CLI
wants a `/v1` suffix; the Anthropic SDK appends `/v1/messages` itself and must not
receive one. Each engine normalises the value it is given, so the same
`base_url` works across engines and flipping `engine` never silently 404s. Do
not "fix" this by giving the dispatch per-engine defaults — that would make one
input value mean two different things.

**A model swap is config; an engine swap is a rewrite.** Any model the LiteLLM
proxy fronts can be reached by setting `model` (and `max_context_size` on Kimi).
Replacing an engine's *CLI* means writing a new composite action, because each
CLI has its own config format, sandbox model, tool names and entrypoint.

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `engine` | `kimi` or `anthropic` | ❌ | `kimi` |
| `model` | Model ID; resolved per engine when empty | ❌ | `""` |
| `base_url` | LLM API endpoint; `/v1` added or stripped per engine | ❌ | `https://litellmsa.deriv.ai/v1` |
| `max_context_size` | **[kimi]** Context window in tokens. Must match the model, or the CLI over-packs and the API rejects the request | ❌ | `1048576` |
| `cli_version` | **[kimi]** Exact `@moonshot-ai/kimi-code` version | ❌ | `0.34.0` |
| `legacy_markers` | Newline-separated markers from superseded workflows to also delete | ❌ | `Claude PR Review Complete` |
| `prompt_gist_url` | Review prompt template | ❌ | DerivFE gist |

Inputs marked **[kimi]** are ignored by other engines.

`cli_version` is pinned deliberately: `@moonshot-ai/kimi-code` is pre-1.0 and
ships minor releases weekly, so `latest` would pull both breaking changes and
unreviewed code into a job holding `LLM_API_KEY` and a write-scoped
`GITHUB_TOKEN`. Bump it by PR. The Anthropic engine's action SHA is pinned the
same way but *inside* the action, because `uses:` accepts no expressions.

## Secrets

| Secret | Description | Required |
|--------|-------------|----------|
| `LLM_API_KEY` | LiteLLM virtual key (or a Kimi Console key with the direct endpoint). The same value serves every engine | ✅ |
| `AGENT_METRICS_API_URL` | Metrics dashboard base URL. Unset = skip POSTing | ❌ |
| `AGENT_METRICS_API_KEY` | Dashboard auth; required when the URL is set | ❌ |

The left-hand side is *this workflow's* parameter name and the right-hand side is
your repo's secret, so migrating from `claude-pr-review.yml` needs no new secret:
`LLM_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}` works as-is, because that value
is already a LiteLLM virtual key.

## Permissions

`actions: write` is currently declared but believed unnecessary — `git blame`
shows it was escalated from `read` alongside an `upload-artifact` change, and
`upload-artifact` authenticates with `ACTIONS_RUNTIME_TOKEN` rather than this
token. It is retained only so no existing consumer breaks mid-migration. When
removing it: **drop it from this workflow first, then from the callers.** The
reverse order fails every run, because a caller granting less than the called
workflow declares is rejected outright.

`id-token: write` also appears unused and is a candidate for the same treatment.

## Comment markers and cleanup

Each run deletes prior review comments before posting, so a PR carries exactly
one. Detection uses a canonical hidden marker, `<!-- deriv-pr-review -->`, which
the **post step appends** — it is not something the model is asked to emit.
Earlier versions depended on the model reproducing a visible header, which meant
one reworded header left a duplicate comment on the PR forever.

`legacy_markers` exists purely for migrations: a run also deletes comments
matching those strings, so a PR that has been through more than one review
workflow does not accumulate one orphan per workflow.

> **When may the `legacy_markers` default be emptied?**
> Only once no open PR anywhere in the org can still carry a
> `Claude PR Review Complete` comment — i.e. every consumer has been migrated
> **and** every PR that was open during the migration has closed. Allow 90 days
> minimum. Emptying it early resurrects duplicate comments on long-lived PRs.

## Metrics

Events go to `${AGENT_METRICS_API_URL}/api/v1/events`, and always to the job
summary regardless of dashboard state:

```json
{
  "agent": "ai_review",
  "event_type": "initial_review | followup_review",
  "timestamp": "…", "pr_number": "…", "repo": "…",
  "payload": { "commit_sha": "…", "review_size_bytes": 0, "model": "k3", "engine": "kimi" }
}
```

`agent` is pinned per engine so migrating a repo onto this workflow keeps feeding
the dashboard series it already had. `payload.engine` is the durable dimension
for telling engines apart — prefer grouping on it over reading `agent`.

## Migrating from `claude-pr-review.yml`

`claude-pr-review.yml` is **deprecated** and now delegates here. It will be
deleted; see the deprecation ledger in the repo README. To migrate a consumer,
edit its caller (three changes — `uses:`, `with:`, and the secret *parameter*
name):

```diff
-    uses: deriv-com/shared-actions/.github/workflows/claude-pr-review.yml@master
+    uses: deriv-com/shared-actions/.github/workflows/ai-pr-review.yml@master
     permissions:
       contents: read
       pull-requests: write
       issues: write
       id-token: write
       actions: write
+    with:
+      engine: anthropic          # explicit — the default is kimi
     secrets:
-      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
+      LLM_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
       AGENT_METRICS_API_URL: ${{ secrets.AGENT_METRICS_API_URL }}
       AGENT_METRICS_API_KEY: ${{ secrets.AGENT_METRICS_API_KEY }}
```

Keep the caller's filename, `name:` and job id — they determine the status-check
name, and changing one can block merges on a repo with branch protection. Do
cosmetic renames separately, after auditing required checks.

Switching that repo to Kimi afterwards is a separate decision: set
`engine: kimi`, drop `max_context_size` if the model's window differs, and expect
review prose to change. Compare quality on real PRs before rolling it out.

## Adding an engine

Exactly three edits:

1. **`.github/actions/ai_review_engine_<name>/action.yml`** — satisfy the engine
   contract (below).
2. **A `case` arm** in `Resolve and validate engine` — the enum plus the engine's
   default model, metrics agent and artifact prefix.
3. **An `if:`-gated step** in the `ENGINE DISPATCH` block. `uses:` accepts no
   expressions, so dispatch cannot be one dynamic step.

### The contract

The workflow guarantees the PR head is checked out, that
`/tmp/review_context.md` and `/tmp/pr_diff.txt` exist and are non-empty, and that
the access gate has passed.

An engine **must** strip PR-supplied agent config as its *first* step, grant the
model no shell tool, read the context and diff, write the review to
`output_path`, and fail with an engine-named message if it wrote nothing. It
**must not** post PR comments, reach the GitHub API on the model's behalf, or
assume it owns checkout, prompt fetch, previous-review handling, context build,
diff fetch, comment posting, metrics or artifacts.

The stripping step is a **security boundary, and its paths are engine-specific**
— `.claude/settings.json` can declare hooks that execute arbitrary commands and
`.kimi-code/mcp.json` can declare MCP servers, neither gated by a tool allowlist,
and both PR-controlled. Never inherit another engine's list; work out what your
CLI reads.

### Gotchas that will bite you

- **`uses:` takes no expressions**, in workflows *or* composite actions. That is
  why dispatch is N gated steps and why the Anthropic action's SHA is literal.
- **A local `./.github/actions/…` path resolves against the *caller's* repo**
  inside a reusable workflow, so engines must be referenced as
  `deriv-com/shared-actions/.github/actions/<name>@master`.
- **Composite refs resolve `@master` even from a PR branch.** To test an engine
  change before merge, temporarily point the dispatch `uses:` at `@<branch>` and
  revert before merging. Merge a *new* engine while nothing references it.
- **`secrets` is unreadable inside a composite action** — pass credentials as
  inputs. `${{ github.token }}` *is* reachable.
- **`timeout-minutes` is invalid on steps inside a composite action.** It lives
  on the dispatch step in the workflow.
- **All steps in a composite action share one log group**, so failures must name
  the engine or they are unattributable.
- **`actionlint` does not validate composite actions**, only `.github/workflows/`.
  Lint action files with `yaml-lint` and review them by hand.

## How It Works

1. **Access gate** — actor must be a `deriv-com` member or a repo collaborator.
2. **Resolve engine** — validate `engine`, resolve per-engine defaults.
3. **Checkout** PR head (depth 20, for the incremental diff).
4. **Fetch prompt** template from the gist; inject the Click2Fix URL.
5. **Capture and delete** prior review comments (canonical + legacy markers,
   paginated), keeping the newest as `PREVIOUS_REVIEW` and extracting its
   `reviewed-commit` SHA.
6. **Collect acknowledged suggestions** from `Click2Fix - Acknowledge` comments.
7. **Build `/tmp/review_context.md`** — instructions, previous review,
   noise-filtered incremental diff, acknowledged items, PR metadata, output format.
8. **Pre-fetch the diff** to `/tmp/pr_diff.txt` with the trusted token, so the
   engine needs no shell.
9. **Dispatch to the engine** — it writes `/tmp/ai_review_output.txt`.
10. **Post** exactly one comment, appending the detection markers.
11. **Emit metrics** to the dashboard and the job summary; upload the payload.
