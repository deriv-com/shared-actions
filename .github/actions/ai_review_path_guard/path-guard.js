#!/usr/bin/env node
'use strict';
// PreToolUse path guard for the AI review engines:
//   - Default mode (no flags): Kimi Code and Claude Code (`stdin` carries
//     `{ tool_name, tool_input }`; exit 0 allows, exit 2 + stderr denies).
//   - `--cli=antigravity`: Google Antigravity CLI `agy` (`stdin` carries
//     `{ toolCall: { name, args } }`; `stdout` emits `{"decision":"allow"}`
//     or `{"decision":"deny","reason":"..."}`).
//
// Why a hook at all:
//   - Kimi Code (`kimi -p`) ignores `[[permission.rules]]` in print mode
//     (verified on 0.34.0 and 2.3.2 while fixing HackerOne #4037167).
//   - Claude Code's `--allowedTools` has no path scope for `Read`, and its
//     CLI environment carries the job's GitHub token.
//   - Antigravity CLI (`agy -p`) runs in a strictly read-only posture
//     (`settings.json` denies `command(*)`, `write_file(*)`, `read_file(.git/)`,
//     `read_url(*)`, `execute_url(*)`, `mcp(*)`); this hook is the independent
//     second layer confining `read_file` to the checkout (minus `.git/`) plus
//     `CONTEXT_PATH` / `DIFF_PATH` and proving via `PATH_GUARD_LOG` that the
//     hook ran. (Verified against `agy` 1.5.5 wire captures across Gemini 4 and
//     Gemini 3.x: `read_file` with `args.Path` is the CLI's only file-read tool;
//     IDE-only tools like `grep_search`, `find_by_name`, `list_dir`, and
//     `view_file` do not exist in `agy`.)
//
// Audit trail: when PATH_GUARD_LOG is set, every decision appends one line
// (`allow<TAB><tool>` or `deny<TAB><tool>`) to that file outside the checkout.
// Each engine's post-run check fails the job if the log is missing or empty.
//
// Self-contained on purpose: `node:` builtins only (never consults
// `node_modules`), no reading of repo files, and installed outside the PR
// checkout.
//
// Tests: path-guard.test.js (run with `node --test`).

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const cliArgs = process.argv.slice(2);
const isAntigravity = cliArgs.length === 1 && cliArgs[0] === '--cli=antigravity';

let tool = '';
let decided = false;

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
  if (decided) return;
  decided = true;
  record('deny');
  const msg = String(reason);
  if (isAntigravity) {
    process.stdout.write(JSON.stringify({ decision: 'deny', reason: msg }) + '\n');
    process.exit(0);
  }
  process.stderr.write(msg + '\n');
  process.exit(2);
}

function allow() {
  if (decided) return;
  decided = true;
  record('allow');
  if (isAntigravity) {
    process.stdout.write(JSON.stringify({ decision: 'allow' }) + '\n');
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

function allowIfInsideCheckoutMinusGit(raw, wsRaw, ws, target) {
  const lexicalWs = path.resolve(wsRaw);
  const lexicalTarget = path.resolve(wsRaw, expandTilde(raw));
  if (within(target, ws)) {
    if (within(lexicalTarget, lexicalWs) && hasGitSegment(path.relative(lexicalWs, lexicalTarget))) {
      deny(tool + ' denied: ' + raw + ' is inside .git/, which is not part of the code under review.');
    }
    if (hasGitSegment(path.relative(ws, target))) {
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

  const target = canonical(path.resolve(wsRaw, expandTilde(raw)));
  if (readableFiles.indexOf(target) !== -1) allow();
  allowIfInsideCheckoutMinusGit(raw, wsRaw, ws, target);
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
const target = canonical(path.resolve(wsRaw, expandTilde(raw)));

if (tool === 'Write') {
  if (target === outFile) allow();
  deny('Write denied: ' + raw + '. This review may only write its single output file, ' + outFile + '.');
}
if (tool === 'Read' && readableFiles.indexOf(target) !== -1) allow();
allowIfInsideCheckoutMinusGit(raw, wsRaw, ws, target);
deny(tool + ' denied: ' + raw + ' resolves outside the PR checkout (' + ws + '). Only the checked-out repository, the review context and the pre-fetched diff may be read.');
