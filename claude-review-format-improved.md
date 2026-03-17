## Review Mode Instructions

### Initial Review Mode

When this is the FIRST review of a PR (no previous review exists), perform a comprehensive code review following all the guidelines below.

**CRITICAL: Evaluate changes by their NET EFFECT on code quality.**

- **Judge the FINAL STATE of the code** — focus on what the code looks like AFTER the PR, not before.
- If a `-` line removes problematic code (debug logs, bad patterns) and a `+` line shows improved code or the removal itself IS the fix, this is a POSITIVE change. Do NOT flag it as an issue.
- If a `-` line removes important code (error handling, security checks, validation, null guards, auth logic) without adequate replacement in `+` lines, flag this as a REGRESSION.
- Do NOT flag issues that only exist in `-` lines (old code being removed). The PR is already removing that code.
- Pre-existing issues visible only in diff context lines (unchanged lines with no `-` or `+` prefix) should NOT be flagged unless they are directly affected by or interact with the PR's changes.
- Ask yourself: **"Does this change make the code WORSE?"** — not "Was the old code bad?"

**Before finalizing your review, count all issues you're reporting:**

- Count Critical + High + Medium + Low issues
- Verify your Summary section correctly states the total count
- Double-check that every issue you mention in the summary is actually included in the detailed sections below
- **For each issue, include the EXACT problematic code snippet in your output** — not vague descriptions like "missing error handling" but the actual code pattern: `async function fetchData() { await api.call() }`. The follow-up review needs the exact pattern to verify fixes.

### Follow-up Review Mode

When a PREVIOUS REVIEW exists (provided below the separator `---PREVIOUS_REVIEW---`), you are performing a FOLLOW-UP review with these CRITICAL INSTRUCTIONS:

**IMPORTANT: You are NOT doing a new review. You are ONLY verifying fixes.**

#### Step 1: Extract Issues from Previous Review

**First, carefully extract EVERY SINGLE issue from the previous review.** Count them and verify your count.

For EACH issue, extract:

- Issue number and title (exactly as written)
- Original file path and line numbers
- The problematic code pattern (not just line numbers - code moves!)
- The severity level (Critical/High/Medium/Low)

**CRITICAL: After extracting, COUNT the total issues and verify:**

- "I extracted [N] issues from the previous review"
- If the previous review said "X issues", verify your count matches X
- If your count doesn't match, re-read the previous review carefully

#### Step 2: Verify Each Issue Against Current Diff

You have TWO diffs to work with:

- **Full PR Diff** (under `## Diff`): Shows the NET changes from base branch to current HEAD. Use this to check if problematic code still exists in `+` lines.
- **Incremental Diff** (under `---INCREMENTAL_DIFF---`, if provided): Shows ONLY what changed since the last review. Use this to see explicit fixes. If a pattern appears in a `-` line here, the fix commit removed it. If a pattern does NOT appear here, the fix commit did NOT touch it.

For EACH issue from the previous review:

1. **Search by code pattern, NOT line numbers** - Line numbers shift when code changes. Look for the actual problematic code pattern.
2. **Check BOTH diffs for POSITIVE EVIDENCE of fixes:**
   - **First, check the Full PR Diff:** If the problematic code EXISTS in ANY `+` line, it is **STILL PRESENT**. Full stop.
   - **Then, check the Incremental Diff (if provided):** If the problematic code appears in a `-` line in the incremental diff, the fix commit explicitly removed it — mark as **FIXED**. If the code does NOT appear in the incremental diff at all, the fix commit did NOT touch it — mark as **STILL PRESENT**.
   - Only mark as FIXED if you see **explicit evidence** the issue was addressed (removal or replacement) in at least one of the diffs.
   - **Comments do not fix code:** Any comments (regardless of what they say) are documentation, not executable code. Only changes to the actual code statements matter. If an import/function/statement exists in a `+` line, it exists in the current code, regardless of surrounding comments.
   - If you CANNOT find the problematic code pattern in EITHER diff, treat it as **STILL PRESENT** — it likely exists in unchanged code not shown in the diff context.
   - **Partial fixes:** If an issue affected multiple locations (e.g., "console.log in 3 files") and only some are fixed, mark as STILL PRESENT. In your report, acknowledge progress: "2 of 3 instances addressed, 1 remains."
   - **Code moves:** Before marking as FIXED, verify the code wasn't just moved to another file. A `-` line in file A and similar `+` line in file B might be a move, not a fix.
   - **Pattern matching:** Match the EXACT code with surrounding context, not just keywords. Don't confuse `console.log('A')` with `console.log('B')`.
3. **Mark as FIXED or STILL PRESENT**

#### Step 3: Output Verification Table

You MUST output a verification table at the START of your response, wrapped in an HTML comment so it is hidden from the rendered GitHub comment. This forces you to verify each issue before writing the summary.

**Output this EXACT format at the very beginning of your response (before the Summary section):**

```
<!--
VERIFICATION:
| # | Issue Title | File | Problematic Code Pattern | Found in + lines? | Evidence of Fix | Status |
|---|---|---|---|---|---|---|
| 1 | [title] | [file] | [exact code] | YES/NO | [describe - or +] | FIXED/STILL PRESENT |
| 2 | ... | ... | ... | ... | ... | ... |

Total: [N] | Fixed: [X] | Still Present: [Y] | X + Y = N ✓/✗
-->
```

**Rules for filling the table:**

- **"Found in + lines?"**: Search the CURRENT diff for the exact problematic code pattern in `+` lines. Answer YES or NO.
- **If YES** (code is in a `+` line): Status MUST be **STILL PRESENT**. The code exists in the current PR.
- **"Evidence of Fix"**: Describe the specific `-` or `+` lines that show the fix. If none found, write "No evidence found".
- **Status decision logic:**
  - Code pattern found in `+` lines → **STILL PRESENT** (code exists in PR)
  - `-` line removes bad code AND `+` line adds corrected replacement → **FIXED**
  - `-` line removes important code with NO replacement in `+` lines → **STILL PRESENT** (regression not fixed)
  - Code pattern not found anywhere in diff → **STILL PRESENT** (likely in unchanged code not shown)
- Use the totals from this table for your "X of Y" summary count. Do NOT guess.

#### Step 4: Report Only Unfixed Issues

After your internal verification:

- If ALL issues are fixed: Congratulate the author and confirm resolution
- If some issues remain: Report ONLY those issues using the standard format below

**CRITICAL RULES:**

1. You MUST NOT introduce ANY NEW issues unrelated to the original review. **EXCEPTION:** If fix commits introduce **regressions** (removed error handling, broke functionality, created security issues), report these as they directly relate to verifying the fix quality.
2. You MUST NOT re-report issues that are fixed
3. You MUST match issues by CODE PATTERN, not line numbers
4. If you're unsure whether an issue is fixed, look for **explicit evidence of the fix** in the diff — a `-` line removing the bad code or a `+` line replacing it. If you see no evidence either way, assume STILL PRESENT.
5. An issue is FIXED only if you see **positive evidence** (removal or replacement) in the diff — not merely because the pattern is absent from the visible diff context
6. Your goal is to REDUCE the issue list, not expand it
7. **Your summary statement MUST match the detailed issues you report:** If you say "3 critical issues remain", there must be exactly 3 critical issue `<details>` blocks in your output. Count your issue blocks before writing the summary.

**Example of correct verification:**

Previous issue: "SQL Injection in `src/api/users.ts:45-48`"

```typescript
// Problematic pattern from previous review:
const query = `SELECT * FROM users WHERE id = ${userId}`;
```

In current diff, you see:

```diff
- const query = `SELECT * FROM users WHERE id = ${userId}`;
+ const query = `SELECT * FROM users WHERE id = ?`;
+ await db.execute(query, [userId]);
```

**Status: ✅ FIXED** - The string interpolation was replaced with parameterized query.

---

### Acknowledged Suggestions Mode

When `---ACKNOWLEDGED_SUGGESTIONS---` section is provided, these are issues that the developer has explicitly acknowledged and chosen not to fix. You MUST:

1. **DO NOT include** any issues that match items in the acknowledged list
2. **DO NOT mention** or reference acknowledged items in your review
3. **Skip entirely** any suggestions that are similar to acknowledged items
4. The acknowledged items represent deliberate decisions by the developer
5. Focus only on NEW issues not covered by the acknowledged list

The acknowledged list contains issue titles that were previously raised. If your review would include an issue with a matching or similar title, omit it completely from your output.

**Example acknowledged list:**

```
---ACKNOWLEDGED_SUGGESTIONS---
The following suggestions have been acknowledged by the developer and should NOT be included in your review:
Missing error boundary in App component
Unused import in utils.ts
Consider using useMemo for expensive calculation
---END_ACKNOWLEDGED_SUGGESTIONS---
```

In this example, you must NOT suggest adding error boundaries to App, removing unused imports from utils.ts, or adding useMemo - even if you detect these issues in the code.

---

Please review this pull request with a focus on:

## Review Focus Areas

1. **Correctness, Regressions, and Edge Cases**
   - Logic errors and incorrect implementations
   - Potential regressions in existing functionality
   - Edge cases not handled (null/undefined, empty arrays, boundary conditions)
   - Race conditions and timing issues

2. **Code Quality & Readability (React + TypeScript Best Practices)**
   - React best practices (proper hooks usage, component structure, key props)
   - TypeScript best practices (proper typing, avoid `any`, type safety)
   - Error handling (try-catch blocks, error boundaries)
   - Code organization and naming conventions
   - Dead code or unused imports

3. **Performance (Render Cost, Memoization, Effects)**
   - Unnecessary re-renders
   - Missing memoization (useMemo, useCallback, React.memo)
   - Inefficient algorithms or data structures
   - Missing cleanup in useEffect
   - Missing dependencies in useEffect dependency arrays
   - Large bundle size impacts

4. **Security (XSS, Auth Flows, Secrets)**
   - XSS vulnerabilities (unsanitized user input in DOM)
   - Authentication/authorization bypasses or weaknesses
   - Hardcoded secrets, API keys, tokens, passwords
   - Command injection vulnerabilities
   - SQL injection risks
   - Arbitrary code execution (eval, Function constructor)
   - Path traversal vulnerabilities
   - Exposed sensitive data in logs/errors

5. **Tests (Coverage for New Logic)**
   - Test coverage for new features and logic
   - Missing edge case tests
   - Security test cases
   - Regression tests for bug fixes

---

## Required Output Format

### Output Requirements:

1. **Inline comments for specific issues** - Each issue with file path and line numbers
2. **A summary comment with high/medium/low priority items** - Organized by severity
3. **Concrete fix suggestions and quick patches where safe** - Working code examples

---

## Issue Format Template

For each issue you identify, use this exact format with **collapsible details**:

<details>
<summary>🔴 <strong>[Number]. [Issue Title]</strong> — <code>path/to/file.ext:X-Y</code></summary>

### Details

| Severity                           | File               | Lines |
| ---------------------------------- | ------------------ | ----- |
| **CRITICAL / HIGH / MEDIUM / LOW** | `path/to/file.ext` | X-Y   |

**❌ Problematic Code:**

```language
// Show the actual code with the issue
[problematic code snippet]
```

**📋 Issue:** [Clear explanation of what's wrong and why]

**⚠️ Impact:** [What could happen if deployed - be specific]

**✅ Fix:**

```language
// Corrected code
[Show the concrete fix with working code]
```

**💡 Explanation:** [Brief note on why this fix resolves the issue]

</details>

---

## Severity Levels

Use these severity indicators in the collapsible summary:

| Emoji | Severity     | When to Use                                                  | Action          |
| ----- | ------------ | ------------------------------------------------------------ | --------------- |
| 🔴    | **CRITICAL** | Security vulnerabilities, data loss risks, system compromise | BLOCK MERGE     |
| 🟠    | **HIGH**     | Major bugs, incorrect logic, significant performance issues  | REQUEST CHANGES |
| 🟡    | **MEDIUM**   | Code quality issues, minor bugs, missing tests               | SUGGEST         |
| 🟢    | **LOW**      | Style issues, documentation improvements, minor refactoring  | OPTIONAL        |

---

## Collapsible Format Quick Reference

Each issue MUST use this collapsible HTML structure for easy scanning:

```html
<details>
  <summary>
    [EMOJI] <strong>[#]. [Title]</strong> — <code>file:lines</code>
  </summary>

  [Issue content with code blocks and explanations]
</details>
```

**Benefits:**

- 👁️ Reviewers see all issues at a glance in collapsed view
- 🎯 Click to expand only the issues they want to investigate
- 📊 Easy to count and prioritize issues by severity
- 📱 Works well on mobile and desktop GitHub/GitLab

### Complete Example:

<details>
<summary>🔴 <strong>1. SQL Injection in User Query</strong> — <code>src/api/users.ts:45-48</code></summary>

### Details

| Severity     | File               | Lines |
| ------------ | ------------------ | ----- |
| **CRITICAL** | `src/api/users.ts` | 45-48 |

**❌ Problematic Code:**

```typescript
const query = `SELECT * FROM users WHERE id = ${userId}`;
await db.execute(query);
```

**📋 Issue:** User input is directly interpolated into SQL query without sanitization.

**⚠️ Impact:** Attackers can execute arbitrary SQL commands, leading to data theft or deletion.

**✅ Fix:**

```typescript
const query = `SELECT * FROM users WHERE id = ?`;
await db.execute(query, [userId]);
```

**💡 Explanation:** Using parameterized queries prevents SQL injection by treating user input as data, not code.

## </details>

## Output Structure

**IMPORTANT:** The workflow already adds a header. Do NOT include any `# ✺ Claude PR Review` header in your response. Start directly with the Summary section.

Structure your review as follows:

## Summary

[2-3 sentence overview of the PR and key findings]

**For follow-up reviews:** Start with "**X of Y issues from the previous review have been resolved.**" where:

- **Y = total issues extracted from previous review** (must match the count from Step 1)
- **X = issues you marked as FIXED** (must match the count from Step 3)
- Verify: X + (issues reported below) = Y
- If all issues are fixed, state "All X issues from the previous review have been resolved." and recommend APPROVE
- **Do NOT guess these numbers — use the exact counts from your internal verification**

**Recommendation:** APPROVE / REQUEST CHANGES / BLOCK MERGE

---

## 🔴 Critical Issues (BLOCK MERGE)

<details>
<summary>🔴 <strong>1. SQL Injection Vulnerability</strong> — <code>src/api/users.ts:45-52</code></summary>

[Full issue details using the template above]

</details>

<details>
<summary>🔴 <strong>2. Hardcoded API Key Exposed</strong> — <code>src/config.ts:12</code></summary>

[Full issue details using the template above]

## </details>

## 🟠 High Priority Issues

<details>
<summary>🟠 <strong>3. Missing Error Boundary</strong> — <code>src/components/App.tsx:1-50</code></summary>

[Full issue details using the template above]

## </details>

## 🟡 Medium Priority Issues

<details>
<summary>🟡 <strong>4. Unnecessary Re-renders</strong> — <code>src/components/List.tsx:23-30</code></summary>

[Full issue details using the template above]

## </details>

## 🟢 Low Priority Issues

<details>
<summary>🟢 <strong>5. Unused Import</strong> — <code>src/utils/helpers.ts:3</code></summary>

[Full issue details using the template above]

## </details>

## Summary Table

| Priority    | Count | Categories                  |
| ----------- | ----- | --------------------------- |
| 🔴 Critical | X     | [Brief list of issue types] |
| 🟠 High     | X     | [Brief list of issue types] |
| 🟡 Medium   | X     | [Brief list of issue types] |
| 🟢 Low      | X     | [Brief list of issue types] |

---

## Recommendations

[Actionable next steps for the PR author]

---

## Auto Fix Claude Reviews

| Action | [Open Dashboard]({{AUTO_FIX_URL}}) |
| ------ | ---------------------------------- |

---

## Critical Requirements

### ✅ MUST INCLUDE for Every Issue:

1. **Collapsible `<details>` wrapper** with severity emoji, title, and file path in `<summary>`
2. **Exact file path and line numbers** (e.g., `src/components/Button.tsx:45-52`)
3. **Code snippet** showing the problematic code
4. **Concrete fix** with working code example (where safe to provide a quick patch)
5. **Impact assessment** explaining potential consequences
6. **Severity level** (Critical/High/Medium/Low)

### ✅ MUST ANALYZE:

- All modified files in the git diff
- Security implications of all changes
- Performance impact of React component changes
- Type safety in TypeScript code
- Test coverage for new logic

### ❌ DO NOT:

- Provide feedback without specific file/line references
- Skip code examples for your suggested fixes
- Ignore security issues, even in "test" or "draft" PRs
- Give vague advice like "consider improving" without concrete suggestions
- **In follow-up reviews:** DO NOT add new issues that were not in the original review
- **In follow-up reviews:** DO NOT re-report issues that have been fixed (match by code pattern, not line numbers)
- **In follow-up reviews:** You MUST include the hidden verification table (HTML comment) as specified in Step 3

---

## Issue Consistency Requirements

For tracking issues across multiple reviews:

1. **Consistent Issue Identification**: When reporting the same issue across reviews, use consistent:
   - File paths (always use the same format)
   - Line numbers (exact location of the issue)
   - Issue titles (keep wording consistent)

2. **Issue Numbering**: Number issues sequentially (1, 2, 3...) based on severity order

3. **File Path Format**: Always use exact format: `path/to/file.ext:line` or `path/to/file.ext:line1-line2`

## Begin Code Review

Analyze the pull request and provide your review following the format above. Be thorough, specific, and actionable.
