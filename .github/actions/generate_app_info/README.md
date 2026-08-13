# generate_app_info

Composite action that creates or updates an `app-info.json` file in your build
output directory, stamping it with the production tag of the release. Frontends
(or monitoring) can then fetch `/app-info.json` to know exactly which version
is deployed.

## What it does

Given a tag, it writes this file into the directory you point it at:

```json
{
  "version": "<the tag you passed>"
}
```

- If the file does not exist, it is created.
- If it already exists, it is overwritten with the new version.
- The JSON is generated with `jq`, so any special characters in the tag are
  safely escaped.
- The action fails early with a clear error if the target directory does not
  exist (e.g., if you run it before your build step).

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `version` | ✅ yes | — | The production tag to write as the version (e.g., `production_V20260813_0`) |
| `output_dir` | no | `.` | Directory in which your compiled frontend is located (where `app-info.json` will be written) |

## Usage

Add a step **after your build step** (so the file lands in the final build
output and gets deployed with it):

```yaml
steps:
  - name: Checkout
    uses: actions/checkout@v4

  - name: Build
    run: npm run build

  - name: Generate app-info.json
    uses: "deriv-com/shared-actions/.github/actions/generate_app_info@master"
    with:
      version: ${{ github.event.inputs.tag }}
      output_dir: dist

  # ... your deploy step (Cloudflare Pages, Vercel, etc.)
```

### Where does the tag come from?

Pass whatever identifies the release in your pipeline. Common sources:

```yaml
# Production workflow triggered manually with a tag input
version: ${{ github.event.inputs.tag }}

# Workflow triggered by pushing a tag
version: ${{ github.ref_name }}

# Release event
version: ${{ github.event.release.tag_name }}
```

### Verifying the deployment

After deploy, the file is served from the site root:

```bash
curl https://your-app.example.com/app-info.json
# {"version": "production_V20260813_0"}
```

## Notes

- `output_dir` must already exist — run this action after the build, not before.
- Everything in this repo is consumed at `@master`, so changes to this action
  are live for all consumers as soon as they merge.
