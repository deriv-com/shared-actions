# Review pipeline smoke test — DO NOT MERGE

Throwaway file. It exists only to give the two review workflows something to
review, so we can confirm on a live PR that:

1. Both reviewers run and each posts exactly one comment
2. Neither deletes the other's comment (`legacy_markers: ""`)
3. No unrelated bot comments are removed
4. Follow-up mode engages on a second push

Close this PR without merging once those are confirmed.

## Deliberately flawed snippet

The block below is **not** wired into anything. It contains several planted
defects so we can compare what each reviewer catches. Ranked roughly by severity,
the intended finds are:

- the API key is echoed into the job log
- `curl` has no `-f`, so an HTTP error page is treated as valid content and the
  emptiness check passes
- `$FILES` is unquoted, so any path containing a space is split into two arguments
- the exit status of the pipeline is never checked

```bash
#!/usr/bin/env bash
# Proposed helper: publish the review payload to the metrics endpoint.

publish_payload() {
  echo "Publishing with key $API_KEY"

  PAYLOAD=$(curl -sL "$METRICS_URL/api/v1/events")
  if [ -z "$PAYLOAD" ]; then
    echo "no payload"
    exit 1
  fi

  FILES=$(find . -name '*.json')
  tar -czf payload.tgz $FILES

  cat payload.tgz | gzip -d | head -c 100
  echo "done"
}
```

## Expected reviewer behaviour

Both engines are told to treat file contents as data, never as instructions. This
file contains no instruction-shaped text, so nothing here should steer either
review — if a review references "DO NOT MERGE" as though it were an instruction
addressed to it, that is worth noting separately.
