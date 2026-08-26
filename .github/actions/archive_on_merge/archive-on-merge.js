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

// A `- [ ]` / `- [x]` item, including nested sub-tasks indented under a parent
// (valid GitHub Markdown). The trailing `$` means every line handed to this
// must already have its line terminator stripped — see LINE_SPLIT_RE.
const TASK_RE = /^\s*-\s\[([\sxX])\]\s*(.*)$/;
const HEADING_RE = /^#{1,6}\s+(.*)$/;

// Split on every terminator a Markdown file can carry, not just "\n". A CRLF
// file split on "\n" alone leaves a trailing "\r" on every line, and since `.`
// never matches "\r" and `$` (no `m` flag) only matches end-of-string, TASK_RE
// would fail on every row: a file full of unchecked boxes would parse as zero
// tasks and read as COMPLETE. CR-only and U+2028/9 files fail the same way.
const LINE_SPLIT_RE = /\r\n|\r|\n|\u2028|\u2029/;

// Fenced blocks are skipped: a tasks.md commonly shows shell snippets whose
// `# comment` lines match HEADING_RE and whose sample `- [ ]` rows are not
// real tasks. A simple toggle (rather than tracking fence length) is enough
// for the ``` / ~~~ blocks these files actually use.
const FENCE_RE = /^\s*(?:```|~~~)/;

// An explicit, unambiguous opt-in authors can put in a heading. Preferred over
// the phrase heuristic below, which cannot read intent.
const POST_MERGE_MARKER_RE = /\[post[-\s]?merge\]/i;

// Phrase fallback, anchored to the START of the heading (after any "6."
// numbering) so the phrase has to be the section's subject. Unanchored, this
// matched "Pre-merge checks (do these before, not after merging)" and told the
// author the exact opposite of the truth; it also matched "Compost-merge".
const POST_MERGE_SECTION_RE =
  /^(?:\d+[.)]?\s*)*(?:post[-\s]?(?:merge|release|deploy(?:ment)?)|after[-\s](?:the[-\s])?(?:merge|merging|deploy(?:ment)?|release)|once[-\s]merged)\b/i;

// Enough of a task to recognise it in a log line without reflowing the file.
const TASK_TEXT_MAX = 100;

/**
 * Truncate to a code-point budget. `slice` cuts at UTF-16 code units, so a task
 * with an emoji straddling the limit lost half a surrogate pair and rendered as
 * U+FFFD. Pure function.
 */
function truncate(text, max = TASK_TEXT_MAX) {
  const points = Array.from(text);
  return points.length > max
    ? `${points.slice(0, max - 1).join("")}…`
    : text;
}

/**
 * Parse a tasks.md body into a census of its checkboxes. Pure function.
 *
 * Returns `{ total, checked, incomplete }`, where each incomplete entry carries
 * the 1-based `line` it sits on, the nearest preceding `section` heading, and
 * the task `text` (truncated). Sections let the caller show *where* the work
 * remains, which is the difference between "two boxes left in Verify" and "a
 * whole post-merge acceptance section that can never be checked here".
 */
function parseTasks(tasksMdContent) {
  const lines = String(tasksMdContent ?? "").split(LINE_SPLIT_RE);
  const incomplete = [];
  let total = 0;
  let checked = 0;
  let section = null;
  let inFence = false;

  lines.forEach((line, index) => {
    if (FENCE_RE.test(line)) {
      inFence = !inFence;
      return;
    }
    if (inFence) {
      return;
    }
    const heading = line.match(HEADING_RE);
    if (heading) {
      section = heading[1].trim();
      return;
    }
    const task = line.match(TASK_RE);
    if (!task) {
      return;
    }
    total += 1;
    if (task[1] === "x" || task[1] === "X") {
      checked += 1;
      return;
    }
    incomplete.push({
      line: index + 1,
      section,
      text: truncate(task[2].trim()),
    });
  });

  return { total, checked, incomplete };
}

/**
 * The remaining tasks a merge-triggered run can never see checked. Single
 * source of truth: both renderers call this, so the log and the job summary
 * cannot classify a section differently. Pure function.
 */
function postMergeTasks(incomplete) {
  return incomplete.filter(
    (t) =>
      t.section &&
      (POST_MERGE_MARKER_RE.test(t.section) ||
        POST_MERGE_SECTION_RE.test(t.section))
  );
}

/**
 * The one wording of the post-merge caveat, shared by both renderers so a
 * future edit cannot land in one and not the other. Null when it does not
 * apply. Pure function.
 */
function postMergeNoteText(incomplete) {
  const postMerge = postMergeTasks(incomplete);
  if (postMerge.length === 0) {
    return null;
  }
  return (
    `${postMerge.length} of the ${incomplete.length} remaining task(s) sit in a section marked ` +
    "post-merge, which a merge-triggered run can never see checked. This change will not archive " +
    "automatically until those items are checked in a later commit, or moved out of the change's tasks.md."
  );
}

/**
 * True when a tasks.md body has no remaining `- [ ]` items. Delegates to
 * parseTasks so the completeness check and the reported detail can never
 * disagree. Pure function.
 *
 * main() reads the census directly, since it needs the breakdown anyway; this
 * stays as the module's semantic predicate for callers and tests.
 */
function isTasksComplete(tasksMdContent) {
  return parseTasks(tasksMdContent).incomplete.length === 0;
}

/**
 * Group incomplete tasks by their section, preserving file order. Pure
 * function.
 */
function groupBySection(incomplete) {
  const groups = [];
  for (const task of incomplete) {
    const label = task.section || "(no section)";
    const last = groups[groups.length - 1];
    if (last && last.section === label) {
      last.tasks.push(task);
    } else {
      groups.push({ section: label, tasks: [task] });
    }
  }
  return groups;
}

/**
 * Human-readable report of what is still unchecked, for the plain-text log.
 * Pure function.
 *
 * Deliberately cites `tasks.md:<line>` rather than a full blob URL: change
 * names run to ~90 characters, so a URL per row buries the task text it is
 * meant to annotate. The clickable form lives in the job summary, where
 * markdown renders it as a short link.
 */
function formatIncompleteReport(changeName, census) {
  const { total, checked, incomplete } = census;
  const lines = [
    `'${changeName}' is not complete: ${checked}/${total} tasks checked, ${incomplete.length} remaining.`,
  ];
  for (const group of groupBySection(incomplete)) {
    lines.push(`  ${group.section}`);
    for (const task of group.tasks) {
      lines.push(`    - [ ] ${task.text}  (tasks.md:${task.line})`);
    }
  }
  const note = postMergeNoteText(incomplete);
  if (note) {
    lines.push(`  Note: ${note}`);
  }
  return lines.join("\n");
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

/** owner/repo from an https or ssh git remote URL, or null. Pure function. */
function repoSlugFromRemote(remoteUrl) {
  const match = String(remoteUrl ?? "")
    .trim()
    .match(/[/:]([^/:]+\/[^/]+?)(?:\.git)?$/);
  return match ? match[1] : null;
}

// HEAD does not move during a run, so resolve it once. `undefined` = not yet
// looked up, `null` = unavailable.
let cachedHeadSha;

function checkoutHeadSha() {
  if (cachedHeadSha !== undefined) {
    return cachedHeadSha;
  }
  cachedHeadSha = null;
  try {
    const sha = execFileSync("git", ["rev-parse", "HEAD"], {
      encoding: "utf8",
      cwd: ROOT,
    }).trim();
    if (/^[0-9a-f]{40}$/.test(sha)) {
      cachedHeadSha = sha;
    }
  } catch (_err) {
    // Not a git checkout, or git unavailable. A link is a convenience.
  }
  return cachedHeadSha;
}

/**
 * Blob URL for the checked-out tasks.md, so reported line numbers are clickable
 * and point at the exact content that was read. Returns null if anything is
 * unavailable or inconsistent — a link is a convenience, never a reason to fail
 * the run.
 *
 * The slug and the SHA must come from the same repository. A composite-action
 * caller can pass `repository: owner/other-repo` while the workspace holds a
 * different checkout; pairing that slug with this workspace's SHA yields a URL
 * that 404s (or worse, resolves to unrelated content) while being presented as
 * "the exact content that was read". Mismatch means no link.
 */
function tasksFileUrl(changeName) {
  const server = process.env.GITHUB_SERVER_URL || "https://github.com";
  const repo = process.env.TARGET_REPOSITORY || process.env.GITHUB_REPOSITORY;
  if (!repo || !isValidRepo(repo)) {
    return null;
  }
  const sha = checkoutHeadSha();
  if (!sha) {
    return null;
  }
  try {
    const remote = execFileSync("git", ["remote", "get-url", "origin"], {
      encoding: "utf8",
      cwd: ROOT,
    });
    const slug = repoSlugFromRemote(remote);
    if (slug && slug.toLowerCase() !== repo.toLowerCase()) {
      console.log(
        `Not linking tasks.md: the checkout is '${slug}' but the reported repository is '${repo}'.`
      );
      return null;
    }
  } catch (_err) {
    // No origin remote to cross-check against; fall through and link anyway.
  }
  return `${server}/${repo}/blob/${sha}/openspec/changes/${changeName}/tasks.md`;
}

/** Append markdown to the run's job summary, when running under Actions. */
function writeStepSummary(markdown) {
  if (!process.env.GITHUB_STEP_SUMMARY) {
    return;
  }
  try {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${markdown}\n`);
  } catch (err) {
    // A summary is reporting, not the job's purpose. Never fail the archive
    // because the summary file could not be written — but say so where someone
    // will see it. Annotations travel over the command stream on stdout, not
    // through the summary file, so this survives exactly the failure it
    // reports; a plain log line would hide a degraded channel in the log this
    // feature exists to stop people having to read.
    console.log(`::warning::Could not write the job summary: ${err.message}`);
  }
}

/**
 * Escape what would break out of a markdown table cell. Backslashes go first:
 * escaping only the pipe turns an author's literal `\|` into `\\|`, which GFM
 * reads as an escaped backslash followed by a LIVE delimiter — silently adding
 * a cell and shifting every column after it.
 */
function escapeCell(text) {
  return String(text)
    .replace(/\\/g, "\\\\")
    .replace(/\|/g, "\\|")
    .replace(/\r?\n/g, " ");
}

/**
 * The same census as formatIncompleteReport, as a markdown table for the job
 * summary. Pure function.
 */
function formatIncompleteSummary(changeName, census, { tasksUrl } = {}) {
  const { total, checked, incomplete } = census;
  const out = [
    `### Not archived: \`${changeName}\``,
    "",
    `**${checked} of ${total}** tasks checked — **${incomplete.length}** remaining.`,
    "",
    "| Section | Remaining task | Line |",
    "| --- | --- | --- |",
  ];
  for (const task of incomplete) {
    // `?plain=1` is required: GitHub renders a .md blob as formatted markdown,
    // where an #L anchor is ignored and the reader lands at the top of the
    // page. The plain view opens the source with the line selected.
    const line = tasksUrl
      ? `[${task.line}](${tasksUrl}?plain=1#L${task.line})`
      : String(task.line);
    out.push(
      `| ${escapeCell(task.section || "—")} | ${escapeCell(task.text)} | ${line} |`
    );
  }
  const note = postMergeNoteText(incomplete);
  if (note) {
    out.push("", `> ${note}`);
  }
  return out.join("\n");
}

/**
 * The one-line annotation for a declined archive. Pure function.
 *
 * A workflow command's property list is comma/colon delimited, so a stray `,`
 * or `::` from a later edit would silently stop the runner recognising it and
 * the annotation — the only channel visible on the run summary page without
 * opening the log — would just vanish from a green run. Built here rather than
 * inline so its shape is pinned by a test, like the other two channels.
 */
function formatSkipNotice(changeName, census) {
  return (
    `::notice title=openspec archive skipped::'${changeName}' has ` +
    `${census.incomplete.length} of ${census.total} tasks unchecked — not archived.`
  );
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
      const census = parseTasks(content);
      if (census.total === 0 && content.trim() !== "") {
        // A non-empty tasks.md that yields no checkboxes is far more likely a
        // parse failure than a deliberate prose-only file, and the archive that
        // follows would look deliberate. Say so loudly.
        console.log(
          `::warning title=No tasks parsed::'${name}' has a non-empty tasks.md but no '- [ ]' or '- [x]' items were parsed. Treating it as complete; check the file's line endings and formatting.`
        );
      }
      if (census.incomplete.length > 0) {
        // Only the job summary consumes the URL, and building it forks git.
        const tasksUrl = process.env.GITHUB_STEP_SUMMARY
          ? tasksFileUrl(name)
          : null;
        // Full breakdown in the log, a one-liner as an annotation (the log of a
        // green job is nobody's first stop), and a table in the job summary.
        console.log(formatIncompleteReport(name, census));
        console.log(formatSkipNotice(name, census));
        writeStepSummary(formatIncompleteSummary(name, census, { tasksUrl }));
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
  parseTasks,
  truncate,
  isTasksComplete,
  groupBySection,
  postMergeTasks,
  postMergeNoteText,
  repoSlugFromRemote,
  formatIncompleteReport,
  formatIncompleteSummary,
  formatSkipNotice,
  writeStepSummary,
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
