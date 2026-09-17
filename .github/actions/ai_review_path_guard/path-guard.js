#!/usr/bin/env node
'use strict';
// PreToolUse path guard for the AI review engines (Kimi Code and Claude Code).
//
// The Kimi engine copies this file into $HOME/.kimi-code and registers it in
// config.toml as a PreToolUse hook with a match-all matcher; the Anthropic
// engine copies it under $RUNNER_TEMP and registers it through the
// claude-code-action `settings` input, also match-all. Either CLI runs it
// before EVERY tool call with the call's JSON on stdin:
//   { "tool_name": "Read", "tool_input": { "path": "..." }, "cwd": "...", ... }
// Exit 0 allows the call. Exit 2 denies it and hands stderr to the model as the
// reason. Anything unexpected also exits 2: this guard fails closed.
//
// Why a hook at all: kimi-code 0.34.0 does not apply `[[permission.rules]]`
// when run as `kimi -p` (verified against a mock model endpoint while fixing
// HackerOne #4037167), and Claude Code's `--allowedTools` has no path scope for
// Read at all. In both engines this is the only thing confining paths, and the
// CLI process's own environment (readable through /proc without it) carries
// the LLM key — and, for Claude Code, the job's GitHub token.
//
// Why match-all and an explicit tool allow-list: in both CLIs a hook only
// blocks on exit 2; a call the matcher does not fire for is simply allowed. If
// a CLI bump renamed a tool or its path argument, a matcher listing four
// literal names would silently stop firing and the guard would be gone with no
// error. So the matcher is match-all, any tool other than Read/Grep/Glob/Write
// is denied here (the engine's own tool allow-list is the primary control
// removing them; this is the independent second one), and Read/Write without a
// string path are denied rather than waved through. Every decision this script
// makes is explicit; there is no "unknown, so allow".
//
// Allow-list, not deny-list:
//   Read / Grep / Glob  -> inside GITHUB_WORKSPACE, never through a `.git` segment
//   Read                -> additionally CONTEXT_PATH, DIFF_PATH and OUTPUT_PATH
//   Write               -> exactly OUTPUT_PATH, nothing else
//   Grep / Glob         -> may omit the path (the CLI then searches its cwd,
//                          which the run step pins to the workspace)
//   anything else       -> denied
// The path argument is `path` (Kimi Code, and Grep/Glob in both CLIs) or
// `file_path` (Claude Code's Read/Write). Both present and different is denied:
// the guard must know which one the tool will act on.
// $RUNNER_TEMP (where actions/checkout parks a token), $HOME, /proc, `~` and
// everything else fall outside that by construction. Symlinks are resolved
// before the comparison so a link inside the checkout cannot alias a file
// outside it.
//
// Audit trail: when PATH_GUARD_LOG is set, every decision appends one line
// (`allow<TAB>Read`) to that file, which lives outside the checkout. The
// engines' verify step fails the job if the file is missing or empty after a
// run that produced a review — a hook that never fired means the CLI's hook
// plumbing changed and the model ran unconfined. Writing the line can never
// change the decision: a logging failure is ignored here and surfaces there.
//
// Self-contained on purpose. Both CLIs treat a hook that times out or cannot
// start as ALLOW, and this process runs with the attacker-controlled checkout
// as its cwd. So: `node:` builtins only (they never consult node_modules), no
// reading of repo files, and the script itself lives outside the checkout.
// Node's package.json scope lookup walks UP from this file's directory, never
// down into the checkout. Keep it that way.
//
// Tests: path-guard.test.js (run with `node --test`).

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

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
function deny(reason) {
  record('deny');
  process.stderr.write(reason + '\n');
  process.exit(2);
}
function allow() {
  record('allow');
  process.exit(0);
}
process.on('uncaughtException', function (err) {
  deny('path guard: internal error: ' + (err && err.message ? err.message : String(err)));
});

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

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
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
let expanded = raw;
if (expanded === '~' || expanded.startsWith('~/')) expanded = path.join(os.homedir(), expanded.slice(1));
// The CLI resolves relative paths against its cwd, which the run step pins to
// the workspace.
const target = canonical(path.resolve(wsRaw, expanded));

if (tool === 'Write') {
  if (target === outFile) allow();
  deny('Write denied: ' + raw + '. This review may only write its single output file, ' + outFile + '.');
}
if (tool === 'Read' && readableFiles.indexOf(target) !== -1) allow();
if (within(target, ws)) {
  if (hasGitSegment(path.relative(ws, target))) {
    deny(tool + ' denied: ' + raw + ' is inside .git/, which is not part of the code under review.');
  }
  allow();
}
deny(tool + ' denied: ' + raw + ' resolves outside the PR checkout (' + ws + '). Only the checked-out repository, the review context and the pre-fetched diff may be read.');
