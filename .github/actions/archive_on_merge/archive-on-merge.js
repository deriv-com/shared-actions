#!/usr/bin/env node
// When the PR completing an openspec change is merged, archive that change.
// Shared across repos via deriv-com/shared-actions (composite action +
// reusable workflow).
//
// Detects which change(s) the merged PR itself touched, verifies every task in
// that change's tasks.md is checked, then runs `openspec archive --yes --json`
// (non-interactive). The calling workflow opens a follow-up PR with the result
// — it never pushes directly to a protected branch.
//
// The touched-file list comes from the GitHub API rather than a local `git
// diff`. A diff of `base.sha..merge_commit_sha` is NOT the PR's own diff: for
// a PR opened against an older master it also contains every commit merged in
// between, so an unrelated PR merged after some other PR completed a change
// would "touch" that change too and archive it a second time. Asking the API
// for the PR's files is exact and, unlike any local range, is independent of
// whether the PR was merged, squashed, or rebased.
//
// Requires Node.js 18 or newer for global `fetch`.
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const { setTimeout: sleep } = require("timers/promises");

// Prefer GITHUB_WORKSPACE so this script works when shipped as a composite
// action (action files live under github.action_path, not the consumer repo).
// Fallback: three levels up from .github/actions/archive_on_merge → repo root.
const ROOT =
  process.env.GITHUB_WORKSPACE || path.join(__dirname, "..", "..", "..");

/**
 * Given a list of changed file paths (e.g. the filenames of a PR's files),
 * return the distinct openspec change names touched, excluding the archive
 * directory itself. Pure function — no I/O.
 */
// Change directory names are kebab-case (e.g. "loop-automation-glue") — this
// also guards against a path-traversal value (e.g. "..") ever being treated
// as a change name below, since it can never match this pattern.
const CHANGE_NAME_RE = /^[a-z0-9][a-z0-9-]*$/;

// GitHub returns at most 100 files per page and caps the endpoint at 3000
// files, so 30 pages is a complete read and also a runaway-loop backstop.
const FILES_PER_PAGE = 100;
const MAX_FILE_PAGES = 30;

// Retry only what a retry can fix: 5xx, 429, and the rate-limit flavour of 403
// (see isRetryableResponse). A 404, or a 403 about permissions, is a real
// answer and failing immediately on it keeps the log readable.
const MAX_ATTEMPTS = 3;
const RETRY_BASE_MS = 1000;
// Per-attempt ceiling. Node's fetch does not hang forever without one, but its
// default headers timeout is 300s, so three attempts of that would outlast the
// calling job's timeout-minutes and surface as an opaque job kill rather than a
// failed request.
const REQUEST_TIMEOUT_MS = 30_000;

/** True when `value` is a positive integer PR number. Pure function. */
function isValidPrNumber(value) {
  return /^[1-9][0-9]*$/.test(String(value ?? ""));
}

/** True when `value` is an `owner/repo` slug. Pure function. */
function isValidRepo(value) {
  const slug = String(value ?? "");
  if (!/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(slug)) {
    return false;
  }
  // The character class above still admits "." and ".." as whole segments,
  // which `fetch` would resolve away and silently retarget the request at a
  // different API path.
  return slug.split("/").every((segment) => segment !== "." && segment !== "..");
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
  // Sorted so the caller's branch slug is canonical: the same set of changes
  // must produce the same branch name whatever order the API listed the files
  // in, or the open-PR dedupe silently misses.
  return names.sort();
}

/**
 * True when a tasks.md body has no remaining `- [ ]` items, including nested
 * sub-tasks indented under a parent item (valid GitHub Markdown). Pure
 * function.
 */
function isTasksComplete(tasksMdContent) {
  return !/^\s*-\s\[\s\]/m.test(tasksMdContent);
}

/**
 * True when a response is worth retrying. Pure function.
 *
 * GitHub signals both primary and secondary rate limits with 403, and losing a
 * call permanently loses the archive — `pull_request: closed` never fires again
 * for that merge. But 403 is also how a token missing `pull-requests: read` is
 * refused, and retrying that three times buries the real cause. The rate-limit
 * headers separate the two.
 */
function isRetryableResponse(response) {
  if (response.status >= 500 || response.status === 429) {
    return true;
  }
  if (response.status !== 403) {
    return false;
  }
  return (
    response.headers.get("retry-after") !== null ||
    response.headers.get("x-ratelimit-remaining") === "0"
  );
}

/**
 * `fetch` with a per-attempt timeout and bounded retries on transient failures
 * (network error, timeout, 5xx, 429, rate-limit 403). Detection used to be an
 * offline `git diff`; over the network a single blip would otherwise fail the
 * job, and `pull_request: closed` never fires again for that merge.
 */
async function fetchWithRetry(
  url,
  options,
  {
    attempts = MAX_ATTEMPTS,
    baseDelayMs = RETRY_BASE_MS,
    timeoutMs = REQUEST_TIMEOUT_MS,
  } = {}
) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      // A fresh signal per attempt: AbortSignal.timeout starts counting from
      // creation, so one hoisted out of the loop would abort every retry after
      // the first budget elapsed.
      const response = await fetch(url, {
        ...options,
        signal: options.signal ?? AbortSignal.timeout(timeoutMs),
      });
      if (!isRetryableResponse(response)) {
        return response;
      }
      lastError = new Error(
        `GitHub API returned ${response.status} ${response.statusText}`
      );
    } catch (err) {
      lastError = new Error(
        err.name === "TimeoutError"
          ? `request timed out after ${timeoutMs}ms`
          : `request failed: ${err.message}`
      );
    }
    if (attempt < attempts) {
      const delay = baseDelayMs * 2 ** (attempt - 1);
      console.log(
        `Attempt ${attempt}/${attempts} failed (${lastError.message}) — retrying in ${delay}ms.`
      );
      await sleep(delay);
    }
  }
  throw lastError;
}

/**
 * Every path the pull request itself changed, via the GitHub API. Renames
 * report both their new and previous path, so a file moved out of a change
 * directory still counts as touching that change.
 */
async function fetchPullRequestFiles({
  apiUrl,
  repo,
  prNumber,
  token,
  retry = {},
}) {
  const files = [];
  for (let page = 1; page <= MAX_FILE_PAGES; page += 1) {
    const url =
      `${apiUrl}/repos/${repo}/pulls/${prNumber}/files` +
      `?per_page=${FILES_PER_PAGE}&page=${page}`;
    const response = await fetchWithRetry(
      url,
      {
        headers: {
          accept: "application/vnd.github+json",
          authorization: `Bearer ${token}`,
          "x-github-api-version": "2022-11-28",
          "user-agent": "deriv-com/shared-actions archive_on_merge",
        },
      },
      retry
    );
    if (!response.ok) {
      throw new Error(
        `GitHub API returned ${response.status} ${response.statusText} for ${repo} PR #${prNumber} files.`
      );
    }
    const batch = await response.json();
    if (!Array.isArray(batch)) {
      throw new Error(
        `Expected an array of files from the GitHub API, got ${typeof batch}.`
      );
    }
    for (const file of batch) {
      if (file && typeof file.filename === "string") {
        files.push(file.filename);
      }
      if (file && typeof file.previous_filename === "string") {
        files.push(file.previous_filename);
      }
    }
    if (batch.length < FILES_PER_PAGE) {
      return files;
    }
  }
  // Hitting the endpoint's own 3000-file ceiling. Say so rather than treating
  // a truncated list as the whole PR — an openspec directory could be missing
  // from it, and the run would report "nothing to archive" with no clue why.
  console.log(
    `::warning::PR #${prNumber} has more files than the GitHub API will list ` +
      `(${MAX_FILE_PAGES * FILES_PER_PAGE}); the file list is truncated and a ` +
      `completed openspec change may not be detected.`
  );
  return files;
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

/**
 * Write composite/workflow step outputs. Always emits `archived` (true/false)
 * so callers can branch on either value, including the no-candidates path.
 */
function writeOutputs(archived) {
  if (!process.env.GITHUB_OUTPUT) {
    return;
  }
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

async function main() {
  const prNumber = process.env.PR_NUMBER;
  // TARGET_REPOSITORY rather than overriding GITHUB_REPOSITORY: the GITHUB_
  // prefix is reserved, and reassigning a default runner variable from a
  // step's `env:` is not documented as supported.
  const repo = process.env.TARGET_REPOSITORY || process.env.GITHUB_REPOSITORY;
  const token = process.env.GITHUB_TOKEN;
  const apiUrl = process.env.GITHUB_API_URL || "https://api.github.com";

  if (typeof fetch !== "function") {
    console.error(
      "Global fetch is unavailable — this action requires Node.js 18 or newer. " +
        `Running on ${process.version}; raise the workflow's node_version input.`
    );
    process.exit(1);
  }
  if (!isValidPrNumber(prNumber)) {
    console.error(`PR_NUMBER must be a positive integer (got '${prNumber}').`);
    process.exit(1);
  }
  if (!isValidRepo(repo)) {
    console.error(
      `Repository must be an 'owner/repo' slug (got '${repo}'). Set TARGET_REPOSITORY or run inside Actions.`
    );
    process.exit(1);
  }
  if (!token) {
    console.error("GITHUB_TOKEN env var is required to read the PR's files.");
    process.exit(1);
  }

  const changedFiles = await fetchPullRequestFiles({
    apiUrl,
    repo,
    prNumber,
    token,
  });
  const candidates = extractChangeNames(changedFiles);

  if (candidates.length === 0) {
    console.log(
      `PR #${prNumber} touched no openspec change directories. Nothing to archive.`
    );
    writeOutputs([]);
    return;
  }

  const archived = [];
  let archiveFailures = 0;
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
        archiveFailures += 1;
        continue;
      }
      console.log(`Archived '${name}' -> ${result.archive.archivedAs}`);
      archived.push(result.archive);
    } catch (err) {
      console.log(
        `Unexpected error archiving '${name}': ${err.message}. Skipping.`
      );
      archiveFailures += 1;
    }
  }

  writeOutputs(archived);

  // Soft-skip (incomplete / no tasks.md) is success. But if every attempt to
  // archive a completed change failed, exit non-zero so CI does not go green
  // while leaving finished changes unarchived.
  if (archived.length === 0 && archiveFailures > 0) {
    console.error(
      `Failed to archive ${archiveFailures} completed change(s); see logs above.`
    );
    process.exit(1);
  }
}

module.exports = {
  extractChangeNames,
  isTasksComplete,
  isValidPrNumber,
  isValidRepo,
  isRetryableResponse,
  fetchWithRetry,
  fetchPullRequestFiles,
  runOpenspecArchive,
  writeOutputs,
  main,
  MAX_FILE_PAGES,
  FILES_PER_PAGE,
};

if (require.main === module) {
  main().catch((err) => {
    console.error(err.message);
    process.exit(1);
  });
}
