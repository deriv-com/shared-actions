# Grok Build Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `engine: grok` so AI PR review runs Grok Build (`@xai-official/grok@1.0.5`) against LiteLLM `grok-4.6`.

**Architecture:** First-class composite action `ai_review_engine_grok` (peer of kimi/anthropic), wired through the existing resolve `case` + if-gated dispatch. Same scaffolding; Grok-specific strip list, sandbox, and LiteLLM `config.toml`. Does not wrap the Kimi engine. Does not change dogfood (`ai-review.yml`).

**Tech Stack:** GitHub Actions composite actions, Grok Build CLI 1.0.5, LiteLLM (`https://litellmsa.deriv.ai/v1`).

## Global Constraints

- Engine = Grok Build CLI, not a Kimi wrapper and not a model-only swap.
- Pin `@xai-official/grok@1.0.5` (non-alpha). Never `curl | bash`, never `@latest`.
- Inference: LiteLLM `litellmsa.deriv.ai/v1`, model `grok-4.6`, `api_backend = chat_completions`, `context_window = 500000`. Never `api.x.ai`. Never write `api_key` into toml (`env_key = "XAI_API_KEY"`).
- No `--always-approve` / `--yolo` / `bypassPermissions`. Use `--permission-mode dontAsk`.
- Tools: Read/Grep/Glob plus Write/Edit **only** in the output dir. Deny Bash, WebFetch, WebSearch, MCP. `--sandbox read-only`. `--disable-web-search --no-subagents --no-plan`.
- Grok deny-wins: do **not** add a catch-all deny for Write/Edit (that would block the scoped allow). `dontAsk` is the catch-all.
- `GROK_HOME=/tmp/grok-engine-home`. Wipe **before** `npm install` (postinstall writes `$GROK_HOME/bin`). Do not wipe after install.
- `output_path` must be under temp (`/tmp` or `/var/tmp`) so read-only sandbox can write it.
- Per-engine defaults in the resolve `case`: grok `DEFAULT_MAX_CONTEXT=500000`, `DEFAULT_CLI_VERSION=1.0.5`; kimi keeps `1048576` / `0.34.0`.
- Composite lint: no empty `${{ }}`, no inner `timeout-minutes`, no `secrets.` (including comments). Failures named `Grok engine`.
- Do not edit `ai_review_engine_kimi`, `ai_review_engine_anthropic`, or `ai-review.yml`.
- Dispatch `uses:` stays `@master` (merge a new engine while nothing is required to call it).

---

## File structure

| File | Role |
|---|---|
| `.github/actions/ai_review_engine_grok/action.yml` | Grok Build engine (strip, install, sandbox, `grok -p`, salvage) |
| `.github/workflows/ai-pr-review.yml` | Enum, per-engine defaults, dispatch step |
| `.github/workflows/AI_PR_REVIEW_README.md` | Engines table + usage |
| `README.md` | Engine enum on the reusable-workflow row |

---

### Task 1: Grok engine composite action

**Files:**
- Create: `.github/actions/ai_review_engine_grok/action.yml`

**Interfaces:**
- Consumes: engine contract inputs (`review_context_path`, `pr_diff_path`, `output_path`, `repository`, `pr_number`, `model`, `base_url`, `api_key`, `max_context_size`, `cli_version`, `node_version`)
- Produces: `outputs.output_path`; writes the review file; no GitHub token

- [ ] **Step 1: Write failing lint check (file missing)**

Run from repo root:

```bash
test -f .github/actions/ai_review_engine_grok/action.yml
```

Expected: FAIL (`test` exit 1).

- [ ] **Step 2: Create `action.yml`** implementing the spec (full file in the working tree). Must include: Grok-specific recursive strip; setup-node SHA `49933ea5288caeca8642d1e84afbd3f7d6820020`; `GROK_HOME=/tmp/grok-engine-home` wipe-then-install `@xai-official/grok@${CLI_VERSION}`; `config.toml` alias `[model.review]` with `env_key`, `chat_completions`; `grok inspect`; `grok -p` with dontAsk + read-only + tool allowlist; Kimi salvage/retry; named errors.

- [ ] **Step 3: Composite lint on the new file**

```bash
python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' .github/actions/ai_review_engine_grok/action.yml
! grep -nE '\$\{\{[[:space:]]*\}\}' .github/actions/ai_review_engine_grok/action.yml
! grep -nE '^[[:space:]]*timeout-minutes:' .github/actions/ai_review_engine_grok/action.yml
! grep -nE '\bsecrets\.[A-Za-z_]' .github/actions/ai_review_engine_grok/action.yml
```

Expected: YAML loads; the three greps match nothing.

- [ ] **Step 4: Commit**

```bash
git add .github/actions/ai_review_engine_grok/action.yml
git commit -m "feat: add Grok Build AI PR review engine"
```

### Task 2: Workflow enum + dispatch

**Files:**
- Modify: `.github/workflows/ai-pr-review.yml`

**Interfaces:**
- Consumes: `ai_review_engine_grok` contract
- Produces: `engine=grok` resolve outputs (`model=grok-4.6`, `max_context_size=500000`, `cli_version=1.0.5`, `artifact_prefix=grok-review`, `METRICS_AGENT=grok_review`) and a gated dispatch step

- [ ] **Step 1: Confirm grok is rejected today**

```bash
rg -n "Supported values for the .engine. input" .github/workflows/ai-pr-review.yml
```

Expected: line lists only `kimi, anthropic`.

- [ ] **Step 2: Patch inputs, `case` arm (including per-engine `DEFAULT_MAX_CONTEXT` / `DEFAULT_CLI_VERSION`), unknown-engine message, and dispatch step `id: engine-grok`.** Pass the same fields as Kimi except `provider_type`. `timeout-minutes: 60`. `uses: deriv-com/shared-actions/.github/actions/ai_review_engine_grok@master`.

- [ ] **Step 3: Verify enum + dispatch stay paired**

```bash
rg -n "engine == 'grok'|grok\\)" .github/workflows/ai-pr-review.yml
```

Expected: `case` arm and `if:` gate both present.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ai-pr-review.yml
git commit -m "feat: dispatch engine=grok from ai-pr-review"
```

### Task 3: Docs

**Files:**
- Modify: `.github/workflows/AI_PR_REVIEW_README.md`
- Modify: `README.md`

- [ ] **Step 1:** Add `grok` to the engines table, usage (`engine: kimi` / `anthropic` / `grok`), and note `[kimi, grok]` inputs vs `provider_type` remaining Kimi-only. Do not present wrapping Kimi as the Grok path.
- [ ] **Step 2:** README reusable-workflow row: `kimi | anthropic | grok`.
- [ ] **Step 3: Commit**

```bash
git add .github/workflows/AI_PR_REVIEW_README.md README.md
git commit -m "docs: document engine=grok for AI PR review"
```
