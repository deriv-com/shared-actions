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
engine is pluggable: pick `kimi`, `anthropic`, or `grok` with one input.

## Features

- 🤖 Full-context review — reads changed files whole, plus their imports, types, callers and tests
- 🔄 Follow-up mode — on re-push, feeds the previous review plus an incremental diff so fixed items are not re-reported
- 🧹 Exactly one review comment per engine per PR — a "working on it" comment is posted first, then **edited** into the finished review (same comment URL). The previous review is deleted only after that edit, so a failed or cancelled run never leaves the PR without its last completed review
- 🔌 Pluggable engine (`kimi` | `anthropic` | `grok`), each a composite action with its own CLI and sandbox
- 🔒 The model gets **no shell tool** and no GitHub token — it cannot comment, and PR-supplied agent config is stripped before it starts
- 🛡️ The post step refuses to publish a review containing the LLM API key (comment bodies are not covered by Actions secret masking), and truncates bodies over GitHub's 65,536-character comment limit instead of failing
- ✅ Respects `Click2Fix - Acknowledge` comments from the posting bot or accounts with repo standing — acknowledged suggestions are never raised again
- 📊 Emits events to the OneAboveAll metrics dashboard, and always to the job summary
- ⏳ Posts a caller-owned "working on it" comment (model at the top) before the engine runs, then edits that same comment into the review; the CLI never gets a GitHub token
- 🏷️ The reusable job is named after the engine (`Grok PR Review` / `Kimi PR Review` / `Claude PR Review`), or after `review_title` when that input is set. `review_title` relabels one engine+model; it does not make two same-engine callers concurrent

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
      engine: kimi          # or: anthropic | grok
      # Optional. Empty keeps the engine default heading ("Kimi PR Review").
      # review_title: GLM PR Review
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

| | `kimi` | `anthropic` | `grok` |
|---|---|---|---|
| Runtime | `@moonshot-ai/kimi-code` CLI (npm, pinned) | `anthropics/claude-code-action` (pinned by SHA) | `@xai-official/grok` CLI — Grok Build (npm, pinned) |
| Default model | `kimi-k3` | `claude-sonnet-5` | `grok-4.6` |
| `base_url` sent | proxy origin **+ `/v1`** | proxy origin, **`/v1` stripped** | proxy origin **+ `/v1`** |
| Tools granted | `Read`, `Write`, `Grep`, `Glob` | `Read`, `Write` (agent mode mounts **no** GitHub MCP servers — see below) | `Read`, `Grep`, `Write`/`Edit` **output dir only** |
| Shell | none (absent from `enabled` **and** denied by rule) | none (`--allowedTools` omits Bash, `--disallowedTools` re-denies it) | none (`dontAsk` + `--tools` allowlist + `--deny Bash`) |
| `Write` scope | output directory only (allow + catch-all deny) | **unscoped** — see below | output directory only (`dontAsk`; Grok deny-wins, so no catch-all deny) |
| Config stripped | `CLAUDE.md`, `AGENTS.md`, `KIMI.md`, `.kimi-code/` | `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.mcp.json`, `.claude/`, `.claude-plugin/` | Case-insensitive `AGENTS.md` / `AGENT.md` / `CLAUDE.md` / `CLAUDE.local.md` / `KIMI.md` / `.mcp.json` / `.cursorrules`; dirs `.grok/`, `.claude/`, `.claude-plugin/`, `.agents/`, `.cursor/rules/` |
| Applicable inputs | all, incl. `max_context_size`, `cli_version`, `provider_type` | all except `max_context_size`, `cli_version`, `provider_type` | all except `provider_type` |
| `agent` reported | `ai_review` | `claude_review` | `grok_review` |
| Artifact | `ai-review-summary-*` | `claude-review-summary-*` | `grok-review-summary-*` |

**`provider_type` must match what `base_url` serves.** This is the Kimi engine's
sharpest trap, because a mismatch produces a bare `400 The request was invalid`
that names nothing:

| `base_url` | correct `provider_type` |
|---|---|
| `https://litellmsa.deriv.ai/v1` (LiteLLM proxy — the default) | `openai` |
| `https://api.kimi.com/coding/v1` (direct Kimi Code platform) | `kimi` |

The `kimi` dialect is built for the Kimi Code platform and a LiteLLM proxy
rejects it, even when the model name and key are correct — verified by sending
the same model and key as a plain `/v1/chat/completions` request, which
succeeds. **Change these two inputs together, never one alone.** Valid types:
`kimi`, `anthropic`, `openai`, `openai_responses`, `google-genai`, `vertexai`.

**Model names belong to the endpoint, not the model.** `model` is passed through
verbatim, so it must be whatever the thing in `base_url` calls it. On the Deriv
LiteLLM proxy K3 is `kimi-k3`; the Kimi-platform ids (`k3`, `k3-256k`,
`kimi-for-coding`) resolve only against `api.kimi.com/coding/v1` and return a
bare `400 The request was invalid` from the proxy. List what a proxy accepts:

```bash
curl -s https://litellmsa.deriv.ai/v1/models \
  -H "Authorization: Bearer $LLM_API_KEY" | jq -r '.data[].id' | sort
```

If a 400 survives fixing the model name, suspect `max_context_size` exceeding
the window the endpoint allows for that alias.

**On the `/v1` asymmetry:** `base_url` is one engine-neutral input. The Kimi CLI
wants a `/v1` suffix; the Anthropic SDK appends `/v1/messages` itself and must not
receive one. Each engine normalises the value it is given, so the same
`base_url` works across engines and flipping `engine` never silently 404s. Do
not "fix" this by giving the dispatch per-engine defaults — that would make one
input value mean two different things.

**How each engine's sandbox actually holds.** Be precise about this rather than
assuming parity:

- **Kimi** — the tool surface *is* the guarantee. Bash is absent from `enabled`
  and denied by rule; `Write` is confined to the output directory by an allow rule
  plus a catch-all deny; no GitHub token reaches the step at all. The agent
  cannot comment because it has no means to. Its `Read` is unscoped, though —
  which is why the caller's post step scans the review for the API key before
  publishing (see below).
- **Anthropic** — stronger than the action's docs suggest. The docs' *"base
  GitHub tools are always included"* describes **tag mode**; passing `prompt:`
  selects **agent mode**, and the action's source at the pinned SHA mounts the
  `github_comment` MCP server only when `--allowedTools` requests its tools,
  file-ops only with commit signing, inline comments only when requested. Ours
  requests `Read,Write`, so **no GitHub MCP server is mounted at all** — the
  model holds no comment tool, matching the Kimi guarantee. Because that rests
  on source behavior at one SHA, the engine also passes `--disallowedTools`
  denying those servers plus Bash/WebFetch/WebSearch, so a future SHA bump that
  changes agent-mode defaults fails safe. `Write` is unscoped, because
  path-scoped patterns are only documented for `Bash`, and the workflow this
  replaced recorded that a scoped `Write(/path)` made the tool unavailable
  entirely. The action does hold a token for its own actor checks.

- **Grok** — permissions (`dontAsk`) plus `--tools Read,Grep,Write,Edit` are the
  guarantee; `--sandbox read-only` is extra (cannot write the checkout; temp
  and `$GROK_HOME` stay writable). Bash, WebFetch and WebSearch are denied and
  removed. `--always-approve` is never passed. Grok's **deny-wins** (`deny`
  always wins over `allow`: https://docs.x.ai/build/features/permissions;
  evaluation order deny > ask > allow:
  https://docs.x.ai/build/settings/reference), so there is no catch-all deny
  for Write/Edit — that would block the scoped output-dir allow. Unlisted
  tools are denied by `dontAsk`. No GitHub token reaches the
  step. `output_path` must be under temp or the engine fails closed rather than
  loosening the sandbox. `GROK_HOME` is `/tmp/grok-engine-home` and is wiped
  *before* `npm install` so leftover runner state cannot survive, without
  deleting the binary postinstall just wrote.

Tightening the Anthropic `Write` grant (or scoping the Kimi `Read`) needs a
verification run, since a pattern the CLI reads as "tool unavailable" means the
engine reviews and writes nothing. Do not "fix" either blind.

**Post-step guards, engine-neutral:** whatever the engine, the caller refuses to
post a review containing the `LLM_API_KEY` value (Actions masks secrets in logs,
**not** in comment bodies — and the model's input is attacker-influenced PR
content), and truncates bodies over GitHub's 65,536-character comment limit
(full text preserved in the job log) instead of failing the run.

**A model swap is config; an engine swap is a rewrite.** Any model the LiteLLM
proxy fronts can be reached by setting `model` (and `max_context_size` on Kimi
or Grok). Replacing an engine's *CLI* means writing a new composite action,
because each CLI has its own config format, sandbox model, tool names and
entrypoint. Grok 4.6 as a *model* on the Kimi CLI is a model swap; Grok Build
as the *agent* is this engine. `review_title` is a replacement label for a
repo that has already chosen one engine+model (for example GLM on
`engine: anthropic`). It does not make two same-engine callers coexist:
hidden HTML markers and `METRICS_AGENT` stay per-engine, and the
`concurrency` group is keyed only by `engine`, so a second anthropic run
(Claude + GLM) cancels the first (`cancel-in-progress: true`) and would
reap the same comment. Run one anthropic caller per repo, or add a real
engine if you need a bake-off.

## Inputs

| Input | Description | Required | Default (resolved when empty) |
|-------|-------------|----------|---------|
| `engine` | `kimi`, `anthropic`, or `grok` | ❌ | `kimi` |
| `review_title` | Visible Checks name and comment heading (` Complete` is appended). Empty keeps the engine default. Must end in ` PR Review`. Replacement label, not a second concurrent engine. Example: `engine: anthropic`, `model: glm-5.3`, `review_title: GLM PR Review` | ❌ | engine name (`Kimi PR Review` / `Claude PR Review` / `Grok PR Review`) |
| `model` | Model ID; resolved per engine when empty | ❌ | per engine |
| `base_url` | LLM API endpoint; `/v1` added or stripped per engine | ❌ | `https://litellmsa.deriv.ai/v1` |
| `max_context_size` | **[kimi, grok]** Context window in tokens. Must match the model, or the CLI over-packs and the API rejects the request | ❌ | per engine (`1048576` kimi, `500000` grok) |
| `cli_version` | **[kimi, grok]** Exact CLI version (`@moonshot-ai/kimi-code` or `@xai-official/grok`) | ❌ | per engine (`0.34.0` kimi, `1.0.5` grok) |
| `provider_type` | **[kimi]** Wire dialect; must match what `base_url` serves | ❌ | `openai` |
| `legacy_markers` | Newline-separated markers from superseded workflows to also delete | ❌ | `Claude PR Review Complete` |
| `prompt_gist_url` | Review prompt template | ❌ | DerivFE gist, **pinned to a revision** |

An invalid `review_title` still renders verbatim in the Check name at
workflow-parse time; the run then fails in "Resolve and validate engine".
The job name is not authoritative until the run succeeds.

Inputs marked **[kimi]** / **[kimi, grok]** are ignored by engines that do not
use them. Every input except
`engine` and `legacy_markers` declares `default: ""` and is resolved to the
values above inside the `Resolve and validate engine` step — so each default
exists in exactly one place, and that step is where you bump any of them.

The gist default is pinned to a specific revision on purpose: the bare `raw/`
URL is mutable, and a gist edit would rewrite the review agent's instructions
for every consumer live, with no PR and no audit trail. To roll out a new
prompt, edit the gist, then bump the revision hash in the resolve step via PR.

`cli_version` is pinned deliberately: both `@moonshot-ai/kimi-code` and
`@xai-official/grok` ship frequently, so `latest` would pull both breaking
changes and unreviewed code into a job holding `LLM_API_KEY` and a write-scoped
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

This workflow does **not** request `actions:` at all. `claude-pr-review.yml`
granted `actions: write`, but `git blame` shows it was escalated from `read`
alongside an `upload-artifact` change, and `upload-artifact` authenticates with
`ACTIONS_RUNTIME_TOKEN` rather than this token. Neither engine calls the Actions
API.

Callers may keep granting it harmlessly: **permissions can only be reduced, never
elevated, down a reusable-workflow chain**, so declaring less than a caller grants
always works. The reverse does not — a called workflow requesting *more* than its
caller granted fails the run outright. That asymmetry is why the caller stubs in
the migration guide keep their existing `permissions` block unchanged.

`id-token: write` also appears unused by both engines and is a candidate for the
same trim, pending a check that the self-hosted runner group does not rely on it.

## Known limitations

**Engine actions are referenced at `@master`, not a pinned SHA.** Every other
third-party ref in this workflow is SHA-pinned, so this is a deliberate
exception, for two reasons: a SHA cannot be referenced before the commit that
introduces it exists, and pinning would make every engine change a two-commit
dance (change, then re-pin). It also matches house style — `docsync-ai.yml` does
the same for its composite actions.

The consequence worth knowing: a consumer pinning `ai-pr-review.yml` to a tag or
SHA does **not** pin the engine code that actually executes. Given how privileged
this job is, pinning the engine refs — across this repo's self-referencing
composite actions consistently, not just here — is a reasonable follow-up.

## Comment markers and cleanup

Each run **edits** the progress comment into the finished review (same
comment id and URL), then deletes prior review comments. The reap-list is
captured just before that edit and **excludes** the comment being patched, so
the replacement cannot match its own filter. A run that fails at any point
leaves the last completed review untouched and PATCHes the progress comment
to "did not finish". The worst case is a transient duplicate (progress plus
the previous review), which the next run reaps. (Deletion used to happen at
the start of the run, which meant every engine failure or cancel-in-progress
in the up-to-an-hour gap destroyed the previous review and its reviewed-commit
SHA.)
Detection uses a canonical hidden marker, `<!-- deriv-pr-review-<engine> -->`
(for example `<!-- deriv-pr-review-grok -->`), which the **post step appends**
as its own unindented line — it is not something the model is asked to emit.
Capture and reap match that **exact line** in the last 20 lines of the
comment, not a substring anywhere in the body. Visible titles such as
`Grok PR Review Complete` are not markers: a follow-up that quotes this
workflow's YAML would otherwise be deleted by the other engine. The marker
is per-engine so a Kimi run and a Grok run on the same PR keep both
comments. `engine: kimi` and `engine: anthropic` also match the older
shared line `<!-- deriv-pr-review -->` so comments posted before the
split stay in follow-up mode. Grok does **not** match that old tag, or a
Grok run would reap Kimi during a bake-off.

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
  "payload": { "commit_sha": "…", "review_size_bytes": 0, "model": "kimi-k3", "engine": "kimi" }
}
```

`agent` is pinned per engine so migrating a repo onto this workflow keeps feeding
the dashboard series it already had. `payload.engine` is the durable dimension
for telling engines apart — prefer grouping on it over reading `agent`.

## Migrating from `claude-pr-review.yml`

`claude-pr-review.yml` is **deprecated**. It is still its own standalone
implementation for now — converting it into a thin shim that delegates here is a
tracked follow-up, after which it will be deleted. See the deprecation ledger in
the repo README. To migrate a consumer, edit its caller (three changes —
`uses:`, `with:`, and the secret *parameter* name):

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

Keep the caller's filename, `name:` and job id — they determine the left
half of the status-check name (`{caller job} / {reusable job}`), and
changing one can block merges on a repo with branch protection. The
reusable job is named after `engine` (`Kimi PR Review`, `Grok PR Review`,
`Claude PR Review`) so two *engines* on one PR are distinguishable in
Checks. Override that heading with `review_title` when replacing the model
on the same engine (for example `review_title: GLM PR Review`) — that is
not a second concurrent anthropic job. After adopting this, update any required check that still names
`ai-review / ai-review`. Do other cosmetic renames separately.

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
**must not** harvest or invent cost/usage for the PR comment (the caller does
not publish a usage footer). It **must not** post PR comments, reach the GitHub
API on the model's behalf, or assume it owns checkout, prompt fetch,
previous-review handling, context build, diff fetch, comment posting, metrics
or artifacts.

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

0. **Bot skip** — the job does not run at all for `*[bot]` actors (they cannot
   pass the gate, and a red run on every dependabot PR reads like a regression).
1. **Access gate** — actor must be a `deriv-com` member or a repo collaborator.
2. **Resolve engine** — validate `engine`, resolve per-engine and engine-neutral
   defaults (the single place every default value lives).
3. **Progress comment** — the caller (not the engine) posts a Claude-style
   "working on it" comment with the model at the top and a job link. This is
   the comment that later becomes the review (same id). The CLI never
   receives `GITHUB_TOKEN`.
4. **Checkout** the event's `head.sha` — not the branch, which could have moved
   past what the gate validated — at depth 20, for the incremental diff.
5. **Fetch prompt** template from the pinned gist revision; inject the Click2Fix URL.
6. **Capture** the newest prior review comment (canonical + legacy markers,
   paginated) as `PREVIOUS_REVIEW` and extract its `reviewed-commit` SHA.
   Capture only — deletion waits until step 11. Progress comments use a
   different marker and are not captured as reviews.
7. **Collect acknowledged suggestions** from `Click2Fix - Acknowledge` comments
   posted by the bot or by accounts with repo standing (`author_association`),
   so a drive-by comment cannot suppress findings.
8. **Build `/tmp/review_context.md`** — instructions, previous review,
   noise-filtered incremental diff, acknowledged items, PR metadata, review
   procedure, output format.
9. **Pre-fetch the diff** to `/tmp/pr_diff.txt` with the trusted token (so the
   engine needs no shell), filtered for build noise only — lockfiles and
   generated output, never test or doc files, which the review must see.
10. **Dispatch to the engine** — it writes `/tmp/ai_review_output.txt`.
11. **Post**: scan the review for the API key (refuse if found), truncate over
    GitHub's comment limit, prepend the model and engine title, append
    detection markers, **PATCH the progress comment** into that body (or
    `gh pr comment` if progress never posted), **then** delete the prior
    review comments (never the comment just patched). On failure, PATCH the
    progress comment to "did not finish".
12. **Emit metrics** to the dashboard and the job summary; upload the payload.
