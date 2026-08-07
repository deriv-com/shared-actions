#!/usr/bin/env node
// When the PR completing an openspec change is merged, archive that change.
// Shared across repos via deriv-com/shared-actions (composite action +
// reusable workflow).
//
// Detects which change(s) a merge touched from the diff, verifies every task
// in that change's tasks.md is checked, then runs `openspec archive --yes
// --json` (non-interactive). The calling workflow opens a follow-up PR with
// the result — it never pushes directly to a protected branch.
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

// Prefer GITHUB_WORKSPACE so this script works when shipped as a composite
// action (action files live under github.action_path, not the consumer repo).
const ROOT = process.env.GITHUB_WORKSPACE || path.join(__dirname, "..");

/**
 * Given a list of changed file paths (e.g. from `git diff --name-only`),
 * return the distinct openspec change names touched, excluding the archive
 * directory itself. Pure function — no I/O.
 */
// Change directory names are kebab-case (e.g. "loop-automation-glue") — this
// also guards against a path-traversal value (e.g. "..") ever being treated
// as a change name below, since it can never match this pattern.
const CHANGE_NAME_RE = /^[a-z0-9][a-z0-9-]*$/;

// Full 40-char hex git SHA. GitHub always provides base/head SHAs in this
// shape for a pull_request event, but validating the shape here is cheap
// defense-in-depth before shelling out to `git diff` with them.
const SHA_RE = /^[0-9a-f]{40}$/i;

/** True when `value` is a well-formed 40-char hex git SHA. Pure function. */
function isValidSha(value) {
  return typeof value === "string" && SHA_RE.test(value);
}

function extractChangeNames(files) {
  const names = [];
  for (const f of files) {
    const match = f.match(/^openspec\/changes\/([^/]+)\//);
    const name = match && match[1];
    if (
      name &&
      name !== "archive" &&
      CHANGE_NAME_RE.test(name) &&
      !names.includes(name)
    ) {
      names.push(name);
    }
  }
  return names;
}

/**
 * True when a tasks.md body has no remaining `- [ ]` items, including nested
 * sub-tasks indented under a parent item (valid GitHub Markdown). Pure
 * function.
 */
function isTasksComplete(tasksMdContent) {
  return !/^\s*-\s\[\s\]/m.test(tasksMdContent);
}

function gitDiffNames(base, head) {
  const raw = execFileSync("git", ["diff", "--name-only", `${base}..${head}`], {
    encoding: "utf8",
  });
  return raw.split("\n").filter(Boolean);
}

function runOpenspecArchive(changeName) {
  try {
    const raw = execFileSync(
      "openspec",
      ["archive", changeName, "--yes", "--json"],
      {
        encoding: "utf8",
        cwd: ROOT,
      }
    );
    return JSON.parse(raw);
  } catch (err) {
    // openspec exits non-zero on failure but still prints JSON to stdout.
    const stdout = err.stdout ? err.stdout.toString() : "";
    try {
      return JSON.parse(stdout);
    } catch (_parseErr) {
      throw err;
    }
  }
}

function main() {
  const base = process.env.BASE_SHA;
  const head = process.env.HEAD_SHA;
  if (!base || !head) {
    console.error("BASE_SHA and HEAD_SHA env vars are required.");
    process.exit(1);
  }
  if (!isValidSha(base) || !isValidSha(head)) {
    console.error(
      `BASE_SHA and HEAD_SHA must be 40-char hex SHAs (got '${base}', '${head}').`
    );
    process.exit(1);
  }

  const changedFiles = gitDiffNames(base, head);
  const candidates = extractChangeNames(changedFiles);

  if (candidates.length === 0) {
    console.log(
      "No openspec change directories touched by this merge. Nothing to archive."
    );
    return;
  }

  const archived = [];
  for (const name of candidates) {
    // Fault-isolated per candidate: an unexpected failure archiving one
    // change (e.g. a merge that touches two changes at once) must not lose
    // the result of another candidate that already succeeded in this run.
    try {
      const tasksPath = path.join(
        ROOT,
        "openspec",
        "changes",
        name,
        "tasks.md"
      );
      if (!fs.existsSync(tasksPath)) {
        console.log(
          `'${name}' has no tasks.md — skipping (nothing to verify completion against).`
        );
        continue;
      }
      const content = fs.readFileSync(tasksPath, "utf8");
      if (!isTasksComplete(content)) {
        console.log(
          `'${name}' still has incomplete tasks — not archiving yet.`
        );
        continue;
      }

      console.log(`'${name}' is complete — archiving...`);
      const result = runOpenspecArchive(name);
      if (!result.archive) {
        const messages = (result.status || []).map((s) => s.message).join("; ");
        console.log(
          `openspec archive failed for '${name}': ${messages || "unknown error"}`
        );
        continue;
      }
      console.log(`Archived '${name}' -> ${result.archive.archivedAs}`);
      archived.push(result.archive);
    } catch (err) {
      console.log(
        `Unexpected error archiving '${name}': ${err.message}. Skipping.`
      );
    }
  }

  if (process.env.GITHUB_OUTPUT) {
    // `a.change` comes from openspec's own JSON response, not from our
    // validated `name` input — re-validate against the same kebab-case
    // allowlist before writing it to the GITHUB_OUTPUT file, so a malformed
    // value (e.g. containing a newline) can't inject extra output keys.
    const safeChanges = archived
      .map((a) => a.change)
      .filter((c) => CHANGE_NAME_RE.test(c))
      .join(",");
    fs.appendFileSync(
      process.env.GITHUB_OUTPUT,
      `archived=${archived.length > 0}\nchanges=${safeChanges}\n`
    );
  }
}

module.exports = {
  extractChangeNames,
  isTasksComplete,
  isValidSha,
  gitDiffNames,
  runOpenspecArchive,
  main,
};

if (require.main === module) {
  try {
    main();
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}
