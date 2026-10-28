#!/usr/bin/env bash
# Recover the review from the session transcript when the engine wrote none.
#
# The Anthropic engine sometimes ends its turn with the finished review as
# chat text instead of calling the Write tool (seen on derivatives-trader:
# the job failed with "claude-code-action finished but wrote no review").
# That text is in the session transcript the action saved; a complete review
# there IS the review, so recover it instead of failing the job. Anything
# short of a complete review leaves the file alone and the verify step fails
# closed exactly as before. The recovered text is model output with the same
# trust level as a written file: the caller's exfiltration scan still runs
# over it before anything is posted.
#
# Env in:  OUTPUT_PATH    — the review file to write
#          EXECUTION_FILE — the action's saved session transcript
# Out:     appends "still_missing=true|false" to $GITHUB_OUTPUT. When the
#          output file already exists and is non-empty, still_missing=false
#          and nothing is read or written.
missing=true
if [[ -s "$OUTPUT_PATH" ]]; then
  missing=false
elif [[ -f "$EXECUTION_FILE" ]]; then
  text=$(jq -r '
    (if type == "array" then . else [.] end)
    | [ .[] | select(.type == "assistant") | (.message.content // [])[] | select(.type == "text") | .text ]
    | last // ""
  ' "$EXECUTION_FILE" 2>/dev/null || true)
  if [[ -z "$text" ]]; then
    # Newline-delimited stream-json instead of one JSON array.
    text=$(jq -sr '
      [ .[] | select(.type == "assistant") | (.message.content // [])[] | select(.type == "text") | .text ]
      | last // ""
    ' "$EXECUTION_FILE" 2>/dev/null || true)
  fi
  # Complete means the caller's verdict parser can read it: the mandated
  # Recommendation line, anchored, with a real verdict — not a mid-line quote
  # of the format, which would post with an "unknown" verdict.
  if [[ ${#text} -ge 200 ]] && grep -qE '^\*\*Recommendation:\*\*[[:space:]]+(APPROVE|REQUEST CHANGES|BLOCK MERGE)' <<<"$text"; then
    printf '%s\n' "$text" > "$OUTPUT_PATH"
    echo "♻️ Anthropic engine: recovered the review from the session transcript ($(wc -c < "$OUTPUT_PATH") bytes) — the model answered in chat instead of writing the file"
    missing=false
  fi
fi
echo "still_missing=$missing" >> "$GITHUB_OUTPUT"
