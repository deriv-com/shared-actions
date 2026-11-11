#!/usr/bin/env node
'use strict';
// PreToolUse path guard for the AI review engines:
//   - Default mode (no flags): Kimi Code and Claude Code. The Kimi engine
//     copies this file into $HOME/.kimi-code and registers it in config.toml as
//     a PreToolUse hook with a match-all matcher; the Anthropic engine copies
//     it under $RUNNER_TEMP and registers it through the claude-code-action
//     `settings` input, also match-all. Either CLI runs it before EVERY tool
//     call with the call's JSON on stdin:
//       { "tool_name": "Read", "tool_input": { "path": "..." }, "cwd": "..." }
//     Exit 0 allows the call. Exit 2 denies it and hands stderr to the model as
//     the reason. Anything unexpected also exits 2: this guard fails closed.
//   - `--cli=antigravity`: Google Antigravity CLI (`agy`). Copied under
//     $RUNNER_TEMP and registered in `$HOME/.gemini/config/hooks.json` with a
//     match-all (`"*"`) matcher. `agy` passes `{ toolCall: { name, args } }` on
//     stdin and reads `{"decision":"allow"}` or
//     `{"decision":"deny","reason":"..."}` from stdout.
//
// Why a hook at all: kimi-code does not apply `[[permission.rules]]`
// when run as `kimi -p` (found on kimi-code 0.34.0 against a mock model
// endpoint while fixing HackerOne #4037167; re-verified on kimi-code 2.3.2 —
// a bare `deny Read` still read files and a bare `deny Write` still wrote
// into the checkout), and Claude Code's `--allowedTools` has no path scope
// for Read at all. In both engines this is the only thing confining paths,
// and the CLI process's own environment (readable through /proc without it)
// carries the LLM key — and, for Claude Code, the job's GitHub token. In the
// Antigravity engine this hook is the independent second layer alongside
// `settings.json` permission denials (`allowNonWorkspaceAccess: false`,
// `read_file(.git/)` denied, all non-read actions denied).
//
// Why match-all and an explicit tool allow-list: in Kimi Code and Claude Code a
// hook only blocks on exit 2, and in all three CLIs a call the matcher does not
// fire for is simply allowed without consulting the hook. If a CLI bump renamed
// a tool or its path argument, a matcher listing literal tool names would
// silently stop firing and the guard would be gone with no error. So the
// matcher is match-all, any tool outside the mode's explicit allow-list is
// denied here (the engine's own tool configuration is the primary control
// removing them; this is the independent second one), and file tools without a
// string path are denied rather than waved through. Every decision this script
// makes is explicit; there is no "unknown, so allow".
//
// Allow-list, not deny-list:
//   Default mode (Kimi Code & Claude Code):
//     Read / Grep / Glob  -> inside GITHUB_WORKSPACE, never through a `.git` segment
//     Read                -> additionally CONTEXT_PATH, DIFF_PATH and OUTPUT_PATH
//     Write               -> exactly OUTPUT_PATH, nothing else
//     Grep / Glob         -> may omit the path (the CLI then searches its cwd,
//                            which the run step pins to the workspace)
//     anything else       -> denied
//   `--cli=antigravity` mode (Google Antigravity CLI `agy`):
//     read_file (`Path`)  -> inside GITHUB_WORKSPACE, never through a `.git`
//                            segment, plus CONTEXT_PATH and DIFF_PATH
//                            (OUTPUT_PATH is excluded: `agy` is strictly read-only,
//                            and wire captures on `agy` 1.5.5 confirm `read_file`
//                            is the sole file-read tool the CLI exposes)
//     anything else       -> denied
// In default mode the path argument is `path` (Kimi Code, and Grep/Glob in both
// CLIs) or `file_path` (Claude Code's Read/Write). Both present and different
// is denied: the guard must know which one the tool will act on.
// $RUNNER_TEMP (where actions/checkout parks a token), $HOME, /proc, `~` and
// everything else fall outside that by construction. Symlinks are resolved
// before the comparison so a link inside the checkout cannot alias a file
// outside it.
//
// Audit trail: when PATH_GUARD_LOG is set, every decision appends one line
// (`allow<TAB><tool>` or `deny<TAB><tool>`) to that file, which lives outside
// the checkout. The engines' verify step fails the job if the file is missing
// or empty after a run that produced a review — a hook that never fired means
// the CLI's hook plumbing changed and the model ran unconfined. Writing the
// line can never change the decision: a logging failure is ignored here and
// surfaces there.
//
// Self-contained on purpose. Kimi Code and Claude Code treat a hook that times
// out or cannot start as ALLOW (hence `|| exit 2` in their hook commands), and
// `agy` 1.5.5 treats an exit-0 hook with empty stdout as ALLOW (while failing
// closed on non-zero exit — verified with `command: "exit 2"` -> `JSON hook
// ... failed: command failed: exit status 2` — or hook timeout — verified with
// `timeout: 1` + `sleep 2` -> `signal: killed`; its `hooks.json` command wraps
// node with `timeout 20` and validates stdout). This process runs with the
// attacker-controlled checkout as its cwd. So: `node:` builtins only (they
// never consult node_modules), no reading of repo files, and the script itself
// lives outside the checkout. Node's package.json scope lookup walks UP from
// this file's directory, never down into the checkout. Keep it that way.
//
// Tests: path-guard.test.js (run with `node --test`).

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const cliArgs = process.argv.slice(2);
const isAntigravity = cliArgs.length === 1 && cliArgs[0] === '--cli=antigravity';

let tool = '';

function record(decision) {
  const logPath = process.env.PATH_GUARD_LOG;
  if (!logPath) return;
  try {
    fs.appendFileSync(logPath, decision + '\t' + tool + '\n');
  } catch (e) {
    // Deliberately ignored: see "Audit trail" above.
  }
}

// Every call site relies on deny() and allow() never returning. Synchronous
// fs.writeSync(1/2, ...) flushes before process.exit and throws synchronously
// on EPIPE/EBADF, wrapped in try/catch so a write failure exits 2 rather than
// throwing into uncaughtException or exiting 0 with empty stdout in
// `--cli=antigravity` mode.
function deny(reason) {
  record('deny');
  const msg = String(reason);
  try {
    if (isAntigravity) {
      fs.writeSync(1, JSON.stringify({ decision: 'deny', reason: msg }) + '\n');
    } else {
      fs.writeSync(2, msg + '\n');
    }
  } catch (e) {
    process.exit(2);
  }
  process.exit(isAntigravity ? 0 : 2);
}

function allow() {
  record('allow');
  if (isAntigravity) {
    try {
      fs.writeSync(1, JSON.stringify({ decision: 'allow' }) + '\n');
    } catch (e) {
      process.exit(2);
    }
  }
  process.exit(0);
}

process.on('uncaughtException', function (err) {
  deny('path guard: internal error: ' + (err && err.message ? err.message : String(err)));
});

if (cliArgs.length > 0 && !isAntigravity) {
  deny('path guard: unrecognized CLI arguments: ' + cliArgs.join(' '));
}

// realpath of the longest existing prefix: resolves symlinks anywhere in the
// path, and still works for an output file that does not exist yet.
function canonical(p) {
  let head = path.resolve(p);
  const tail = [];
  for (;;) {
    try {
      return path.join(fs.realpathSync.native(head), ...tail);
    } catch (e) {
      const parent = path.dirname(head);
      if (parent === head) return path.join(head, ...tail);
      tail.unshift(path.basename(head));
      head = parent;
    }
  }
}

function within(child, parent) {
  const rel = path.relative(parent, child);
  return rel === '' || (!path.isAbsolute(rel) && rel.split(path.sep)[0] !== '..');
}

function hasGitSegment(rel) {
  return rel.split(path.sep).some(function (seg) { return seg.toLowerCase() === '.git'; });
}

// ripgrep matches these relative to the search root, so neither shape is ever
// needed for a legitimate search; refuse them rather than reason about
// ripgrep's anchoring rules.
function unsafeGlob(g) {
  return typeof g === 'string' && (path.isAbsolute(g) || g.split(/[\\/]/).indexOf('..') !== -1);
}

function present(v) {
  return v !== undefined && v !== null;
}

function expandTilde(raw) {
  if (raw === '~' || raw.startsWith('~/')) {
    return path.join(os.homedir(), raw.slice(1));
  }
  return raw;
}

function allowIfInsideCheckoutMinusGit(raw, lexicalWs, ws, lexicalTarget, target) {
  if (within(target, ws)) {
    const lexicalHasGit = within(lexicalTarget, lexicalWs) && hasGitSegment(path.relative(lexicalWs, lexicalTarget));
    const canonicalHasGit = hasGitSegment(path.relative(ws, target));
    if (lexicalHasGit || canonicalHasGit) {
      deny(tool + ' denied: ' + raw + ' is inside .git/, which is not part of the code under review.');
    }
    allow();
  }
}

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
if (!input || typeof input !== 'object' || Array.isArray(input)) {
  deny('path guard: hook payload must be a JSON object.');
}

if (isAntigravity) {
  const toolCall = input.toolCall;
  if (!toolCall || typeof toolCall !== 'object' || Array.isArray(toolCall)) {
    deny('path guard: missing toolCall object in Antigravity hook payload.');
  }
  tool = typeof toolCall.name === 'string' ? toolCall.name : '';
  if (tool !== 'read_file') {
    deny('path guard: tool "' + tool + '" is not permitted in this review. Only read_file is.');
  }
  const agyArgs = toolCall.args;
  if (!agyArgs || typeof agyArgs !== 'object' || Array.isArray(agyArgs)) {
    deny('read_file denied: toolCall.args must be an object.');
  }
  const wsRaw = process.env.GITHUB_WORKSPACE;
  if (!wsRaw) deny('path guard: GITHUB_WORKSPACE is not set');
  const lexicalWs = path.resolve(wsRaw);
  const ws = canonical(wsRaw);
  const readableFiles = [process.env.CONTEXT_PATH, process.env.DIFF_PATH]
    .filter(function (p) { return typeof p === 'string' && p.length > 0; })
    .map(canonical);

  const OTHER_PATH_KEYS = ['AbsolutePath', 'DirectoryPath', 'SearchDirectory', 'SearchPath', 'TargetFile', 'path', 'file_path'];
  for (const k of OTHER_PATH_KEYS) {
    if (present(agyArgs[k]) && agyArgs[k] !== agyArgs.Path) {
      deny('read_file denied: unexpected or conflicting path argument `' + k + '`.');
    }
  }

  const raw = agyArgs.Path;
  if (!present(raw)) deny('read_file denied: a `Path` argument is required.');
  if (typeof raw !== 'string' || raw.length === 0) deny('read_file denied: `Path` must be a non-empty string.');

  const lexicalTarget = path.resolve(wsRaw, expandTilde(raw));
  const target = canonical(lexicalTarget);
  if (readableFiles.indexOf(target) !== -1) allow();
  allowIfInsideCheckoutMinusGit(raw, lexicalWs, ws, lexicalTarget, target);
  deny('read_file denied: ' + raw + ' resolves outside the PR checkout (' + ws + '). Only the checked-out repository, the review context and the pre-fetched diff may be read.');
}

tool = String(input.tool_name || '');
const args = input.tool_input && typeof input.tool_input === 'object' ? input.tool_input : {};

// Exact names, not patterns: a tool this script has never heard of gets no
// path check, so it gets no permission either. Which argument names carry the
// path is part of the contract: `path` (Kimi Code; Grep/Glob everywhere),
// `file_path` (Claude Code's Read/Write).
const PATH_KEYS = { Read: ['path', 'file_path'], Write: ['path', 'file_path'], Grep: ['path'], Glob: ['path'] };
if (!Object.prototype.hasOwnProperty.call(PATH_KEYS, tool)) {
  deny('path guard: tool "' + tool + '" is not permitted in this review. Only Read, Grep, Glob and Write are.');
}

const wsRaw = process.env.GITHUB_WORKSPACE;
const outRaw = process.env.OUTPUT_PATH;
if (!wsRaw || !outRaw) deny('path guard: GITHUB_WORKSPACE or OUTPUT_PATH is not set');
const lexicalWs = path.resolve(wsRaw);
const ws = canonical(wsRaw);
const outFile = canonical(outRaw);
// Files the caller prepared for the model, plus its own output so it can
// re-read what it wrote.
const readableFiles = [process.env.CONTEXT_PATH, process.env.DIFF_PATH]
  .filter(function (p) { return typeof p === 'string' && p.length > 0; })
  .map(canonical)
  .concat([outFile]);

if ((tool === 'Glob' && unsafeGlob(args.pattern)) || (tool === 'Grep' && unsafeGlob(args.glob))) {
  deny(tool + ' denied: glob patterns must be relative to the search path and must not contain "..".');
}

const supplied = PATH_KEYS[tool].map(function (k) { return args[k]; }).filter(present);
if (supplied.length > 1 && supplied.some(function (v) { return v !== supplied[0]; })) {
  deny(tool + ' denied: `path` and `file_path` disagree; supply one path.');
}
const raw = supplied.length > 0 ? supplied[0] : undefined;
if (!present(raw)) {
  // Grep/Glob search the CLI's cwd when the path is omitted, and the run step
  // pins that to the workspace. Read/Write have nothing to check without a
  // path, so they are denied rather than assumed harmless: if a future CLI
  // renamed the argument, every call would arrive here, and "allow" would mean
  // no guard.
  if (tool === 'Grep' || tool === 'Glob') allow();
  deny(tool + ' denied: a `path` argument is required.');
}
if (typeof raw !== 'string') deny(tool + ' denied: path must be a string.');
// The CLI resolves relative paths against its cwd, which the run step pins to
// the workspace.
const lexicalTarget = path.resolve(wsRaw, expandTilde(raw));
const target = canonical(lexicalTarget);

if (tool === 'Write') {
  if (target === outFile) allow();
  deny('Write denied: ' + raw + '. This review may only write its single output file, ' + outFile + '.');
}
if (tool === 'Read' && readableFiles.indexOf(target) !== -1) allow();
allowIfInsideCheckoutMinusGit(raw, lexicalWs, ws, lexicalTarget, target);
deny(tool + ' denied: ' + raw + ' resolves outside the PR checkout (' + ws + '). Only the checked-out repository, the review context and the pre-fetched diff may be read.');
