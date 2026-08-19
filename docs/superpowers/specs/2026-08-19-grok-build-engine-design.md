# Grok Build engine for AI PR review

Date: 2026-08-19  
Status: approved  
Repo: `deriv-com/shared-actions`

## Goal

Add `engine: grok` to the reusable AI PR review workflow. The engine runs **Grok Build** (xAI’s coding CLI), talks to Deriv’s LiteLLM proxy as `grok-4.6`, and satisfies the same engine contract as `kimi` and `anthropic`.

This is an engine swap (new CLI), not a model swap on the Kimi CLI.

## Non-goals

- Do not vendor Grok Build source into this repo.
- Do not wrap `ai_review_engine_kimi` and label it `grok`.
- Do not switch this repo’s dogfood caller (`ai-review.yml`) off `kimi` / `kimi-k3`.
- Do not call `api.x.ai` directly; inference stays on LiteLLM.
- Do not enable Grok Build features the review sandbox forbids: shell, web search, web fetch, MCP, subagents, plan mode, `--always-approve` / `--yolo`.
- Do not install via `curl | bash` (`https://x.ai/cli/install.sh`).

## Background

Ako’s rule, from `.github/workflows/AI_PR_REVIEW_README.md`:

> A model swap is config; an engine swap is a rewrite. Replacing an engine’s *CLI* means writing a new composite action, because each CLI has its own config format, sandbox model, tool names and entrypoint.

| Engine | CLI | Default LiteLLM model |
|---|---|---|
| `kimi` | `@moonshot-ai/kimi-code` | `kimi-k3` |
| `anthropic` | `anthropics/claude-code-action` | `claude-sonnet-5` |
| `grok` (this spec) | `@xai-official/grok` (Grok Build) | `grok-4.6` |

Official product page: https://x.ai/build  
Official docs: https://docs.x.ai/build/overview  
Grok 4.6 now powers Grok Build. Headless CI is `grok -p`. Custom OpenAI-compatible `base_url` is supported. Code-review sandbox profile is `read-only`.

## Architecture

```
caller
  → ai-pr-review.yml   (engine: grok; scaffolding unchanged)
  → ai_review_engine_grok
  → grok -p            (pinned @xai-official/grok)
  → LiteLLM            https://litellmsa.deriv.ai/v1  model grok-4.6
```

The workflow still owns: access gate, checkout, prompt fetch, previous-review capture, context build, diff pre-fetch, comment posting, metrics, artifacts.

The Grok engine owns: stripping PR-supplied agent config, installing and configuring Grok Build, sandbox/tool restrictions, writing `/tmp/ai_review_output.txt`. It must not post PR comments or receive `GITHUB_TOKEN`.

Engines are referenced as `deriv-com/shared-actions/.github/actions/<name>@master`. A relative `./.github/actions/…` path inside the reusable workflow resolves against the **consumer** repo and would break every caller.

## Components

### 1. `.github/actions/ai_review_engine_grok/action.yml`

New composite action. Same public contract as the Kimi engine:

| Input | Required | Default |
|---|---|---|
| `review_context_path` | no | `/tmp/review_context.md` |
| `pr_diff_path` | no | `/tmp/pr_diff.txt` |
| `output_path` | no | `/tmp/ai_review_output.txt` |
| `repository` | yes | — |
| `pr_number` | yes | — |
| `model` | no | `grok-4.6` |
| `base_url` | no | `https://litellmsa.deriv.ai/v1` |
| `api_key` | yes | — |
| `max_context_size` | no | `500000` |
| `cli_version` | no | `1.0.5` (non-alpha `@xai-official/grok` as of 2026-08-19; re-check at implement, never use `alpha`) |
| `node_version` | no | `22` |

Output: `output_path`.

There is no `provider_type` input. Grok Build’s wire dialect is `api_backend` in `config.toml`, default `chat_completions` (what LiteLLM advertised for grok-4.6). If the first verification run 400s, switch that one field to `responses` — do not invent a second caller-facing input until that is proven necessary.

### 2. Resolve-and-validate `case` arm

In `.github/workflows/ai-pr-review.yml`:

```
grok)
  DEFAULT_MODEL="grok-4.6"
  METRICS_AGENT="grok_review"
  ARTIFACT_PREFIX="grok-review"
  DEFAULT_MAX_CONTEXT="500000"
  ;;
```

`kimi` keeps `DEFAULT_MAX_CONTEXT="1048576"`. `MAX_CONTEXT` becomes `${MAX_CONTEXT_INPUT:-$DEFAULT_MAX_CONTEXT}` so the 500k window is not inherited from the current engine-neutral 1M default (which would over-pack grok-4.6).

Unknown-engine error text must list `kimi, anthropic, grok`.

Inputs currently tagged `[kimi]` that Grok also uses (`max_context_size`, `cli_version`) are retagged `[kimi, grok]` in the workflow description and README. `provider_type` stays Kimi-only.

### 3. Dispatch step

`if: steps.engine.outputs.engine == 'grok'`, `timeout-minutes: 60`, `uses: deriv-com/shared-actions/.github/actions/ai_review_engine_grok@master`, passing the same contract fields as the Kimi dispatch except `provider_type`.

### 4. Docs

Update `.github/workflows/AI_PR_REVIEW_README.md` (engines table, adding-an-engine examples, `provider_type` note stays Kimi-only) and the reusable-workflow row in `README.md`.

## Install

- Package: `@xai-official/grok`
- Pin at implementation time to the then-current **non-alpha** `latest` (today: `1.0.5`; `alpha` tag `1.0.6` is not used).
- Install: `npm install -g "@xai-official/grok@${CLI_VERSION}"` after `actions/setup-node` pinned to the same SHA Kimi uses.
- Forbidden: `curl -fsSL https://x.ai/cli/install.sh | bash`, `@latest`, unpinned dist-tags.
- Bump `cli_version` by PR, same governance as Kimi’s `0.34.0`.

## LiteLLM configuration

Recreate `$HOME/.grok` every run (persistent self-hosted runners). Do not merge with leftover config. Never write `api_key` into the toml.

The run step sets `XAI_API_KEY` from the `api_key` input (the workflow’s `LLM_API_KEY` secret). Config uses `env_key` only. The toml block is a fixed alias `review`; the LiteLLM id and window come from inputs so a caller can override them without renaming the block:

```toml
[model.review]
model = "<inputs.model>"
base_url = "<normalised base_url>"
env_key = "XAI_API_KEY"
api_backend = "chat_completions"
context_window = <inputs.max_context_size>

[models]
default = "review"
```

`base_url` is normalised like Kimi: accept with or without a trailing `/v1`; append `/v1` when absent. The Anthropic engine continues to strip `/v1`. One caller-facing `base_url` still works for every engine.

Resolved defaults: `model=grok-4.6`, `max_context_size=500000`.

`500000` is grok-4.6’s advertised **input** window. LiteLLM also quotes 1.0M total / 500k output. Using 1M as `max_context_size` is rejected: the Kimi engine already documented that over-packing yields a bare 400.

After writing config, run `grok inspect` so a bad discovery (MCP, skills, leftover instructions) is visible in the job log before the review starts.

Disable auto-update: `GROK_DISABLE_AUTOUPDATER=1` and/or `grok --no-auto-update`. Disable telemetry if Grok Build has an equivalent flag; if not, do not invent one.

## Sandbox

Permissions are the guarantee. Grok’s OS sandbox is defense in depth.

**Forbidden:** `--always-approve`, `--yolo`, `--dangerously-skip-permissions`, `permission_mode = "always-approve"`.

**Required headless mode:** `--permission-mode dontAsk` (anything not explicitly allowed is denied).

**Allowed tools:** `Read`, `Grep`, and Grok’s edit/write tool **only** for the output directory (`dirname(output_path)`, default `/tmp`). Exact tool names (`Edit` vs `Write`, whether `Glob` exists) are confirmed against `grok --help` at implementation; the intent is non-negotiable: the model may read the checkout and write the review file, nothing else.

**Denied tools:** `Bash`, `WebFetch`, `WebSearch`, `MCPTool`. Also pass `--disable-web-search --no-subagents --no-plan --no-auto-update` and `--disallowed-tools` for the same surface so a config miss still fails closed.

**OS sandbox:** `--sandbox read-only` (xAI: “Code review, auditing”). That profile allows writes to `~/.grok/` and temp, not the checkout. Default `output_path` is `/tmp/ai_review_output.txt` (temp → writable). If a caller sets `output_path` under the workspace, the engine must fail with a Grok-named error rather than silently skip the Write. Do not “fix” this by switching to `--sandbox off`.

No `GITHUB_TOKEN` in the run step env.

## Strip list

Security boundary, **Grok-specific**. Do not copy Kimi’s or Anthropic’s list. Grok Build auto-loads Claude Code and Cursor instruction files.

Recursive from the checkout, prune `.git`:

**Files:** `AGENTS.md`, `Agents.md`, `AGENT.md`, `CLAUDE.md`, `Claude.md`, `CLAUDE.local.md`, `KIMI.md`, `.mcp.json`

**Directories:** `.grok`, `.claude`, `.claude-plugin`, `.agents`, and `.cursor/rules` (Grok reads `*.md` there). Do not delete the whole `.cursor` tree; only `rules/`.

**Home (persistent runner):** delete `$HOME/.grok`, `$HOME/.agents`, and leftover `$HOME/.claude` before writing our config.

## Prompt and salvage

Bootstrap prompt matches Kimi’s (engine-neutral procedure lives in the caller-built context file):

- Read `review_context_path` and follow it exactly.
- No shell; diff is on disk at `pr_diff_path`.
- Chat reply is discarded. The only deliverable is `output_path` written with the edit/write tool.

Operational behaviour copied from the Kimi engine (proven on this workflow, not Grok-specific folklore):

1. Delete any leftover file at `output_path` first (persistent runner).
2. Read the prompt file once, outside the loop.
3. Run `grok -p` up to twice.
4. A non-empty review file outranks a non-zero CLI exit (keep the file, log a warning, dump diagnostics).
5. Retry only when the file is still empty.
6. If still empty after two attempts, fail with `❌ Grok engine: …` and dump logs.

Dump Grok’s own logs on failure (search `$HOME/.grok` and `/tmp` for recent logs). Print resolved `model`, `base_url`, `api_backend`, `max_context_size`, and input byte sizes. Never print `api_key`.

All failure messages must start with `Grok engine` because composite-action steps share one log group.

## Data flow

1. Access gate, checkout PR head, fetch prompt gist, capture previous review, build context, pre-fetch diff. Unchanged.
2. Resolve `engine=grok` and per-engine defaults.
3. Grok engine: strip → setup-node → install CLI → wipe home → write config → `grok inspect` → `grok -p` (retry/salvage).
4. Caller posts the file, appends `<!-- deriv-pr-review -->`, refuses bodies containing `LLM_API_KEY`, truncates over 65,536 characters, emits metrics, uploads `grok-review-summary-${{ github.run_id }}`.

## Error handling

| Case | Behaviour |
|---|---|
| Missing/empty context or diff | Fail immediately, named |
| CLI non-zero after non-empty review file | Keep file, warn, continue |
| Empty file after attempt 1 | Dump logs, retry once |
| Empty after two attempts | Fail, dump logs |
| LiteLLM 400 on the first request | Treat as config: `api_backend` or `max_context_size`, documented in README |
| `output_path` would not be writable under `read-only` (not temp / `~/.grok`) | Fail named; do not loosen the sandbox |

The caller’s existing post-step guards stay engine-neutral.

## Testing and rollout

- `lint-actions.yml` already globs `.github/actions/*/action.yml`; no new lint job. The new file must pass YAML validity, no empty `${{ }}`, no inner `timeout-minutes`, no `secrets.` references (including comments).
- Merge the engine while **no consumer is required to use it**. Do not change `.github/workflows/ai-review.yml`.
- Pre-merge verification: temporarily point the new dispatch `uses:` at `@<branch>` on one test PR, then revert to `@master` before merging (existing house caveat: composite refs on a PR still pull `@master` otherwise).
- Confirm on that test run: `grok inspect` shows no project AGENTS/MCP/skills; review file is posted; no Bash/Web/MCP tool calls; LiteLLM accepts `chat_completions` for `grok-4.6`.
- Consumers opt in with:

```yaml
with:
  engine: grok
```

`model`, `base_url`, and `max_context_size` may be omitted (defaults above). `LLM_API_KEY` stays the existing LiteLLM virtual key; the key must be authorised for `grok-4.6` on `litellmsa.deriv.ai`.

## Files touched

| Path | Change |
|---|---|
| `.github/actions/ai_review_engine_grok/action.yml` | create |
| `.github/workflows/ai-pr-review.yml` | `case` arm, per-engine `max_context_size` default, dispatch step, input descriptions |
| `.github/workflows/AI_PR_REVIEW_README.md` | engines table, usage, adding-an-engine |
| `README.md` | engine enum in the reusable-workflow row |

No changes to `ai_review_engine_kimi`, `ai_review_engine_anthropic`, or `ai-review.yml`.
