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

Add a step **after your build step and before your Cloudflare Pages publish
step**, so the file lands in the final build output and gets deployed with it.
No checkout of `shared-actions` is needed — referencing the action with `uses:`
is enough.

Example from a production workflow triggered by pushing a `production_*` tag
(derivatives-trader style, where the deployed output is `packages/core/dist`):

```yaml
on:
  push:
    tags:
      - production_*

# ...

steps:
  - name: Checkout
    uses: actions/checkout@v4

  - name: Build
    uses: "./.github/actions/build"
    with:
      NODE_ENV: production
      # ...

  - name: Generate app-info.json
    uses: "deriv-com/shared-actions/.github/actions/generate_app_info@master"
    with:
      version: ${{ github.ref_name }} # the production_* tag that triggered the workflow
      output_dir: packages/core/dist

  - name: Publish to Cloudflare Pages Production
    uses: "./.github/actions/publish_to_pages_production"
    with:
      CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

`output_dir` must be the same directory your publish step deploys (the
argument to `wrangler pages deploy`), so `app-info.json` ends up at the site
root.

### Where does the tag come from?

Pass whatever identifies the release in your pipeline. Common sources:

```yaml
# Workflow triggered by pushing a tag (e.g. production_*)
version: ${{ github.ref_name }}

# Production workflow triggered manually with a tag input
version: ${{ github.event.inputs.tag }}

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
