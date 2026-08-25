// Run with: node --test .github/actions/archive_on_merge/archive-on-merge.test.js
//
// No package.json and no dependencies on purpose — this repo ships workflows,
// not a Node package, so the tests use the runner built into Node 18+.
const test = require("node:test");
const assert = require("node:assert");
const http = require("node:http");

const {
  extractChangeNames,
  isTasksComplete,
  isValidPrNumber,
  isValidRepo,
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
    res.writeHead(status, { "content-type": "application/json" });
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
