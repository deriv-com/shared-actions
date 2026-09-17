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
- 🔒 The model gets **no shell tool** and no comment tool, and PR-supplied agent config is stripped before it starts. Only same-repo PRs are reviewed (the job is skipped for forks), the checkout keeps no git credentials on disk (`persist-credentials: false`, and the Anthropic engine runs claude-code-action in the one mode that does not write the token back into `.git/config`, then re-checks the file), and a PR that adds or retargets a symlink is refused before any engine runs
- 🧱 The Kimi and Anthropic engines confine the model's `Read`/`Grep`/`Glob` to the PR checkout and its `Write` to the single output file with a shared, unit-tested **PreToolUse path guard** (match-all, fail-closed, unknown tools denied), and fail the job if a review was produced while the guard never ran
- 🛡️ The post step refuses to publish a review containing the LLM API key, the job's GitHub token, anything shaped like a GitHub token, or the on-disk shapes of git credential plumbing (comment bodies are not covered by Actions secret masking; the failure message names the exact pattern that hit), and truncates bodies over GitHub's 65,536-character comment limit instead of failing
- ✅ Respects `Click2Fix - Acknowledge` comments from the posting bot or accounts with repo standing — acknowledged suggestions are never raised again
- 📊 Emits events to the OneAboveAll metrics dashboard, and always to the job summary
- ⏳ Posts a caller-owned "working on it" comment (model at the top) before the engine runs, then edits that same comment into the review; the CLI never gets a GitHub token
- 🏷️ The reusable job is named after the engine (`Grok PR Review` / `Kimi PR Review` / `Claude PR Review`), or after `review_title` when that input is set. empty title = one slot per engine; set title = concurrent slot on that engine (concurrency, HTML marker, and progress marker include the title)

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
| Tools granted | `Read`, `Write`, `Grep`, `Glob` | `Read`, `Write` (+ Claude Code's permission-free `Grep`/`Glob`; the only GitHub MCP server agent mode mounts here is `github_file_ops`, denied by name and by the guard — see below) | `Read`, `Grep`, `Write`/`Edit` **output dir only** |
| Shell | none (absent from `[tools] enabled`; the deny rule is intent only, and the path guard denies it too) | none (`--allowedTools` omits Bash, `--disallowedTools` re-denies it, the path guard denies it too) | none (`dontAsk` + `--tools` allowlist + `--deny Bash`) |
| `Read` scope | PR checkout minus `.git/`, plus the context/diff/output files (**PreToolUse path guard**) | same guard, same scope (registered via the action's `settings` input) | **unscoped** (`--sandbox read-only` limits writes, not reads) |
| `Write` scope | exactly the output file (path guard) | exactly the output file (path guard) | output directory only (`dontAsk`; Grok deny-wins, so no catch-all deny) |
| GitHub token in the CLI process | none | **yes** — claude-code-action spawns the CLI with `GITHUB_TOKEN`/`GH_TOKEN` in its env for its own MCP servers; the path guard's `/proc` denial and the post-step scan are what stand between that and the PR | none |
| `.git/config` after the run | untouched (`persist-credentials: false`) | untouched: `use_commit_signing: true` keeps the action off the path that rewrites the `origin` URL with the token, its base-branch fetch authenticates from env-only git config, and the file is asserted clean **before** and re-checked **after** | untouched |
| Base-branch config restored | no | **yes** — the action fetches the PR's base branch and restores `.claude/`, `.mcp.json`, `CLAUDE.md`, `.gitmodules`, `.husky`, … from it after the strip step removed the PR's copies (maintainer-merged versions, never the PR's); `.claude/settings.json` from there is still not loaded (`--setting-sources user`) | no |
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

- **The path guard (Kimi and Anthropic)** —
  `.github/actions/ai_review_path_guard/path-guard.js`, one script, unit-tested
  by `path-guard.test.js` in `lint-actions.yml`, registered as a **match-all
  PreToolUse hook** in both engines. `Read`, `Grep` and `Glob` may touch the PR
  checkout minus `.git/`; `Read` may also open the caller's context, diff and
  output files; `Write` may touch exactly the output file; every other tool
  name is denied; `Read`/`Write` without a path are denied; symlinks are
  resolved first. It accepts both CLIs' argument names (`path` for Kimi Code,
  `file_path` for Claude Code's Read/Write) and refuses a call that carries both
  with different values. It is match-all and denies unknown tools on purpose:
  in both CLIs a hook only blocks on exit 2 and a call the matcher does not
  fire for is simply allowed, so a matcher listing four tool names would be
  silently switched off by a CLI bump that renamed one. The guard requires only
  `node:` builtins and reads nothing from the checkout, because both CLIs treat
  a hook that times out or cannot start as allow (hence the `|| exit 2` in both
  hook commands). Every decision is appended to a log outside the checkout, and
  each engine **fails the job if a review was written while that log is empty**
  — a hook that never fired means the plumbing changed and the model ran
  unconfined, and that review is not posted.
- **Kimi** — Bash is absent from `[tools] enabled`, which is what removes it;
  the guard denies it independently. The guard is copied into `$HOME/.kimi-code`
  by the configure step. The `[[permission.rules]]` in the same config are **not
  enforcement**: kimi-code 0.34.0 ignores them in `-p` mode (a bare `deny Read`
  still read files — verified against a mock model while fixing HackerOne
  #4037167). Do not remove the hook because "the rules already cover it"; they
  do not. `kimi doctor config` in the configure step is load-bearing: the CLI's
  config loader drops a section that fails schema validation and carries on,
  so a `[[hooks]]` entry that stopped validating after a version bump would
  silently remove the guard; `doctor` fails on the same condition, before the
  run. No GitHub token reaches the step at all, and the caller's post step
  still scans the review before publishing (see below).
- **Anthropic** — stronger than the action's docs suggest on comment tools,
  weaker than the Kimi engine on tokens, and the engine compensates for both.
  The docs' *"base GitHub tools are always included"* describes **tag mode**;
  passing `prompt:` selects **agent mode**, and the action's source at the
  pinned SHA mounts the `github_comment` MCP server only when `--allowedTools`
  requests its tools, inline comments only when requested, and file-ops only
  with commit signing. Ours requests `Read,Write` and sets `use_commit_signing`
  (see below), so **the only GitHub MCP server mounted is `github_file_ops`**,
  denied by name in `--disallowedTools` and by the path guard — the model holds
  no comment tool and no commit tool, matching the Kimi guarantee. Because that
  rests on source behavior at one SHA, `--disallowedTools` also denies the
  other servers plus Bash/WebFetch/WebSearch, so a future SHA bump that changes
  agent-mode defaults fails safe.
  Two things the action does with the job token, both verified in its source at
  the pinned SHA and both handled: (1) outside commit-signing mode, agent mode
  calls `configureGitAuth`, which runs `git remote set-url origin` with the
  token embedded in the URL — plaintext, in `.git/config`, undoing the caller's
  `persist-credentials: false` and within reach of a `Grep` over the checkout
  (the guard scopes Grep's `path`, not what ripgrep finds under it). The engine
  passes `use_commit_signing: true`, the one prepare branch that skips that
  call. It does **not** remove the `origin` remote — an earlier revision did,
  and that fails the action outright: on every PR event `run.ts` calls
  `restoreConfigFromBase`, which runs `git fetch origin <base> --depth=1` with
  no try/catch and then restores `.claude/`, `.mcp.json`, `CLAUDE.md`,
  `.gitmodules`, `.husky`, … from `origin/<base>` (verified in the source and
  in production logs of deriv-api-v2's GLM and DeepSeek reviews). That fetch
  needs credentials for a private repo, so the engine hands git a credential
  helper through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` in
  the step env — it reads the token the action already placed in its process
  environment, and nothing is written to `.git/config`. The install step asserts
  `.git/config` is credential-free going in and the verify step re-reads it
  **after** the model ran, failing the job if any credential got in. (2) The
  CLI is spawned with the token in its environment (`GITHUB_TOKEN`, `GH_TOKEN`,
  `OVERRIDE_GITHUB_TOKEN`, `DEFAULT_WORKFLOW_TOKEN`) and, with commit signing,
  in its argv (the file-ops server's config), so an unconfined `Read` of
  `/proc/self/environ` or `/proc/self/cmdline` would hand it to the model. The
  path guard is what confines `Read`; it is
  registered through the action's `settings` input (merged into
  `$HOME/.claude/settings.json`, which the SDK loads because `settingSources`
  defaults to user+project+local), with `--setting-sources user` so nothing in
  the checkout is read as settings. `--allowedTools "Read,Write"` itself stays
  unscoped, because path-scoped permission patterns are only documented for
  `Bash` and the workflow this replaced recorded that a scoped `Write(/path)`
  made the tool unavailable entirely; the hook does the scoping instead.

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

Changing either CLI's hook registration (the Kimi `[[hooks]]` block, the
Anthropic `settings` JSON) or the guard's argument contract needs a
verification run: a hook that stops firing is invisible until the
empty-decision-log check fails the job, and a hook that fires but denies
legitimate calls means the engine reviews and writes nothing. Do not "fix"
either blind; the tests cover the guard's decisions, not the CLI's plumbing.

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
as the *agent* is this engine. `review_title` is a replacement label for the
visible Checks name and comment heading. empty title = one slot per engine
(Kimi today). set title = concurrent slot on that engine: concurrency,
the canonical HTML marker, and the progress marker include the title, so
GLM (`review_title: GLM PR Review`) and DeepSeek can share `engine: anthropic`
without cancelling or reaping each other. `METRICS_AGENT` and the artifact
prefix stay per-engine. A title-scoped marker change means open PRs lose
follow-up once for that caller: the next push posts a fresh initial review
and does **not** delete the old bare-marker comment. Remove that leftover
by hand, or leave it until the PR closes. Do not put the bare HTML marker
in `legacy_markers` — that is a substring match on the whole body, so a
review that quotes a caller YAML containing that string would be reaped
(the same trap as listing a visible `Complete` heading). A titled slot is
still the same engine, not a new one.

## Inputs

| Input | Description | Required | Default (resolved when empty) |
|-------|-------------|----------|---------|
| `engine` | `kimi`, `anthropic`, or `grok` | ❌ | `kimi` |
| `review_title` | Visible Checks name and comment heading (` Complete` is appended). Empty keeps the engine default and one slot per engine. Set title = concurrent slot on that engine. Must end in ` PR Review`. Example: `engine: anthropic`, `model: glm-5.3`, `review_title: GLM PR Review` | ❌ | engine name (`Kimi PR Review` / `Claude PR Review` / `Grok PR Review`) |
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
when `review_title` is empty (for example `<!-- deriv-pr-review-grok -->`),
or `<!-- deriv-pr-review-<engine>:<review_title> -->` when it is set (for
example `<!-- deriv-pr-review-anthropic:GLM PR Review -->`). The **post
step appends** it as its own unindented line — it is not something the
model is asked to emit. Capture and reap match that **exact line** in the
last 20 lines of the comment, not a substring anywhere in the body.
Visible titles such as `Grok PR Review Complete` are not markers: a
follow-up that quotes this workflow's YAML would otherwise be deleted by
the other engine. empty title = one slot per engine, so a Kimi run and a
Grok run on the same PR keep both comments. set title = concurrent slot,
so GLM and DeepSeek on `engine: anthropic` keep both comments. Title-scoped
jobs do **not** also match the bare `<!-- deriv-pr-review-<engine> -->` line
or a DeepSeek run would reap GLM. `engine: kimi` and `engine: anthropic`
with an empty title also match the older shared line
`<!-- deriv-pr-review -->` so comments posted before the split stay in
follow-up mode. Grok does **not** match that old tag, or a Grok run would
reap Kimi during a bake-off. Changing a caller from empty title to a set
title changes its marker; open PRs lose follow-up once for that caller.
The old bare-marker comment is never captured and never reaped — it stays
as a duplicate next to the new review until someone deletes it by hand or
the PR closes. The same one-time orphaning applies to a stale progress
comment (`<!-- deriv-pr-review-progress-<engine> -->` left by a pre-change
failed or cancelled run): title-scoped jobs never match that bare progress
marker either, so it also lingers until manual deletion or PR close.
Putting `<!-- deriv-pr-review-<engine> -->` in
`legacy_markers` would substring-match any comment that quotes a workflow
containing that exact line (seen with visible titles on deriv-api-v2#725).
Do not use `legacy_markers` for that cleanup.

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
on the same engine (for example `review_title: GLM PR Review`). set title =
concurrent slot — two anthropic callers with distinct titles keep both
comments. After adopting this, update any required check that still names
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
CLI reads. Both `find` sweeps must match symlinks as well as regular files and
directories (`\( -type f -o -type l \)`, `\( -type d -o -type l \)`): a PR can
add `AGENTS.md` or `.kimi-code` as a link to something else it ships, and a
scrub keyed on `-type f` / `-type d` alone leaves that link in place for the
CLI to follow. `rm` on a link removes the link, never its target. The workflow
additionally rejects PRs that add or modify symlinks before any engine runs, so
this is defence in depth, not the only line. `tests/ai-pr-review-contract.sh`
asserts all of it.

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

0. **Bot and fork skip** — the job does not run at all for `*[bot]` actors (they
   cannot pass the gate, and a red run on every dependabot PR reads like a
   regression) or for PRs whose head repo is not the base repo: callers use
   `pull_request_target`, which runs with the base repo's secrets and a
   write-scoped token even for forks.
1. **Access gate** — actor must be a `deriv-com` member or a repo collaborator.
2. **Resolve engine** — validate `engine`, resolve per-engine and engine-neutral
   defaults (the single place every default value lives).
3. **Progress comment** — the caller (not the engine) posts a Claude-style
   "working on it" comment with the model at the top and a job link. This is
   the comment that later becomes the review (same id). The CLI never
   receives `GITHUB_TOKEN`.
4. **Checkout** the event's `head.sha` — not the branch, which could have moved
   past what the gate validated — at depth 20, for the incremental diff, with
   `persist-credentials: false` so the token is never written under
   `$RUNNER_TEMP` or referenced from `.git/config`. Then **reject symlinks**:
   every symlink in the checked-out tree (`git ls-tree -r -z HEAD`, mode
   `120000` — complete and NUL-safe, no API pagination or 3000-entry cap) is
   looked up in the base tree at the event's `base.sha` by walking the trees
   API one directory at a time; a link that is not there with the same path
   *and* the same blob (i.e. the same target) fails the job before any engine
   runs. Both sides are pinned to the event's SHAs like the checkout is — the
   PR files API was deliberately avoided because it describes the PR's
   *current* head, which can move between the event and this step. A lookup
   failure counts as "new", never as "fine".
5. **Fetch prompt** template from the pinned gist revision; inject the Click2Fix URL.
6. **Capture** the newest prior review comment (canonical + legacy markers,
   paginated) as `PREVIOUS_REVIEW` and extract its `reviewed-commit` SHA.
   Capture only — deletion waits until step 11. Progress comments use a
   different marker and are not captured as reviews. The jq program that
   recognises "our" comments is `REVIEW_MARKER_FILTER`, **job-level env**
   shared with step 11 — not a file under `/tmp`, because the post step runs
   after the engine and a filter an engine could overwrite with `.` would have
   it delete every comment on the PR. Nothing executed or trusted after the
   engine step may come from a path an engine can write.
7. **Collect acknowledged suggestions** from `Click2Fix - Acknowledge` comments
   posted by the bot or by accounts with repo standing (`author_association`),
   so a drive-by comment cannot suppress findings.
8. **Build `/tmp/review_context.md`** — instructions, previous review,
   noise-filtered incremental diff, acknowledged items, PR metadata, review
   procedure, output format.
9. **Pre-fetch the diff** to `/tmp/pr_diff.txt` with the trusted token (so the
   engine needs no shell), filtered for build noise only — lockfiles and
   generated output, never test or doc files, which the review must see.
10. **Dispatch to the engine** — it writes `/tmp/ai_review_output.txt`. Each
    engine verifies its own sandbox before handing the file back (the Kimi and
    Anthropic engines fail if the path guard logged no decisions; the Anthropic
    engine additionally fails if `.git/config` picked up a credential).
11. **Post**: scan the review for the API key, the job's GitHub token, GitHub
    token shapes, and the exact on-disk shapes of git credential plumbing —
    actions/checkout's `includeIf`/`extraheader`/credentials-file/base64 forms
    and the plaintext `x-access-token:<token>@` remote URL claude-code-action
    writes outside commit-signing mode (refuse if found, naming the pattern). Those last patterns are
    anchored to what the tools write — not bare words like `includeIf` — so a
    review that *discusses* git config still posts; the contract test holds
    that line with fixtures on both sides. Then truncate over
    GitHub's comment limit, prepend the model and engine title, append
    detection markers, **PATCH the progress comment** into that body (or
    `gh pr comment` if progress never posted), **then** delete the prior
    review comments (never the comment just patched). On failure, PATCH the
    progress comment to "did not finish".
12. **Emit metrics** to the dashboard and the job summary; upload the payload.
