#!/usr/bin/env node
// Decide which file DocSync AI should edit for AI-agent guidance.
//
// DocSync used to write root CLAUDE.md unconditionally. Repos that keep their
// guidance in AGENTS.md turn CLAUDE.md into an import shim — a file whose only
// content is `@AGENTS.md` — or a symlink to it. Appending notes under that
// import line breaks the shim (and any CI that pins its content), so:
//
//   - `guidance_file` input set      → that file, if it exists and is not a shim
//   - CLAUDE.md is a symlink         → the file it points to, inside the repo
//   - CLAUDE.md is only one @import  → the imported file, inside the repo
//   - CLAUDE.md is anything else     → CLAUDE.md (unchanged behaviour)
//   - no CLAUDE.md                   → nothing (unchanged behaviour)
//
// Never creates a file, never returns a symlink, never returns a path outside
// the repository root. Writes `file`, `source` and `reason` to GITHUB_OUTPUT.
//
// No dependencies; runs on the Node preinstalled on GitHub-hosted runners.
const fs = require("fs");
const path = require("path");

// Repo-relative Markdown path: no leading slash, no `..` segment, no shell or
// GITHUB_OUTPUT metacharacters (the value is echoed into both).
const SAFE_PATH_RE = /^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9._\/-]+\.md$/i;
const IMPORT_LINE_RE = /^@(\S+)$/;

function isSafeRelativePath(p) {
  return typeof p === "string" && SAFE_PATH_RE.test(p);
}

/**
 * Return the import targets when every non-blank line of `content` is an
 * `@path` import, otherwise null. An empty file is not a shim. Pure function.
 */
function parseImportShim(content) {
  const lines = String(content)
    .replace(/^﻿/, "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  if (lines.length === 0) return null;
  const imports = [];
  for (const line of lines) {
    const match = IMPORT_LINE_RE.exec(line);
    if (!match) return null;
    imports.push(match[1]);
  }
  return imports;
}

/** Case-insensitive lookup of a root-level CLAUDE.md, like `find -iname`. */
function findClaudeMd(root) {
  return (
    fs.readdirSync(root).find((name) => name.toLowerCase() === "claude.md") ||
    null
  );
}

/**
 * Resolve `rel` against `root` and return its canonical repo-relative path
 * when it is a regular, non-symlink Markdown file inside the repository.
 * Returns null otherwise.
 */
function regularFileInRepo(root, rel) {
  const normalized = rel.replace(/^\.\//, "");
  if (!isSafeRelativePath(normalized)) return null;
  const abs = path.join(root, normalized);
  let stat;
  try {
    stat = fs.lstatSync(abs);
  } catch {
    return null;
  }
  if (!stat.isFile()) return null;
  const realRoot = fs.realpathSync(root);
  const real = fs.realpathSync(abs);
  if (!real.startsWith(realRoot + path.sep)) return null;
  return path.relative(realRoot, real).split(path.sep).join("/");
}

function none(reason) {
  return { file: "", source: "none", reason };
}

function fromShim(root, shimName, imports) {
  if (imports.length !== 1) {
    return none(`${shimName} imports ${imports.length} files; not choosing one`);
  }
  const target = regularFileInRepo(root, imports[0]);
  if (!target) {
    return none(`${shimName} imports ${imports[0]}, which is not a Markdown file in the repository`);
  }
  if (target.toLowerCase() === shimName.toLowerCase()) {
    return none(`${shimName} imports itself`);
  }
  if (parseImportShim(fs.readFileSync(path.join(root, target), "utf8"))) {
    return none(`${shimName} imports ${target}, which is itself an import shim; point guidance_file at the final file`);
  }
  return {
    file: target,
    source: "import",
    reason: `${shimName} only imports ${target}`,
  };
}

/** Pure decision over the filesystem under `root`. See the header comment. */
function resolveGuidanceFile({ root, override = "" }) {
  const requested = String(override || "").trim();

  if (requested) {
    const file = regularFileInRepo(root, requested);
    if (!file) {
      return none(`guidance_file ${requested} is not an existing Markdown file in the repository`);
    }
    if (parseImportShim(fs.readFileSync(path.join(root, file), "utf8"))) {
      return none(`guidance_file ${file} is an import shim; point guidance_file at the imported file`);
    }
    return { file, source: "input", reason: "set by the guidance_file input" };
  }

  const claudeName = findClaudeMd(root);
  if (!claudeName) return none("no CLAUDE.md in the repository root");

  const claudePath = path.join(root, claudeName);
  if (fs.lstatSync(claudePath).isSymbolicLink()) {
    let target = null;
    try {
      target = regularFileInRepo(root, path.relative(fs.realpathSync(root), fs.realpathSync(claudePath)));
    } catch {
      target = null;
    }
    if (!target) {
      return none(`${claudeName} is a symlink to something other than a Markdown file in the repository`);
    }
    if (parseImportShim(fs.readFileSync(path.join(root, target), "utf8"))) {
      return none(`${claudeName} is a symlink to ${target}, which is itself an import shim; point guidance_file at the final file`);
    }
    return { file: target, source: "symlink", reason: `${claudeName} is a symlink to ${target}` };
  }

  if (!fs.lstatSync(claudePath).isFile()) {
    return none(`${claudeName} is not a regular file`);
  }

  const imports = parseImportShim(fs.readFileSync(claudePath, "utf8"));
  if (imports) return fromShim(root, claudeName, imports);

  return { file: claudeName, source: "claude", reason: `${claudeName} holds the guidance itself` };
}

function main() {
  const result = resolveGuidanceFile({
    root: process.cwd(),
    override: process.env.GUIDANCE_FILE_INPUT || "",
  });
  const lines = [
    `file=${result.file}`,
    `source=${result.source}`,
    // Reasons can quote user input; keep GITHUB_OUTPUT single-line.
    `reason=${result.reason.replace(/[\r\n]+/g, " ")}`,
  ];
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, lines.join("\n") + "\n");
  }
  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(
      process.env.GITHUB_STEP_SUMMARY,
      `### Agent guidance file\n- File: ${result.file || "(none)"}\n- Why: ${result.reason}\n`
    );
  }
  console.log(lines.join("\n"));
}

if (require.main === module) main();

module.exports = {
  isSafeRelativePath,
  parseImportShim,
  regularFileInRepo,
  resolveGuidanceFile,
};
