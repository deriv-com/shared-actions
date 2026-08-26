// Run with: node --test .github/actions/archive_on_merge/archive-on-merge.test.js
//
// No package.json and no dependencies on purpose — this repo ships workflows,
// not a Node package, so the tests use the runner built into Node 18+.
const test = require("node:test");
const assert = require("node:assert");
const http = require("node:http");

const {
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
  FILES_PER_PAGE,
  MAX_FILE_PAGES,
} = require("./archive-on-merge.js");

/**
 * Start a stub GitHub API on a random port. `handler(url, req)` returns either
 * an array (sent as 200 JSON) or a { status, body } object. Resolves to the
 * base URL; the server is closed when the test ends.
 */
async function stubApi(t, handler) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    const result = handler(url, req);
    const status = Array.isArray(result) ? 200 : result.status;
    const body = Array.isArray(result) ? result : (result.body ?? []);
    if (result && result.hang) {
      return; // socket accepted, no response — exercises the request timeout
    }
    res.writeHead(status, {
      "content-type": "application/json",
      ...(Array.isArray(result) ? {} : (result.headers ?? {})),
    });
    res.end(typeof body === "string" ? body : JSON.stringify(body));
  });
  await new Promise((resolve) => server.listen(0, resolve));
  t.after(() => server.close());
  return `http://127.0.0.1:${server.address().port}`;
}

const page = (n, item) => Array.from({ length: n }, (_, i) => item(i));

test("extractChangeNames picks up change directories", () => {
  assert.deepStrictEqual(
    extractChangeNames(["openspec/changes/foo-bar/tasks.md"]),
    ["foo-bar"]
  );
  assert.deepStrictEqual(
    extractChangeNames([
      "openspec/changes/a/x.md",
      "openspec/changes/a/y.md",
      "openspec/changes/b/z.md",
    ]),
    ["a", "b"]
  );
});

test("extractChangeNames ignores the archive dir and unrelated files", () => {
  assert.deepStrictEqual(
    extractChangeNames(["openspec/changes/archive/2026-01-01-x/spec.md"]),
    []
  );
  assert.deepStrictEqual(
    extractChangeNames([
      "lib/hooks/useDocumentTitle.ts",
      "lib/hooks/__tests__/useDocumentTitle.test.ts",
    ]),
    []
  );
});

test("extractChangeNames rejects path traversal", () => {
  assert.deepStrictEqual(
    extractChangeNames(["openspec/changes/../evil/tasks.md"]),
    []
  );
  assert.deepStrictEqual(
    extractChangeNames(["openspec/changes/Not_Kebab/tasks.md"]),
    []
  );
});

test("extractChangeNames sorts, so the branch slug is order-independent", () => {
  // Two runs archiving the same set must produce the same branch name, or the
  // "is an archive PR already open?" check silently misses.
  const forwards = extractChangeNames([
    "openspec/changes/b-change/tasks.md",
    "openspec/changes/a-change/tasks.md",
  ]);
  const backwards = extractChangeNames([
    "openspec/changes/a-change/tasks.md",
    "openspec/changes/b-change/tasks.md",
  ]);
  assert.deepStrictEqual(forwards, ["a-change", "b-change"]);
  assert.deepStrictEqual(forwards, backwards);
});

test("isTasksComplete handles nested sub-tasks", () => {
  assert.strictEqual(isTasksComplete("- [x] one\n  - [x] two\n"), true);
  assert.strictEqual(isTasksComplete("- [x] one\n  - [ ] nested\n"), false);
  assert.strictEqual(isTasksComplete("- [ ] one\n"), false);
});

test("isValidPrNumber accepts only positive integers", () => {
  assert.strictEqual(isValidPrNumber("673"), true);
  for (const bad of ["0", "-1", "1.5", "", null, undefined, "12; rm -rf /"]) {
    assert.strictEqual(isValidPrNumber(bad), false, `rejects ${bad}`);
  }
});

test("isValidRepo accepts a slug and rejects dot segments", () => {
  assert.strictEqual(isValidRepo("deriv-com/deriv-api-v2"), true);
  assert.strictEqual(isValidRepo("a.b/c_d-e"), true);
  for (const bad of ["nope", "a/b/c", "", null, "a b/c"]) {
    assert.strictEqual(isValidRepo(bad), false, `rejects ${bad}`);
  }
  // fetch would resolve these away and retarget the request at another path.
  for (const bad of ["../..", "owner/..", "../repo", "./repo", "owner/."]) {
    assert.strictEqual(isValidRepo(bad), false, `rejects traversal ${bad}`);
  }
});

test("fetchPullRequestFiles paginates and stops on a short page", async (t) => {
  const seen = [];
  const apiUrl = await stubApi(t, (url) => {
    seen.push(url.searchParams.get("page"));
    if (url.searchParams.get("page") === "1") {
      return page(FILES_PER_PAGE, (i) => ({ filename: `src/f${i}.ts` }));
    }
    return [{ filename: "openspec/changes/my-change/tasks.md" }];
  });

  const files = await fetchPullRequestFiles({
    apiUrl,
    repo: "o/r",
    prNumber: "7",
    token: "tok",
  });
  assert.deepStrictEqual(seen, ["1", "2"]);
  assert.strictEqual(files.length, FILES_PER_PAGE + 1);
  assert.deepStrictEqual(extractChangeNames(files), ["my-change"]);
});

test("fetchPullRequestFiles sends auth and API version headers", async (t) => {
  let headers;
  const apiUrl = await stubApi(t, (_url, req) => {
    headers = req.headers;
    return [];
  });
  await fetchPullRequestFiles({
    apiUrl,
    repo: "o/r",
    prNumber: "7",
    token: "secret-token",
  });
  assert.strictEqual(headers.authorization, "Bearer secret-token");
  assert.strictEqual(headers["x-github-api-version"], "2022-11-28");
});

test("a rename out of a change dir still counts, via previous_filename", async (t) => {
  const apiUrl = await stubApi(t, () => [
    {
      filename: "openspec/specs/x/spec.md",
      previous_filename: "openspec/changes/renamed-change/spec.md",
    },
  ]);
  const files = await fetchPullRequestFiles({
    apiUrl,
    repo: "o/r",
    prNumber: "7",
    token: "tok",
  });
  assert.deepStrictEqual(extractChangeNames(files), ["renamed-change"]);
});

test("a non-retryable API error throws instead of reporting 'nothing to archive'", async (t) => {
  const apiUrl = await stubApi(t, () => ({ status: 404, body: {} }));
  await assert.rejects(
    fetchPullRequestFiles({
      apiUrl,
      repo: "o/r",
      prNumber: "7",
      token: "tok",
      retry: { baseDelayMs: 0 },
    }),
    /404/
  );
});

test("a non-array API response throws", async (t) => {
  const apiUrl = await stubApi(t, () => ({
    status: 200,
    body: { message: "not a list" },
  }));
  await assert.rejects(
    fetchPullRequestFiles({ apiUrl, repo: "o/r", prNumber: "7", token: "tok" }),
    /Expected an array/
  );
});

test("hitting the API's file ceiling warns rather than truncating silently", async (t) => {
  const apiUrl = await stubApi(t, () =>
    page(FILES_PER_PAGE, (i) => ({ filename: `src/f${i}.ts` }))
  );
  const logs = [];
  t.mock.method(console, "log", (msg) => logs.push(String(msg)));

  const files = await fetchPullRequestFiles({
    apiUrl,
    repo: "o/r",
    prNumber: "7",
    token: "tok",
  });
  assert.strictEqual(files.length, MAX_FILE_PAGES * FILES_PER_PAGE);
  assert.ok(
    logs.some((l) => l.includes("::warning::") && l.includes("truncated")),
    "expected a truncation warning"
  );
});

test("fetchWithRetry retries 5xx and 429, then succeeds", async (t) => {
  for (const transient of [500, 502, 503, 429]) {
    let calls = 0;
    const apiUrl = await stubApi(t, () => {
      calls += 1;
      return calls < 3 ? { status: transient, body: {} } : [];
    });
    const res = await fetchWithRetry(
      `${apiUrl}/repos/o/r/pulls/7/files`,
      {},
      { baseDelayMs: 0 }
    );
    assert.strictEqual(res.status, 200, `recovers from ${transient}`);
    assert.strictEqual(calls, 3, `retried ${transient} twice`);
  }
});

test("fetchWithRetry does not retry a 404", async (t) => {
  let calls = 0;
  const apiUrl = await stubApi(t, () => {
    calls += 1;
    return { status: 404, body: {} };
  });
  const res = await fetchWithRetry(
    `${apiUrl}/repos/o/r/pulls/7/files`,
    {},
    { baseDelayMs: 0 }
  );
  assert.strictEqual(res.status, 404);
  assert.strictEqual(calls, 1, "a 404 is a real answer, not a blip");
});

test("fetchWithRetry gives up after the attempt budget", async (t) => {
  let calls = 0;
  const apiUrl = await stubApi(t, () => {
    calls += 1;
    return { status: 503, body: {} };
  });
  await assert.rejects(
    fetchWithRetry(
      `${apiUrl}/repos/o/r/pulls/7/files`,
      {},
      { attempts: 3, baseDelayMs: 0 }
    ),
    /503/
  );
  assert.strictEqual(calls, 3);
});

test("fetchWithRetry retries a network error", async () => {
  // Nothing is listening on this port, so fetch rejects rather than responding.
  await assert.rejects(
    fetchWithRetry("http://127.0.0.1:1/x", {}, { attempts: 2, baseDelayMs: 0 }),
    /request failed/
  );
});

// --- response classification -------------------------------------------------

const stubResponse = (status, headers = {}) => ({
  status,
  headers: { get: (k) => headers[k.toLowerCase()] ?? null },
});

test("isRetryableResponse retries 5xx and 429", () => {
  for (const status of [500, 502, 503, 504, 429]) {
    assert.strictEqual(
      isRetryableResponse(stubResponse(status)),
      true,
      `${status} is transient`
    );
  }
});

test("isRetryableResponse does not retry a plain 4xx", () => {
  for (const status of [200, 301, 400, 404, 422]) {
    assert.strictEqual(
      isRetryableResponse(stubResponse(status)),
      false,
      `${status} is a real answer`
    );
  }
});

test("isRetryableResponse retries a rate-limit 403 but not a permissions 403", () => {
  // GitHub uses 403 for both primary and secondary rate limits. Losing the
  // call permanently loses the archive, so these must be retried.
  assert.strictEqual(
    isRetryableResponse(stubResponse(403, { "x-ratelimit-remaining": "0" })),
    true,
    "primary rate limit"
  );
  assert.strictEqual(
    isRetryableResponse(stubResponse(403, { "retry-after": "60" })),
    true,
    "secondary rate limit"
  );
  // A token without pull-requests:read is also a 403. Retrying it three times
  // would bury the real cause.
  assert.strictEqual(
    isRetryableResponse(stubResponse(403, { "x-ratelimit-remaining": "4999" })),
    false,
    "permissions failure"
  );
  assert.strictEqual(
    isRetryableResponse(stubResponse(403)),
    false,
    "bare 403 without rate-limit headers"
  );
});

test("fetchWithRetry retries a rate-limit 403 and then succeeds", async (t) => {
  let calls = 0;
  const apiUrl = await stubApi(t, () => {
    calls += 1;
    return calls < 3
      ? { status: 403, body: {}, headers: { "x-ratelimit-remaining": "0" } }
      : [];
  });
  const res = await fetchWithRetry(
    `${apiUrl}/repos/o/r/pulls/7/files`,
    {},
    { baseDelayMs: 0 }
  );
  assert.strictEqual(res.status, 200);
  assert.strictEqual(calls, 3);
});

test("fetchWithRetry does not retry a permissions 403", async (t) => {
  let calls = 0;
  const apiUrl = await stubApi(t, () => {
    calls += 1;
    return { status: 403, body: {} };
  });
  const res = await fetchWithRetry(
    `${apiUrl}/repos/o/r/pulls/7/files`,
    {},
    { baseDelayMs: 0 }
  );
  assert.strictEqual(res.status, 403);
  assert.strictEqual(calls, 1, "a permissions 403 is a real answer");
});

// --- request timeout ---------------------------------------------------------

test("a stalled request times out per attempt and is retried", async (t) => {
  let calls = 0;
  const apiUrl = await stubApi(t, () => {
    calls += 1;
    return calls < 2 ? { hang: true } : [];
  });
  const res = await fetchWithRetry(
    `${apiUrl}/repos/o/r/pulls/7/files`,
    {},
    { baseDelayMs: 0, timeoutMs: 150 }
  );
  // Without a per-attempt signal the first call would sit on undici's 300s
  // default headers timeout and outlast the job.
  assert.strictEqual(res.status, 200, "recovered on the retry");
  assert.strictEqual(calls, 2);
});

test("a permanently stalled request fails with a timeout message, not a hang", async (t) => {
  const apiUrl = await stubApi(t, () => ({ hang: true }));
  await assert.rejects(
    fetchWithRetry(
      `${apiUrl}/repos/o/r/pulls/7/files`,
      {},
      { attempts: 2, baseDelayMs: 0, timeoutMs: 150 }
    ),
    /request timed out after 150ms/
  );
});

test("a caller-supplied signal is respected over the default timeout", async (t) => {
  const apiUrl = await stubApi(t, () => ({ hang: true }));
  await assert.rejects(
    fetchWithRetry(
      `${apiUrl}/repos/o/r/pulls/7/files`,
      { signal: AbortSignal.timeout(120) },
      { attempts: 1, baseDelayMs: 0, timeoutMs: 60_000 }
    ),
    /request (timed out|failed)/
  );
});

// --- tasks.md census ---------------------------------------------------------

// Shaped after the real file that prompted this: a change whose remaining work
// is split between pre-merge verification and a section that by its own title
// cannot be done before the merge.
const TASKS_FIXTURE = [
  "## 1. Build it",
  "",
  "- [x] 1.1 First thing",
  "  - [x] 1.2 Nested and done",
  "",
  "## 5. Verify",
  "",
  "- [ ] 5.1 Run the test suite",
  "- [X] 5.2 Uppercase X counts as checked",
  "",
  "## 6. Post-merge acceptance (cannot be run before merge)",
  "",
  "- [ ] 6.1 Dispatch from master",
  "- [ ] 6.2 Confirm the next real merge",
].join("\n");

test("parseTasks counts checked and unchecked, including nested and uppercase", () => {
  const census = parseTasks(TASKS_FIXTURE);
  assert.strictEqual(census.total, 6);
  assert.strictEqual(census.checked, 3);
  assert.strictEqual(census.incomplete.length, 3);
});

test("parseTasks records the line and nearest section for each remaining task", () => {
  const { incomplete } = parseTasks(TASKS_FIXTURE);
  assert.deepStrictEqual(
    incomplete.map((t) => [t.line, t.section, t.text]),
    [
      [8, "5. Verify", "5.1 Run the test suite"],
      [13, "6. Post-merge acceptance (cannot be run before merge)", "6.1 Dispatch from master"],
      [14, "6. Post-merge acceptance (cannot be run before merge)", "6.2 Confirm the next real merge"],
    ]
  );
});

test("parseTasks handles a body with no checkboxes at all", () => {
  const census = parseTasks("# Notes\n\nNothing actionable here.\n");
  assert.deepStrictEqual(census, { total: 0, checked: 0, incomplete: [] });
});

test("parseTasks tolerates empty and missing input", () => {
  for (const input of ["", null, undefined]) {
    assert.strictEqual(parseTasks(input).total, 0, `handles ${input}`);
  }
});

test("parseTasks truncates a very long task rather than reflowing the log", () => {
  const long = "x".repeat(300);
  const [task] = parseTasks(`- [ ] ${long}`).incomplete;
  assert.ok(task.text.length <= 100, `got ${task.text.length}`);
  assert.ok(task.text.endsWith("…"), "marks the truncation");
});

test("isTasksComplete stays consistent with parseTasks", () => {
  // They must not drift: isTasksComplete delegates, so any body where one says
  // "complete" and the other reports remaining work is a bug.
  const bodies = [
    TASKS_FIXTURE,
    "- [x] done\n",
    "- [ ] not done\n",
    "  - [ ] nested only\n",
    "# no tasks\n",
    "",
  ];
  for (const body of bodies) {
    assert.strictEqual(
      isTasksComplete(body),
      parseTasks(body).incomplete.length === 0,
      `disagreement on: ${JSON.stringify(body)}`
    );
  }
});

test("groupBySection preserves file order and merges consecutive runs", () => {
  const groups = groupBySection([
    { line: 1, section: "A", text: "a1" },
    { line: 2, section: "A", text: "a2" },
    { line: 3, section: "B", text: "b1" },
    { line: 4, section: "A", text: "a3" },
  ]);
  assert.deepStrictEqual(
    groups.map((g) => [g.section, g.tasks.length]),
    [["A", 2], ["B", 1], ["A", 1]]
  );
});

test("groupBySection labels tasks that precede any heading", () => {
  const [group] = groupBySection([{ line: 1, section: null, text: "orphan" }]);
  assert.strictEqual(group.section, "(no section)");
});

// --- reporting ---------------------------------------------------------------

test("the log report names the counts, the sections and the line numbers", () => {
  const report = formatIncompleteReport("my-change", parseTasks(TASKS_FIXTURE));
  assert.match(report, /'my-change' is not complete: 3\/6 tasks checked, 3 remaining\./);
  assert.match(report, /^ {2}5\. Verify$/m);
  assert.match(report, /5\.1 Run the test suite {2}\(tasks\.md:8\)/);
  // URLs belong in the job summary: change names run to ~90 characters, so a
  // blob URL per row buries the task text it annotates.
  assert.ok(!report.includes("https://"), "log lines stay URL-free");
});

test("the report calls out remaining tasks a merge can never see checked", () => {
  const report = formatIncompleteReport("my-change", parseTasks(TASKS_FIXTURE));
  assert.match(report, /2 of the 3 remaining task\(s\) sit in a section marked post-merge/);
});

test("the post-merge note stays quiet when no section is post-merge", () => {
  const report = formatIncompleteReport(
    "my-change",
    parseTasks("## 5. Verify\n\n- [ ] 5.1 Run the suite\n")
  );
  assert.ok(!report.includes("post-merge"), "no spurious note");
});

test("the job summary renders a table and links each line when a URL is known", () => {
  const md = formatIncompleteSummary("my-change", parseTasks(TASKS_FIXTURE), {
    tasksUrl: "https://example.test/blob/sha/tasks.md",
  });
  assert.match(md, /### Not archived: `my-change`/);
  assert.match(md, /\*\*3 of 6\*\* tasks checked/);
  assert.match(md, /\| Section \| Remaining task \| Line \|/);
  // ?plain=1 matters: GitHub ignores an #L anchor on a rendered .md blob.
  assert.match(
    md,
    /\[8\]\(https:\/\/example\.test\/blob\/sha\/tasks\.md\?plain=1#L8\)/
  );
  assert.match(md, /> 2 of the 3 remaining task\(s\) sit in a section marked post-merge/);
});

test("the job summary degrades to bare line numbers with no URL", () => {
  const md = formatIncompleteSummary("my-change", parseTasks(TASKS_FIXTURE));
  assert.ok(!md.includes("]("), "no half-built links");
  assert.match(md, /\| 8 \|/);
});

test("a pipe in a task cannot break out of the summary table", () => {
  const md = formatIncompleteSummary(
    "my-change",
    parseTasks("## S\n\n- [ ] run `a | b` then stop\n")
  );
  const row = md.split("\n").find((l) => l.includes("run `a"));
  assert.ok(row.includes("\\|"), "the pipe is escaped");
  assert.strictEqual(row.split(/(?<!\\)\|/).length - 1, 4, "row keeps 3 cells");
});

// --- line endings ------------------------------------------------------------

test("parseTasks reads CRLF, CR and U+2028 files, not just LF", () => {
  // Regression: TASK_RE ends in `$`, which (no `m` flag) only matches
  // end-of-string, and `.` never matches `\r`. Splitting on "\n" alone left a
  // trailing "\r" on every line, so a CRLF file full of unchecked boxes parsed
  // as ZERO tasks and read as complete — archiving an unfinished change.
  for (const [label, eol] of [
    ["CRLF", "\r\n"],
    ["CR", "\r"],
    ["LS", "\u2028"],
    ["PS", "\u2029"],
    ["LF", "\n"],
  ]) {
    const body = ["## S", "", "- [x] done", "- [ ] NOT done"].join(eol);
    const census = parseTasks(body);
    assert.strictEqual(census.total, 2, `${label}: counts both tasks`);
    assert.strictEqual(census.checked, 1, `${label}: counts the checked one`);
    assert.strictEqual(
      isTasksComplete(body),
      false,
      `${label}: must NOT read as complete`
    );
    assert.strictEqual(
      census.incomplete[0].section,
      "S",
      `${label}: heading parsed`
    );
  }
});

test("a CRLF task keeps no carriage return in its reported text", () => {
  const [task] = parseTasks("- [ ] trailing CR must go\r\n").incomplete;
  assert.strictEqual(task.text, "trailing CR must go");
});

// --- fenced blocks -----------------------------------------------------------

const FENCED = [
  "## 1. Real section",
  "",
  "- [x] 1.1 done",
  "",
  "```bash",
  "# after merging, run the smoke test",
  "- [ ] not a real task",
  "```",
  "",
  "- [ ] 1.2 ordinary pre-merge work",
].join("\n");

test("parseTasks ignores checkboxes and headings inside fenced blocks", () => {
  const census = parseTasks(FENCED);
  assert.strictEqual(census.total, 2, "the sample row in the fence is not a task");
  assert.deepStrictEqual(
    census.incomplete.map((t) => t.text),
    ["1.2 ordinary pre-merge work"]
  );
});

test("a comment inside a fence cannot become the attributed section", () => {
  // `# after merging, ...` matches HEADING_RE and matched the post-merge
  // heuristic, so ordinary work was reported as never-archivable.
  const census = parseTasks(FENCED);
  assert.strictEqual(census.incomplete[0].section, "1. Real section");
  assert.ok(
    !formatIncompleteReport("c", census).includes("post-merge"),
    "no phantom post-merge note"
  );
});

test("parseTasks handles tilde fences too", () => {
  const census = parseTasks("~~~\n- [ ] sample\n~~~\n\n- [ ] real\n");
  assert.strictEqual(census.total, 1);
});

// --- post-merge classification ----------------------------------------------

test("post-merge classification matches the section's subject, not any mention", () => {
  const classify = (section) =>
    postMergeTasks([{ line: 1, section, text: "t" }]).length === 1;

  for (const heading of [
    "6. Post-merge acceptance (cannot be run before merge)",
    "Post-release acceptance",
    "After deployment",
    "After the merge",
    "Once merged",
    "Verify [post-merge]", // explicit opt-in marker
  ]) {
    assert.strictEqual(classify(heading), true, `post-merge: ${heading}`);
  }

  for (const heading of [
    // The phrase appears, but the section is pre-merge work. Unanchored, this
    // told the author the exact opposite of the truth.
    "Pre-merge checks (do these before, not after merging)",
    "Compost-merge cleanup",
    "5. Verify",
    "Post",
  ]) {
    assert.strictEqual(classify(heading), false, `not post-merge: ${heading}`);
  }
});

test("both renderers embed the identical post-merge note", () => {
  // One wording, one classification: a future edit cannot land in the log and
  // not the job summary.
  const census = parseTasks("## 6. Post-merge acceptance\n\n- [ ] a\n- [ ] b\n");
  const note = postMergeNoteText(census.incomplete);
  assert.ok(note, "note applies");
  assert.ok(formatIncompleteReport("c", census).includes(note), "log");
  assert.ok(formatIncompleteSummary("c", census).includes(note), "summary");
});

test("postMergeNoteText is null when nothing is post-merge", () => {
  assert.strictEqual(
    postMergeNoteText(parseTasks("## 5. Verify\n\n- [ ] a\n").incomplete),
    null
  );
});

// --- truncation --------------------------------------------------------------

test("truncate never splits a surrogate pair", () => {
  // slice() cuts at UTF-16 code units, so an emoji straddling the limit left a
  // lone high surrogate that rendered as U+FFFD.
  for (const pad of [97, 98, 99, 100]) {
    const text = truncate("x".repeat(pad) + "\u{1F600}" + "y".repeat(60));
    assert.ok(
      !/[\uD800-\uDBFF]$/.test(text.replace(/…$/, "")),
      `pad=${pad}: no lone high surrogate`
    );
    assert.ok(!text.includes("�"), `pad=${pad}: no replacement char`);
  }
});

test("truncate leaves short text and whole emoji alone", () => {
  assert.strictEqual(truncate("short"), "short");
  assert.strictEqual(truncate("ok \u{1F600}"), "ok \u{1F600}");
});

// --- table escaping ----------------------------------------------------------

test("neither a pipe nor an already-escaped pipe can add a table cell", () => {
  // Escaping only the pipe turned an author's `\|` into `\\|`, which GFM reads
  // as an escaped backslash plus a LIVE delimiter.
  for (const [text, label] of [
    ["a | b", "bare pipe"],
    ["a \\| b", "already-escaped pipe"],
    ["a \\\\| b", "double backslash then pipe"],
  ]) {
    const md = formatIncompleteSummary(
      "c",
      parseTasks(`## S\n\n- [ ] ${text}\n`)
    );
    const row = md.split("\n").find((l) => l.includes("a "));
    const live = row.replace(/\\\\/g, "").replace(/\\\|/g, "").match(/\|/g);
    assert.strictEqual(live.length, 4, `${label}: row keeps 3 cells :: ${row}`);
  }
});

// --- blob URL ----------------------------------------------------------------

test("repoSlugFromRemote reads https and ssh remotes", () => {
  for (const [url, expected] of [
    ["https://github.com/deriv-com/shared-actions.git", "deriv-com/shared-actions"],
    ["git@github.com:deriv-com/shared-actions.git", "deriv-com/shared-actions"],
    ["https://github.com/o/r", "o/r"],
    ["ssh://git@github.com/o/r.git", "o/r"],
  ]) {
    assert.strictEqual(repoSlugFromRemote(url), expected, url);
  }
  for (const bad of ["", null, undefined, "not-a-url"]) {
    assert.strictEqual(repoSlugFromRemote(bad), null, `rejects ${bad}`);
  }
});

// --- the annotation ----------------------------------------------------------

test("the skip notice is a well-formed workflow command", () => {
  const notice = formatSkipNotice("my-change", parseTasks(TASKS_FIXTURE));
  // A stray `,` or `:` in the property list stops the runner recognising the
  // command, and the annotation vanishes from a green run with nothing failing.
  assert.match(notice, /^::notice title=[^,:]+::/);
  assert.strictEqual(notice.split("::").length - 1, 2, "exactly two `::` markers");
  assert.ok(
    !/[\r\n]/.test(notice),
    "single line — a newline would truncate the command"
  );
  assert.ok(notice.includes("'my-change' has 3 of 6 tasks unchecked"));
});

test("the skip notice counts agree with the census it was built from", () => {
  for (const body of [
    TASKS_FIXTURE,
    "## S\n\n- [ ] only one\n",
    "## S\n\n- [x] a\n- [x] b\n- [ ] c\n",
  ]) {
    const census = parseTasks(body);
    assert.ok(
      formatSkipNotice("c", census).includes(
        `${census.incomplete.length} of ${census.total} tasks unchecked`
      ),
      `counts match for: ${JSON.stringify(body)}`
    );
  }
});

test("a failed job-summary write is annotated, not just logged", (t) => {
  // The write is the thing that failed, so the report must not depend on it.
  const logs = [];
  t.mock.method(console, "log", (msg) => logs.push(String(msg)));
  process.env.GITHUB_STEP_SUMMARY = "/nonexistent-dir/summary.md";
  t.after(() => delete process.env.GITHUB_STEP_SUMMARY);

  // Must not throw: a summary is reporting, not the job's purpose.
  writeStepSummary(formatIncompleteSummary("c", parseTasks(TASKS_FIXTURE)));

  assert.ok(
    logs.some((l) => l.startsWith("::warning::") && l.includes("job summary")),
    `expected a ::warning:: annotation, got: ${JSON.stringify(logs)}`
  );
});
