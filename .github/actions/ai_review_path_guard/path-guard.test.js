// Run with: node --test .github/actions/ai_review_path_guard/path-guard.test.js
//
// No package.json and no dependencies on purpose — this repo ships workflows,
// not a Node package, so the tests use the runner built into Node 18+.
//
// The guard is a stdin -> exit-code program, so it is tested as one: a fake
// runner layout is built under a temp dir (workspace with .git/, a symlink that
// escapes it, a RUNNER_TEMP with a checkout-style credentials file, the caller's
// input files, the output dir), and each case spawns the script exactly as the
// CLIs do — JSON on stdin, cwd = workspace — and asserts allow (0) or deny (2)
// plus the reason. Both hook contracts are covered: Kimi Code (`path`) and
// Claude Code (`file_path` on Read/Write). Cases mirror the HackerOne #4037167
// attack chain.
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const GUARD = path.join(__dirname, "path-guard.js");

function makeFixture() {
  // realpath: on macOS os.tmpdir() is a symlink (/var -> /private/var) and the
  // guard canonicalises, so expected paths must be canonical too.
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "path-guard-")));
  const ws = path.join(root, "work", "repo", "repo");
  const runnerTemp = path.join(root, "work", "_temp");
  const home = path.join(root, "home");
  const outDir = path.join(root, "out");
  const inputs = path.join(root, "inputs");
  for (const d of [
    path.join(ws, "src"),
    path.join(ws, ".git", "objects"),
    path.join(ws, ".github", "workflows"),
    path.join(ws, "pkg", ".git"),
    runnerTemp,
    path.join(home, ".kimi-code"),
    outDir,
    inputs,
  ]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(ws, "src", "a.ts"), "export const a = 1;\n");
  fs.writeFileSync(path.join(ws, ".github", "workflows", "x.yml"), "name: x\n");
  fs.writeFileSync(path.join(ws, ".git", "config"), "[include]\n\tpath = " + path.join(runnerTemp, "git-credentials-abc.config") + "\n");
  fs.writeFileSync(path.join(ws, "pkg", ".git", "HEAD"), "ref: refs/heads/main\n");
  // Assembled from fragments so a review quoting this file does not itself trip
  // the post step's credential-shape guard (tests/ai-pr-review-contract.sh
  // asserts nothing in the repo's own text does).
  fs.writeFileSync(path.join(runnerTemp, "git-credentials-abc.config"),
    "[http \"https://github.com/\"]\n\textraheader = " + "AUTHORIZATION: basic " + "eC1hY2Nlc3Mt" + "dG9rZW46Z2hzX0ZBS0U=\n");
  fs.writeFileSync(path.join(home, ".kimi-code", "config.toml"), "default_permission_mode = \"auto\"\n");
  fs.writeFileSync(path.join(inputs, "review_context.md"), "# context\n");
  fs.writeFileSync(path.join(inputs, "pr_diff.txt"), "diff --git a/x b/x\n");
  // Escapes: a file link and a directory link, both inside the checkout.
  fs.symlinkSync(path.join(runnerTemp, "git-credentials-abc.config"), path.join(ws, "escape-link"));
  fs.symlinkSync(runnerTemp, path.join(ws, "escape-dir"));
  // A link inside the output dir that points back into the checkout.
  fs.symlinkSync(path.join(ws, "src", "a.ts"), path.join(outDir, "sneaky.txt"));
  return {
    root, ws, runnerTemp, home, outDir, inputs,
    outFile: path.join(outDir, "ai_review_output.txt"),
    env: {
      PATH: process.env.PATH,
      HOME: home,
      GITHUB_WORKSPACE: ws,
      RUNNER_TEMP: runnerTemp,
      OUTPUT_PATH: path.join(outDir, "ai_review_output.txt"),
      CONTEXT_PATH: path.join(inputs, "review_context.md"),
      DIFF_PATH: path.join(inputs, "pr_diff.txt"),
    },
  };
}

function run(fx, toolName, toolInput, opts = {}) {
  const payload = opts.rawStdin !== undefined
    ? opts.rawStdin
    : JSON.stringify({ hook_event_name: "PreToolUse", session_id: "s", cwd: fx.ws, tool_name: toolName, tool_input: toolInput, tool_call_id: "c" });
  const r = spawnSync(process.execPath, [GUARD], {
    input: payload,
    cwd: fx.ws,
    env: opts.env || fx.env,
    encoding: "utf8",
  });
  return { code: r.status, stderr: r.stderr, stdout: r.stdout };
}

function expectAllow(fx, toolName, toolInput) {
  const r = run(fx, toolName, toolInput);
  assert.strictEqual(r.code, 0, `${toolName}(${JSON.stringify(toolInput)}) should be allowed; stderr: ${r.stderr}`);
}
function expectDeny(fx, toolName, toolInput, reasonPart) {
  const r = run(fx, toolName, toolInput);
  assert.strictEqual(r.code, 2, `${toolName}(${JSON.stringify(toolInput)}) should be denied with exit 2, got ${r.code}; stderr: ${r.stderr}`);
  if (reasonPart) assert.match(r.stderr, reasonPart);
}

let fx;
test.before(() => { fx = makeFixture(); });
test.after(() => { fs.rmSync(fx.root, { recursive: true, force: true }); });

test("Read inside the checkout is allowed, dot-directories included", () => {
  expectAllow(fx, "Read", { path: "src/a.ts" });
  expectAllow(fx, "Read", { path: path.join(fx.ws, "src", "a.ts") });
  expectAllow(fx, "Read", { path: ".github/workflows/x.yml" });
  expectAllow(fx, "Read", { path: "./src/../src/a.ts" });
});

test("Read of the caller's input files and the output file is allowed", () => {
  expectAllow(fx, "Read", { path: fx.env.CONTEXT_PATH });
  expectAllow(fx, "Read", { path: fx.env.DIFF_PATH });
  expectAllow(fx, "Read", { path: fx.outFile });
});

test("Read of anything else outside the checkout is denied", () => {
  expectDeny(fx, "Read", { path: "/etc/hosts" }, /outside the PR checkout/);
  expectDeny(fx, "Read", { path: path.join(fx.runnerTemp, "git-credentials-abc.config") }, /outside/);
  expectDeny(fx, "Read", { path: "../_temp/git-credentials-abc.config" }, /outside/);
  expectDeny(fx, "Read", { path: path.join(fx.ws, "src", "..", "..", "_temp", "git-credentials-abc.config") }, /outside/);
  expectDeny(fx, "Read", { path: "~/.kimi-code/config.toml" }, /outside/);
  expectDeny(fx, "Read", { path: "~" }, /outside/);
  expectDeny(fx, "Read", { path: "/proc/self/environ" }, /outside/);
  expectDeny(fx, "Read", { path: path.join(fx.outDir, "other.txt") }, /outside/);
});

test("Read inside .git/ is denied, at any depth and any case", () => {
  expectDeny(fx, "Read", { path: ".git/config" }, /inside \.git\//);
  expectDeny(fx, "Read", { path: path.join(fx.ws, ".git", "config") }, /inside \.git\//);
  expectDeny(fx, "Read", { path: "pkg/.git/HEAD" }, /inside \.git\//);
  expectDeny(fx, "Read", { path: ".git" }, /inside \.git\//);
  expectDeny(fx, "Read", { path: ".GIT/config" }, /inside \.git\//);
});

test("symlinks inside the checkout cannot alias files outside it", () => {
  expectDeny(fx, "Read", { path: "escape-link" }, /outside/);
  expectDeny(fx, "Read", { path: path.join(fx.ws, "escape-dir", "git-credentials-abc.config") }, /outside/);
  expectDeny(fx, "Grep", { pattern: "AUTHORIZATION", path: "escape-dir" }, /outside/);
  expectDeny(fx, "Glob", { pattern: "*", path: "escape-dir" }, /outside/);
});

test("Grep and Glob default to the workspace and may search inside it", () => {
  expectAllow(fx, "Grep", { pattern: "token" });
  expectAllow(fx, "Grep", { pattern: "token", path: "src" });
  expectAllow(fx, "Grep", { pattern: "token", path: fx.ws, glob: "**/*.ts" });
  expectAllow(fx, "Glob", { pattern: "**/*.ts" });
  expectAllow(fx, "Glob", { pattern: "*.yml", path: ".github/workflows" });
});

test("Grep and Glob outside the checkout or inside .git/ are denied", () => {
  expectDeny(fx, "Grep", { pattern: "AUTHORIZATION", path: fx.runnerTemp, output_mode: "content" }, /outside/);
  expectDeny(fx, "Grep", { pattern: "AUTHORIZATION", path: ".git" }, /inside \.git\//);
  expectDeny(fx, "Glob", { pattern: "*", path: fx.runnerTemp }, /outside/);
  expectDeny(fx, "Glob", { pattern: "*", path: ".git" }, /inside \.git\//);
  expectDeny(fx, "Glob", { pattern: "*", path: "/" }, /outside/);
});

test("absolute or parent-traversing glob patterns are refused outright", () => {
  expectDeny(fx, "Glob", { pattern: "/etc/*" }, /must be relative/);
  expectDeny(fx, "Glob", { pattern: "../**/*" }, /must be relative/);
  expectDeny(fx, "Glob", { pattern: "src/../../**" }, /must be relative/);
  expectDeny(fx, "Grep", { pattern: "x", glob: "../**" }, /must be relative/);
  expectDeny(fx, "Grep", { pattern: "x", glob: "/etc/**" }, /must be relative/);
});

test("Write is allowed only for the exact output file", () => {
  expectAllow(fx, "Write", { path: fx.outFile, content: "review" });
  expectAllow(fx, "Write", { path: path.join(fx.outDir, ".", "ai_review_output.txt"), content: "review" });
  expectDeny(fx, "Write", { path: path.join(fx.outDir, "other.txt"), content: "x" }, /single output file/);
  expectDeny(fx, "Write", { path: path.join(fx.outDir, "sneaky.txt"), content: "x" }, /single output file/);
  expectDeny(fx, "Write", { path: path.join(fx.ws, "pwned.txt"), content: "x" }, /single output file/);
  expectDeny(fx, "Write", { path: "src/a.ts", content: "x" }, /single output file/);
  expectDeny(fx, "Write", { path: "/tmp/anything.txt", content: "x" }, /single output file/);
  expectDeny(fx, "Write", { path: fx.env.CONTEXT_PATH, content: "x" }, /single output file/);
  expectDeny(fx, "Write", { path: path.join(fx.outDir, "..", "out", "ai_review_output.txt", "..", "other.txt"), content: "x" }, /single output file/);
});

test("the guard fails closed on malformed input or a broken environment", () => {
  let r = run(fx, "Read", {}, { rawStdin: "not json" });
  assert.strictEqual(r.code, 2);
  assert.match(r.stderr, /internal error/);

  r = run(fx, "Read", {}, { rawStdin: "" });
  assert.strictEqual(r.code, 2);

  r = run(fx, "Read", { path: 42 });
  assert.strictEqual(r.code, 2);
  assert.match(r.stderr, /must be a string/);

  const noWs = { ...fx.env };
  delete noWs.GITHUB_WORKSPACE;
  r = run(fx, "Read", { path: "src/a.ts" }, { env: noWs });
  assert.strictEqual(r.code, 2);
  assert.match(r.stderr, /GITHUB_WORKSPACE or OUTPUT_PATH/);

  const noOut = { ...fx.env };
  delete noOut.OUTPUT_PATH;
  r = run(fx, "Write", { path: fx.outFile, content: "x" }, { env: noOut });
  assert.strictEqual(r.code, 2);
});

test("Grep/Glob may omit path (the CLI searches its cwd, pinned to the workspace); Read/Write may not", () => {
  expectAllow(fx, "Grep", { pattern: "x" });
  expectAllow(fx, "Glob", { pattern: "*" });
  // A renamed argument in a future CLI would make every call look like this.
  // That must read as "no guard", not "nothing to check".
  expectDeny(fx, "Read", {}, /path.*required/);
  expectDeny(fx, "Read", { filePath: "src/a.ts" }, /path.*required/);
  expectDeny(fx, "Write", { content: "x" }, /path.*required/);
  expectDeny(fx, "Write", { filePath: fx.outFile, content: "x" }, /path.*required/);
  expectDeny(fx, "Read", { path: null }, /path.*required/);
});

test("Claude Code shape: Read/Write carry the path in file_path and get the same rules", () => {
  expectAllow(fx, "Read", { file_path: path.join(fx.ws, "src", "a.ts") });
  expectAllow(fx, "Read", { file_path: "src/a.ts", offset: 1, limit: 10 });
  expectAllow(fx, "Read", { file_path: fx.env.CONTEXT_PATH });
  expectAllow(fx, "Read", { file_path: fx.outFile });
  expectDeny(fx, "Read", { file_path: "/proc/self/environ" }, /outside/);
  expectDeny(fx, "Read", { file_path: path.join(fx.runnerTemp, "git-credentials-abc.config") }, /outside/);
  expectDeny(fx, "Read", { file_path: path.join(fx.ws, ".git", "config") }, /inside \.git\//);
  expectDeny(fx, "Read", { file_path: path.join(fx.home, ".claude", "settings.json") }, /outside/);
  expectDeny(fx, "Read", { file_path: "escape-link" }, /outside/);
  expectAllow(fx, "Write", { file_path: fx.outFile, content: "review" });
  expectDeny(fx, "Write", { file_path: path.join(fx.outDir, "other.txt"), content: "x" }, /single output file/);
  expectDeny(fx, "Write", { file_path: path.join(fx.ws, ".git", "config"), content: "x" }, /single output file/);
  expectDeny(fx, "Write", { file_path: path.join(fx.home, ".claude", "settings.json"), content: "{}" }, /single output file/);
  // Grep/Glob use `path` in both CLIs; a stray file_path on them is ignored.
  expectAllow(fx, "Grep", { pattern: "x", file_path: fx.runnerTemp });
});

test("path and file_path both present must agree", () => {
  expectAllow(fx, "Read", { path: "src/a.ts", file_path: "src/a.ts" });
  expectDeny(fx, "Read", { path: "src/a.ts", file_path: "/etc/hosts" }, /disagree/);
  expectDeny(fx, "Read", { path: "/etc/hosts", file_path: "src/a.ts" }, /disagree/);
  expectDeny(fx, "Write", { path: fx.outFile, file_path: path.join(fx.ws, "pwned.txt"), content: "x" }, /disagree/);
});

test("every decision is appended to PATH_GUARD_LOG when set, and logging never changes the decision", () => {
  const logPath = path.join(fx.runnerTemp, "path-guard.log");
  const env = { ...fx.env, PATH_GUARD_LOG: logPath };
  let r = run(fx, "Read", { path: "src/a.ts" }, { env });
  assert.strictEqual(r.code, 0);
  r = run(fx, "Read", { path: "/etc/hosts" }, { env });
  assert.strictEqual(r.code, 2);
  r = run(fx, "Bash", { command: "id" }, { env });
  assert.strictEqual(r.code, 2);
  r = run(fx, "Read", {}, { env, rawStdin: "not json" });
  assert.strictEqual(r.code, 2);
  const lines = fs.readFileSync(logPath, "utf8").split("\n");
  // Unparseable stdin has no tool name, so the last entry is a bare `deny<TAB>`.
  assert.deepStrictEqual(lines, ["allow\tRead", "deny\tRead", "deny\tBash", "deny\t", ""]);

  // An unwritable log (directory does not exist) must not turn an allow into a
  // deny or vice versa — the verify step, not the guard, notices a missing log.
  const badEnv = { ...fx.env, PATH_GUARD_LOG: path.join(fx.root, "no-such-dir", "guard.log") };
  r = run(fx, "Read", { path: "src/a.ts" }, { env: badEnv });
  assert.strictEqual(r.code, 0, r.stderr);
  r = run(fx, "Read", { path: "/etc/hosts" }, { env: badEnv });
  assert.strictEqual(r.code, 2);

  // No PATH_GUARD_LOG: nothing is written anywhere.
  fs.rmSync(logPath);
  run(fx, "Read", { path: "src/a.ts" });
  assert.ok(!fs.existsSync(logPath));
});

test("any tool other than Read/Grep/Glob/Write is denied, whatever its arguments", () => {
  // The hook matcher is `.*`, so these reach the guard. `[tools] enabled` is
  // the primary control removing them; this is the independent second one.
  expectDeny(fx, "Bash", { command: "cat .git/config" }, /not permitted/);
  expectDeny(fx, "Edit", { path: "src/a.ts", old_string: "a", new_string: "b" }, /not permitted/);
  expectDeny(fx, "WebFetch", { url: "https://example.com" }, /not permitted/);
  expectDeny(fx, "Agent", { prompt: "read .git/config" }, /not permitted/);
  expectDeny(fx, "ReadFile", { path: "src/a.ts" }, /not permitted/);
  expectDeny(fx, "read", { path: "src/a.ts" }, /not permitted/);
  expectDeny(fx, "", { path: "src/a.ts" }, /not permitted/);
  let r = run(fx, "Read", { path: "src/a.ts" }, { rawStdin: JSON.stringify({ tool_input: { path: "src/a.ts" } }) });
  assert.strictEqual(r.code, 2, "missing tool_name must be denied");
  assert.match(r.stderr, /not permitted/);
  r = run(fx, "Read", { path: "src/a.ts" }, { rawStdin: JSON.stringify({ toolName: "Read", toolInput: { path: "src/a.ts" } }) });
  assert.strictEqual(r.code, 2, "a camelCase payload (different hook contract) must be denied, not waved through");
});

test("tool_input that is not an object is denied for Read/Write and harmless for Grep/Glob", () => {
  let r = run(fx, "Read", null, { rawStdin: JSON.stringify({ tool_name: "Read", tool_input: "src/a.ts" }) });
  assert.strictEqual(r.code, 2);
  r = run(fx, "Write", null, { rawStdin: JSON.stringify({ tool_name: "Write", tool_input: [fx.outFile] }) });
  assert.strictEqual(r.code, 2);
  r = run(fx, "Grep", null, { rawStdin: JSON.stringify({ tool_name: "Grep", tool_input: "x" }) });
  assert.strictEqual(r.code, 0, "Grep with no usable arguments searches the workspace, which is allowed");
});

test("the guard requires nothing from the checkout: a hostile package.json and node_modules change nothing", () => {
  fs.writeFileSync(path.join(fx.ws, "package.json"), JSON.stringify({ type: "module", main: "evil.js" }));
  for (const m of ["fs", "path", "os", "node:fs"]) {
    fs.mkdirSync(path.join(fx.ws, "node_modules", m), { recursive: true });
    fs.writeFileSync(path.join(fx.ws, "node_modules", m, "index.js"), "console.error('HIJACKED'); process.exit(0);");
  }
  fs.writeFileSync(path.join(fx.ws, ".npmrc"), "script-shell=/bin/false\n");
  const r = run(fx, "Read", { path: "/etc/hosts" });
  assert.strictEqual(r.code, 2);
  assert.doesNotMatch(r.stderr, /HIJACKED/);
  assert.match(r.stderr, /outside the PR checkout/);
});

test("the script uses only node: builtins", () => {
  const src = fs.readFileSync(GUARD, "utf8");
  const requires = [...src.matchAll(/require\(['"]([^'"]+)['"]\)/g)].map((m) => m[1]);
  assert.ok(requires.length > 0);
  for (const r of requires) assert.match(r, /^node:/, `${r} is not a node: builtin`);
});
