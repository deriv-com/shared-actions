// Run with: node --test .github/actions/docsync_guidance_file/resolve-guidance-file.test.js
//
// No package.json and no dependencies on purpose — this repo ships workflows,
// not a Node package, so the tests use the runner built into Node 18+.
const test = require("node:test");
const assert = require("node:assert");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const {
  isSafeRelativePath,
  parseImportShim,
  resolveGuidanceFile,
} = require("./resolve-guidance-file.js");

/** Make a throwaway repo root holding `files` ({ path: content }). */
function repo(t, files = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "guidance-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), content);
  }
  return root;
}

test("parseImportShim recognises an import-only file", () => {
  assert.deepStrictEqual(parseImportShim("@AGENTS.md\n"), ["AGENTS.md"]);
  assert.deepStrictEqual(parseImportShim("﻿\r\n  @AGENTS.md  \r\n\r\n"), ["AGENTS.md"]);
  assert.deepStrictEqual(parseImportShim("@AGENTS.md\n@docs/more.md\n"), ["AGENTS.md", "docs/more.md"]);
});

test("parseImportShim rejects files with any other content", () => {
  assert.strictEqual(parseImportShim(""), null);
  assert.strictEqual(parseImportShim("\n\n"), null);
  assert.strictEqual(parseImportShim("# Project\n@AGENTS.md\n"), null);
  assert.strictEqual(parseImportShim("See @AGENTS.md\n"), null);
});

test("isSafeRelativePath only accepts repo-relative Markdown paths", () => {
  assert.ok(isSafeRelativePath("AGENTS.md"));
  assert.ok(isSafeRelativePath("docs/agent-reference.md"));
  assert.ok(!isSafeRelativePath("/etc/AGENTS.md"));
  assert.ok(!isSafeRelativePath("../AGENTS.md"));
  assert.ok(!isSafeRelativePath("docs/../../AGENTS.md"));
  assert.ok(!isSafeRelativePath("AGENTS.txt"));
  assert.ok(!isSafeRelativePath("AGENTS.md\nfile=x.md"));
  assert.ok(!isSafeRelativePath("$(id).md"));
});

test("a full CLAUDE.md stays the target (unchanged behaviour)", (t) => {
  const root = repo(t, { "CLAUDE.md": "# Project\n\n- Run `npm test`\n@docs/extra.md\n" });
  assert.deepStrictEqual(resolveGuidanceFile({ root }), {
    file: "CLAUDE.md",
    source: "claude",
    reason: "CLAUDE.md holds the guidance itself",
  });
});

test("CLAUDE.md is found case-insensitively, keeping its casing", (t) => {
  const root = repo(t, { "Claude.md": "# Project\n" });
  assert.strictEqual(resolveGuidanceFile({ root }).file, "Claude.md");
});

test("no CLAUDE.md and no input means no guidance target", (t) => {
  const root = repo(t, { "AGENTS.md": "# Project\n", "README.md": "# Readme\n" });
  const result = resolveGuidanceFile({ root });
  assert.strictEqual(result.file, "");
  assert.strictEqual(result.source, "none");
});

test("an @AGENTS.md shim resolves to AGENTS.md", (t) => {
  const root = repo(t, { "CLAUDE.md": "@AGENTS.md\n", "AGENTS.md": "# Project\n" });
  assert.deepStrictEqual(resolveGuidanceFile({ root }), {
    file: "AGENTS.md",
    source: "import",
    reason: "CLAUDE.md only imports AGENTS.md",
  });
});

test("a ./-prefixed or nested import resolves inside the repo", (t) => {
  const root = repo(t, { "CLAUDE.md": "@./docs/guide.md\n", "docs/guide.md": "# Guide\n" });
  assert.strictEqual(resolveGuidanceFile({ root }).file, "docs/guide.md");
});

test("a shim never falls back to writing CLAUDE.md", (t) => {
  const cases = {
    missing: { "CLAUDE.md": "@AGENTS.md\n" },
    outside: { "CLAUDE.md": "@../AGENTS.md\n" },
    home: { "CLAUDE.md": "@~/.claude/AGENTS.md\n" },
    notMarkdown: { "CLAUDE.md": "@AGENTS.txt\n", "AGENTS.txt": "x" },
    ambiguous: { "CLAUDE.md": "@AGENTS.md\n@OTHER.md\n", "AGENTS.md": "a", "OTHER.md": "b" },
    self: { "CLAUDE.md": "@CLAUDE.md\n" },
  };
  for (const [name, files] of Object.entries(cases)) {
    const result = resolveGuidanceFile({ root: repo(t, files) });
    assert.strictEqual(result.file, "", name);
    assert.strictEqual(result.source, "none", name);
  }
});

test("a CLAUDE.md symlink resolves to its target", (t) => {
  const root = repo(t, { "AGENTS.md": "# Project\n" });
  fs.symlinkSync("AGENTS.md", path.join(root, "CLAUDE.md"));
  assert.deepStrictEqual(resolveGuidanceFile({ root }), {
    file: "AGENTS.md",
    source: "symlink",
    reason: "CLAUDE.md is a symlink to AGENTS.md",
  });
});

test("a CLAUDE.md symlink out of the repo, or dangling, has no target", (t) => {
  const outside = repo(t, { "AGENTS.md": "# Elsewhere\n" });
  const escaping = repo(t);
  fs.symlinkSync(path.join(outside, "AGENTS.md"), path.join(escaping, "CLAUDE.md"));
  assert.strictEqual(resolveGuidanceFile({ root: escaping }).source, "none");

  const dangling = repo(t);
  fs.symlinkSync("AGENTS.md", path.join(dangling, "CLAUDE.md"));
  assert.strictEqual(resolveGuidanceFile({ root: dangling }).source, "none");
});

test("the guidance_file input overrides detection", (t) => {
  const root = repo(t, { "CLAUDE.md": "# Full\n", "AGENTS.md": "# Project\n" });
  assert.deepStrictEqual(resolveGuidanceFile({ root, override: " AGENTS.md " }), {
    file: "AGENTS.md",
    source: "input",
    reason: "set by the guidance_file input",
  });
});

test("the guidance_file input is never created, escaped or a shim", (t) => {
  const root = repo(t, { "CLAUDE.md": "@AGENTS.md\n", "AGENTS.md": "# Project\n" });
  fs.symlinkSync("AGENTS.md", path.join(root, "LINK.md"));
  for (const override of ["MISSING.md", "../AGENTS.md", "/AGENTS.md", "LINK.md", "CLAUDE.md"]) {
    const result = resolveGuidanceFile({ root, override });
    assert.strictEqual(result.file, "", override);
    assert.strictEqual(result.source, "none", override);
  }
});

test("the CLI writes single-line outputs to GITHUB_OUTPUT", (t) => {
  const root = repo(t, { "CLAUDE.md": "@AGENTS.md\n", "AGENTS.md": "# Project\n" });
  const output = path.join(root, "github_output");
  execFileSync(process.execPath, [path.join(__dirname, "resolve-guidance-file.js")], {
    cwd: root,
    env: { ...process.env, GITHUB_OUTPUT: output, GITHUB_STEP_SUMMARY: "", GUIDANCE_FILE_INPUT: "" },
  });
  assert.strictEqual(
    fs.readFileSync(output, "utf8"),
    "file=AGENTS.md\nsource=import\nreason=CLAUDE.md only imports AGENTS.md\n"
  );
});
