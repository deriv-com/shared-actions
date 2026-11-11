#!/usr/bin/env node
'use strict';
// PreToolUse path guard for the Google Antigravity CLI (`agy`) review engine.
//
// Antigravity CLI loads global hooks from `$HOME/.gemini/config/hooks.json`
// (not `settings.json`, where `hooks` is deprecated and ignored). For every
// tool call matching `"*"`, `agy` spawns this script with JSON on stdin:
//   {
//     "toolCall": { "id": "...", "name": "read_file", "args": { "Path": "..." } },
//     "workspacePaths": ["..."],
//     ...
//   }
// and reads a JSON decision from stdout:
//   { "decision": "allow" }
//   { "decision": "deny", "reason": "..." }
//
// Why both Gemini 4 and Gemini 3.x read tool shapes are handled here:
//   - Verified on `agy` 1.5.5 against a local mock endpoint: Gemini 4 models
//     (`gemini-4-carbon`, `gemini-4-argon`) receive the unified file toolset
//     where reads arrive as `read_file` with `args.Path`.
//   - Earlier Gemini 3.x models in the same CLI use `view_file`
//     (`args.AbsolutePath`, optional `args.IsSkillFile`), `list_dir`
//     (`args.DirectoryPath`), `find_by_name` (`args.SearchDirectory`,
//     `args.Pattern`), and `grep_search` (`args.SearchPath`, `args.Includes`).
//
// Policy (strict allow-list, read-only):
//   - `read_file` / `view_file` -> inside GITHUB_WORKSPACE (never through a
//     `.git` segment), OR exact CONTEXT_PATH / DIFF_PATH. `view_file` with
//     `IsSkillFile === true` outside GITHUB_WORKSPACE is denied.
//   - `list_dir` / `find_by_name` / `grep_search` -> strictly inside
//     GITHUB_WORKSPACE (never through `.git`), with relative, `..`-free glob
//     patterns only.
//   - Every write, edit, shell, task, schedule, subagent, web, MCP, interactive,
//     or unrecognised tool (`write_file`, `write_to_file`, `edit_file`,
//     `replace_file_content`, `multi_replace_file_content`, `run_command`,
//     `manage_task`, `schedule`, `search_web`, `read_url_content`,
//     `invoke_subagent`, `define_subagent`, `manage_subagents`, `send_message`,
//     `ask_question`, `ask_permission`, ...) -> denied.
//
// Self-contained (`node:` built-ins only) so a hostile `package.json` or
// `node_modules` in the PR checkout cannot hijack imports. Every decision is
// appended to `PATH_GUARD_LOG` (`allow\t<tool>` or `deny\t<tool>`) so the
// engine's post-run check fails closed if the hook plumbing ever stops firing.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

let tool = '';
let decided = false;

function record(decision) {
  const logPath = process.env.PATH_GUARD_LOG;
  if (!logPath) return;
  try {
    fs.appendFileSync(logPath, decision + '\t' + tool + '\n');
  } catch (_) {
    // Deliberately ignored: logging must never flip a security decision, and
    // the engine's post-run verification refuses an empty/missing log.
  }
}

function respond(payload) {
  if (decided) return;
  decided = true;
  process.stdout.write(JSON.stringify(payload) + '\n');
}

function deny(reason) {
  record('deny');
  respond({ decision: 'deny', reason: String(reason) });
  process.exit(0);
}

function allow() {
  record('allow');
  respond({ decision: 'allow' });
  process.exit(0);
}

process.on('uncaughtException', function (err) {
  deny('path guard: internal error: ' + (err && err.message ? err.message : String(err)));
});

// realpath of the longest existing prefix: resolves symlinks anywhere in the
// path so a link inside the checkout cannot alias a file outside it.
function canonical(p) {
  let head = path.resolve(p);
  const tail = [];
  for (;;) {
    try {
      return path.join(fs.realpathSync.native(head), ...tail);
    } catch (_) {
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
  return rel.split(path.sep).some(function (seg) {
    return seg.toLowerCase() === '.git';
  });
}

function unsafeGlob(g) {
  if (typeof g !== 'string') return true;
  if (g === '~' || g.startsWith('~/') || g.startsWith('~\\')) return true;
  if (path.isAbsolute(g) || g.startsWith('/') || g.startsWith('\\')) return true;
  return g.split(/[\\/]/).indexOf('..') !== -1;
}

function present(v) {
  return v !== undefined && v !== null;
}

const rawStdin = fs.readFileSync(0, 'utf8');
const input = JSON.parse(rawStdin);
if (!input || typeof input !== 'object' || Array.isArray(input)) {
  deny('path guard: hook payload must be a JSON object.');
}

const toolCall = input.toolCall;
if (!toolCall || typeof toolCall !== 'object' || Array.isArray(toolCall)) {
  deny('path guard: missing toolCall object in hook payload.');
}

tool = typeof toolCall.name === 'string' ? toolCall.name : '';

const PATH_KEY_BY_TOOL = {
  read_file: 'Path',
  view_file: 'AbsolutePath',
  list_dir: 'DirectoryPath',
  find_by_name: 'SearchDirectory',
  grep_search: 'SearchPath',
};

if (!Object.prototype.hasOwnProperty.call(PATH_KEY_BY_TOOL, tool)) {
  deny(
    'path guard: tool "' +
      tool +
      '" is not permitted in this review. This engine is strictly read-only; deliver the review as your final text response.'
  );
}

const args = toolCall.args;
if (!args || typeof args !== 'object' || Array.isArray(args)) {
  deny(tool + ' denied: toolCall.args must be an object.');
}

const wsRaw = process.env.GITHUB_WORKSPACE;
if (!wsRaw) {
  deny('path guard: GITHUB_WORKSPACE is not set.');
}
const ws = canonical(wsRaw);

const readableExternalFiles = [process.env.CONTEXT_PATH, process.env.DIFF_PATH]
  .filter(function (p) {
    return typeof p === 'string' && p.length > 0;
  })
  .map(canonical);

if (tool === 'find_by_name' && present(args.Pattern)) {
  if (unsafeGlob(args.Pattern)) {
    deny('find_by_name denied: Pattern must be a relative glob without "..".');
  }
}

if (tool === 'grep_search' && present(args.Includes)) {
  const inc = args.Includes;
  if (typeof inc === 'string') {
    if (unsafeGlob(inc)) {
      deny('grep_search denied: Includes must be relative globs without "..".');
    }
  } else if (Array.isArray(inc)) {
    if (inc.some(unsafeGlob)) {
      deny('grep_search denied: Includes entries must be relative globs without "..".');
    }
  } else {
    deny('grep_search denied: Includes must be a string or array of strings.');
  }
}

const expectedKey = PATH_KEY_BY_TOOL[tool];
// Reject calls supplying conflicting path-like keys if a CLI change ever sends
// more than one path field on the same tool.
const ALL_KNOWN_PATH_KEYS = ['Path', 'AbsolutePath', 'DirectoryPath', 'SearchDirectory', 'SearchPath', 'TargetFile', 'path', 'file_path'];
for (const k of ALL_KNOWN_PATH_KEYS) {
  if (k !== expectedKey && present(args[k]) && args[k] !== args[expectedKey]) {
    deny(tool + ' denied: unexpected or conflicting path argument `' + k + '`.');
  }
}

const rawPath = args[expectedKey];
if (!present(rawPath)) {
  deny(tool + ' denied: `' + expectedKey + '` argument is required.');
}
if (typeof rawPath !== 'string' || rawPath.length === 0) {
  deny(tool + ' denied: `' + expectedKey + '` must be a non-empty string.');
}

let expanded = rawPath;
if (expanded === '~' || expanded.startsWith('~/')) {
  expanded = path.join(os.homedir(), expanded.slice(1));
}
const resolvedLexical = path.resolve(wsRaw, expanded);
const target = canonical(resolvedLexical);

if (tool === 'view_file' && args.IsSkillFile === true && !within(target, ws)) {
  deny('view_file denied: reading external skill files is not permitted in this review.');
}

if ((tool === 'read_file' || tool === 'view_file') && readableExternalFiles.indexOf(target) !== -1) {
  if (tool === 'view_file' && args.IsSkillFile === true) {
    deny('view_file denied: caller input files cannot be loaded as skill files.');
  }
  allow();
}

if (within(target, ws)) {
  // Check both the lexical path (when inside wsRaw) and the canonical path so
  // neither `.GIT/config` nor a link pointing into `.git/` can slip through.
  if (within(resolvedLexical, path.resolve(wsRaw)) && hasGitSegment(path.relative(path.resolve(wsRaw), resolvedLexical))) {
    deny(tool + ' denied: ' + rawPath + ' is inside .git/, which is not part of the code under review.');
  }
  if (hasGitSegment(path.relative(ws, target))) {
    deny(tool + ' denied: ' + rawPath + ' is inside .git/, which is not part of the code under review.');
  }
  allow();
}

deny(
  tool +
    ' denied: ' +
    rawPath +
    ' resolves outside the PR checkout (' +
    ws +
    '). Only the checked-out repository, the review context and the pre-fetched diff may be read.'
);
