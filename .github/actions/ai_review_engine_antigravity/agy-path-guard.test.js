'use strict';
// Run with: node --test .github/actions/ai_review_engine_antigravity/agy-path-guard.test.js
//
// Tests the Antigravity CLI (`agy`) PreToolUse path guard against a synthetic
// runner layout: workspace with `.git/`, symlinks escaping the checkout,
// RUNNER_TEMP with checkout-style credentials, HOME with `~/.gemini` settings,
// and the caller-prepared CONTEXT_PATH and DIFF_PATH files.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const GUARD = path.join(__dirname, 'agy-path-guard.js');

function makeFixture() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'agy-path-guard-')));
  const ws = path.join(root, 'work', 'repo', 'repo');
  const runnerTemp = path.join(root, 'work', '_temp');
  const home = path.join(root, 'home');
  const inputs = path.join(root, 'inputs');
  for (const d of [
    path.join(ws, 'src'),
    path.join(ws, '.git', 'objects'),
    path.join(ws, '.github', 'workflows'),
    path.join(ws, 'packages', 'sub', '.git'),
    runnerTemp,
    path.join(home, '.gemini', 'antigravity-cli', 'builtin', 'skills', 'agy-customizations'),
    inputs,
  ]) {
    fs.mkdirSync(d, { recursive: true });
  }

  fs.writeFileSync(path.join(ws, 'src', 'index.ts'), 'export const value = 1;\n');
  fs.writeFileSync(path.join(ws, '.github', 'workflows', 'ci.yml'), 'name: ci\n');
  fs.writeFileSync(
    path.join(ws, '.git', 'config'),
    '[include]\n\tpath = ' + path.join(runnerTemp, 'git-credentials-abc.config') + '\n'
  );
  fs.writeFileSync(path.join(ws, 'packages', 'sub', '.git', 'HEAD'), 'ref: refs/heads/main\n');
  // Split literals so tests/ai-pr-review-contract.sh repo-wide cred-shape scan stays clean.
  fs.writeFileSync(
    path.join(runnerTemp, 'git-credentials-abc.config'),
    '[http "https://github.com/"]\n\textraheader = ' +
      'AUTHORIZATION: basic ' +
      'eC1hY2Nlc3Mt' +
      'dG9rZW46Z2hzX0ZBS0U=\n'
  );
  fs.writeFileSync(
    path.join(home, '.gemini', 'antigravity-cli', 'settings.json'),
    '{"modelProvider":"gemini"}\n'
  );
  fs.writeFileSync(
    path.join(home, '.gemini', 'antigravity-cli', 'builtin', 'skills', 'agy-customizations', 'SKILL.md'),
    '# skill\n'
  );
  fs.writeFileSync(path.join(inputs, 'review_context.md'), '# review context\n');
  fs.writeFileSync(path.join(inputs, 'pr_diff.txt'), 'diff --git a/src/index.ts b/src/index.ts\n');

  fs.symlinkSync(path.join(runnerTemp, 'git-credentials-abc.config'), path.join(ws, 'escape-file'));
  fs.symlinkSync(runnerTemp, path.join(ws, 'escape-dir'));
  fs.symlinkSync(path.join(ws, '.git', 'config'), path.join(ws, 'src', 'git-config-link'));

  return {
    root,
    ws,
    runnerTemp,
    home,
    inputs,
    env: {
      PATH: process.env.PATH,
      HOME: home,
      GITHUB_WORKSPACE: ws,
      RUNNER_TEMP: runnerTemp,
      CONTEXT_PATH: path.join(inputs, 'review_context.md'),
      DIFF_PATH: path.join(inputs, 'pr_diff.txt'),
    },
  };
}

function runGuard(fx, toolName, args, opts = {}) {
  const stdinPayload =
    opts.rawStdin !== undefined
      ? opts.rawStdin
      : JSON.stringify({
          conversationId: 'conv-1',
          workspacePaths: [fx.ws],
          modelName: 'gemini-4-carbon',
          stepIdx: 1,
          toolCall: {
            id: 'call-1',
            name: toolName,
            args,
          },
        });
  const res = spawnSync(process.execPath, [GUARD], {
    input: stdinPayload,
    cwd: fx.ws,
    env: opts.env || fx.env,
    encoding: 'utf8',
  });
  let parsed = null;
  try {
    parsed = JSON.parse(res.stdout);
  } catch (_) {
    parsed = null;
  }
  return { code: res.status, stdout: res.stdout, stderr: res.stderr, json: parsed };
}

function expectAllow(fx, toolName, args, opts) {
  const res = runGuard(fx, toolName, args, opts);
  assert.strictEqual(res.code, 0, `expected exit 0 for ${toolName}, got ${res.code} (${res.stderr})`);
  assert.ok(res.json, `expected JSON on stdout, got: ${res.stdout}`);
  assert.strictEqual(
    res.json.decision,
    'allow',
    `expected allow for ${toolName}(${JSON.stringify(args)}), got: ${res.stdout}`
  );
}

function expectDeny(fx, toolName, args, reasonRegex, opts) {
  const res = runGuard(fx, toolName, args, opts);
  assert.strictEqual(res.code, 0, `expected structured JSON exit 0 for ${toolName}, got ${res.code}`);
  assert.ok(res.json, `expected JSON on stdout, got: ${res.stdout}`);
  assert.strictEqual(
    res.json.decision,
    'deny',
    `expected deny for ${toolName}(${JSON.stringify(args)}), got: ${res.stdout}`
  );
  assert.strictEqual(typeof res.json.reason, 'string');
  if (reasonRegex) {
    assert.match(res.json.reason, reasonRegex);
  }
}

let fx;
test.before(() => {
  fx = makeFixture();
});
test.after(() => {
  fs.rmSync(fx.root, { recursive: true, force: true });
});

test('read_file and view_file allow files inside the workspace and caller context/diff', () => {
  expectAllow(fx, 'read_file', { Path: path.join(fx.ws, 'src', 'index.ts') });
  expectAllow(fx, 'read_file', { Path: 'src/index.ts', StartLine: 1, EndLine: 20 });
  expectAllow(fx, 'read_file', { Path: '.github/workflows/ci.yml' });
  expectAllow(fx, 'read_file', { Path: fx.env.CONTEXT_PATH });
  expectAllow(fx, 'read_file', { Path: fx.env.DIFF_PATH });

  expectAllow(fx, 'view_file', { AbsolutePath: path.join(fx.ws, 'src', 'index.ts') });
  expectAllow(fx, 'view_file', { AbsolutePath: fx.env.CONTEXT_PATH });
  expectAllow(fx, 'view_file', { AbsolutePath: fx.env.DIFF_PATH });
});

test('list_dir, find_by_name, and grep_search allow workspace directories and reject CONTEXT_PATH/DIFF_PATH', () => {
  expectAllow(fx, 'list_dir', { DirectoryPath: fx.ws });
  expectAllow(fx, 'list_dir', { DirectoryPath: 'src' });
  expectAllow(fx, 'find_by_name', { SearchDirectory: fx.ws, Pattern: '*.ts' });
  expectAllow(fx, 'grep_search', { SearchPath: path.join(fx.ws, 'src'), Query: 'value', Includes: ['*.ts'] });
  expectAllow(fx, 'grep_search', { SearchPath: 'src', Query: 'value', Includes: '*.ts' });

  expectDeny(fx, 'list_dir', { DirectoryPath: fx.inputs }, /outside the PR checkout/);
  expectDeny(fx, 'find_by_name', { SearchDirectory: fx.inputs, Pattern: '*' }, /outside the PR checkout/);
  expectDeny(fx, 'grep_search', { SearchPath: fx.env.CONTEXT_PATH, Query: 'x' }, /outside the PR checkout/);
});

test('denies .git/ at root, nested subdirectories, case variants, and symlinks into .git/', () => {
  expectDeny(fx, 'read_file', { Path: '.git/config' }, /inside \.git\//);
  expectDeny(fx, 'read_file', { Path: path.join(fx.ws, '.git', 'config') }, /inside \.git\//);
  expectDeny(fx, 'read_file', { Path: 'packages/sub/.git/HEAD' }, /inside \.git\//);
  expectDeny(fx, 'read_file', { Path: '.GIT/config' }, /inside \.git\//);
  expectDeny(fx, 'read_file', { Path: 'src/git-config-link' }, /inside \.git\//);
  expectDeny(fx, 'view_file', { AbsolutePath: '.git/config' }, /inside \.git\//);
  expectDeny(fx, 'list_dir', { DirectoryPath: '.git' }, /inside \.git\//);
  expectDeny(fx, 'find_by_name', { SearchDirectory: '.git', Pattern: '*' }, /inside \.git\//);
  expectDeny(fx, 'grep_search', { SearchPath: '.git', Query: 'extraheader' }, /inside \.git\//);
});

test('denies /proc/self/environ, RUNNER_TEMP, HOME, parent traversal, and escaping symlinks', () => {
  expectDeny(fx, 'read_file', { Path: '/proc/self/environ' }, /outside the PR checkout/);
  expectDeny(fx, 'read_file', { Path: path.join(fx.runnerTemp, 'git-credentials-abc.config') }, /outside/);
  expectDeny(fx, 'read_file', { Path: '../_temp/git-credentials-abc.config' }, /outside/);
  expectDeny(fx, 'read_file', { Path: '~/.gemini/antigravity-cli/settings.json' }, /outside/);
  expectDeny(fx, 'read_file', { Path: '~' }, /outside/);
  expectDeny(fx, 'read_file', { Path: 'escape-file' }, /outside/);
  expectDeny(fx, 'read_file', { Path: path.join(fx.ws, 'escape-dir', 'git-credentials-abc.config') }, /outside/);
  expectDeny(fx, 'grep_search', { SearchPath: 'escape-dir', Query: 'AUTHORIZATION' }, /outside/);
  expectDeny(fx, 'find_by_name', { SearchDirectory: 'escape-dir', Pattern: '*' }, /outside/);

  expectDeny(
    fx,
    'view_file',
    {
      AbsolutePath: path.join(fx.home, '.gemini', 'antigravity-cli', 'builtin', 'skills', 'agy-customizations', 'SKILL.md'),
      IsSkillFile: true,
    },
    /external skill files/
  );
  expectDeny(
    fx,
    'view_file',
    { AbsolutePath: fx.env.CONTEXT_PATH, IsSkillFile: true },
    /skill files/
  );
});

test('denies absolute or parent-traversing globs in find_by_name and grep_search', () => {
  expectDeny(fx, 'find_by_name', { SearchDirectory: fx.ws, Pattern: '/etc/*' }, /relative glob/);
  expectDeny(fx, 'find_by_name', { SearchDirectory: fx.ws, Pattern: '../**/*' }, /relative glob/);
  expectDeny(fx, 'find_by_name', { SearchDirectory: fx.ws, Pattern: '~/secret' }, /relative glob/);
  expectDeny(fx, 'find_by_name', { SearchDirectory: fx.ws, Pattern: 123 }, /relative glob/);
  expectDeny(fx, 'grep_search', { SearchPath: fx.ws, Query: 'x', Includes: '../**' }, /relative globs/);
  expectDeny(fx, 'grep_search', { SearchPath: fx.ws, Query: 'x', Includes: ['*.ts', '/etc/passwd'] }, /relative globs/);
  expectDeny(fx, 'grep_search', { SearchPath: fx.ws, Query: 'x', Includes: { bad: true } }, /string or array/);
});

test('denies all write, shell, web, subagent, task, MCP, and unknown tools', () => {
  expectDeny(fx, 'write_file', { Path: '/tmp/ai_review_output.txt', Content: 'x' }, /not permitted/);
  expectDeny(fx, 'write_to_file', { TargetFile: '/tmp/ai_review_output.txt', CodeContent: 'x' }, /not permitted/);
  expectDeny(fx, 'edit_file', { Path: 'src/index.ts', Target: '1', Replacement: '2' }, /not permitted/);
  expectDeny(fx, 'replace_file_content', { TargetFile: 'src/index.ts' }, /not permitted/);
  expectDeny(fx, 'multi_replace_file_content', { TargetFile: 'src/index.ts' }, /not permitted/);
  expectDeny(fx, 'run_command', { CommandLine: 'id', toolSummary: 'id', WaitMsBeforeAsync: 500 }, /not permitted/);
  expectDeny(fx, 'manage_task', { Action: 'list' }, /not permitted/);
  expectDeny(fx, 'schedule', { Prompt: 'wake' }, /not permitted/);
  expectDeny(fx, 'search_web', { query: 'deriv' }, /not permitted/);
  expectDeny(fx, 'read_url_content', { Url: 'https://example.com' }, /not permitted/);
  expectDeny(fx, 'invoke_subagent', { TypeName: 'research', Role: 'r', Prompt: 'p' }, /not permitted/);
  expectDeny(fx, 'define_subagent', { Name: 'x', Description: 'd', SystemPrompt: 's' }, /not permitted/);
  expectDeny(fx, 'ask_question', { questions: [] }, /not permitted/);
  expectDeny(fx, 'mcp__github__create_comment', {}, /not permitted/);
  expectDeny(fx, '', {}, /not permitted/);
});

test('denies missing, non-string, or conflicting path arguments and malformed payloads fail-closed', () => {
  expectDeny(fx, 'read_file', {}, /`Path` argument is required/);
  expectDeny(fx, 'read_file', { Path: '' }, /non-empty string/);
  expectDeny(fx, 'read_file', { Path: 42 }, /non-empty string/);
  expectDeny(fx, 'read_file', { Path: 'src/index.ts', AbsolutePath: '/etc/passwd' }, /conflicting path argument/);
  expectDeny(fx, 'view_file', { Path: 'src/index.ts' }, /conflicting path argument|`AbsolutePath` argument is required/);

  expectDeny(fx, 'read_file', {}, /internal error/, { rawStdin: 'not valid json' });
  expectDeny(fx, 'read_file', {}, /internal error/, { rawStdin: '' });
  expectDeny(fx, 'read_file', {}, /missing toolCall/, {
    rawStdin: JSON.stringify({ tool_name: 'Read', tool_input: { path: 'src/index.ts' } }),
  });

  const noWs = { ...fx.env };
  delete noWs.GITHUB_WORKSPACE;
  expectDeny(fx, 'read_file', { Path: 'src/index.ts' }, /GITHUB_WORKSPACE is not set/, { env: noWs });
});

test('appends allow and deny decisions to PATH_GUARD_LOG without letting log errors alter decisions', () => {
  const logPath = path.join(fx.runnerTemp, 'agy-guard.log');
  const env = { ...fx.env, PATH_GUARD_LOG: logPath };

  expectAllow(fx, 'read_file', { Path: 'src/index.ts' }, { env });
  expectDeny(fx, 'read_file', { Path: '/etc/hosts' }, /outside/, { env });
  expectDeny(fx, 'run_command', { CommandLine: 'whoami' }, /not permitted/, { env });
  expectDeny(fx, 'read_file', {}, /internal error/, { env, rawStdin: '{broken' });

  const lines = fs.readFileSync(logPath, 'utf8').split('\n');
  assert.deepStrictEqual(lines, [
    'allow\tread_file',
    'deny\tread_file',
    'deny\trun_command',
    'deny\t',
    '',
  ]);

  const badLogEnv = { ...fx.env, PATH_GUARD_LOG: path.join(fx.root, 'missing-dir', 'guard.log') };
  expectAllow(fx, 'read_file', { Path: 'src/index.ts' }, { env: badLogEnv });
  expectDeny(fx, 'read_file', { Path: '/etc/hosts' }, /outside/, { env: badLogEnv });
});

test('ignores hostile package.json and node_modules in the checkout and uses only node: builtins', () => {
  fs.writeFileSync(path.join(fx.ws, 'package.json'), JSON.stringify({ type: 'module', main: 'evil.js' }));
  for (const mod of ['fs', 'path', 'os']) {
    fs.mkdirSync(path.join(fx.ws, 'node_modules', mod), { recursive: true });
    fs.writeFileSync(
      path.join(fx.ws, 'node_modules', mod, 'index.js'),
      'process.stdout.write(JSON.stringify({decision:"allow"})); process.exit(0);\n'
    );
  }
  expectDeny(fx, 'read_file', { Path: '/etc/hosts' }, /outside the PR checkout/);

  const src = fs.readFileSync(GUARD, 'utf8');
  const requires = [...src.matchAll(/require\(['"]([^'"]+)['"]\)/g)].map((m) => m[1]);
  assert.ok(requires.length > 0);
  for (const req of requires) {
    assert.match(req, /^node:/, `${req} is not a node: builtin`);
  }
});
