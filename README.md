# kifasio/e2e-action

Trigger a [Kifas](https://kifas.io) run and block until it completes.
The GitHub job's pass/fail **is** the required check — exit 0 means the gate passed, exit 1 means it failed.

## Quick start

```yaml
- uses: kifasio/e2e-action@v1
  with:
    api-key: ${{ secrets.KIFAS_API_KEY }}
    target-url: ${{ steps.deploy.outputs.url }}
```

## Full example

```yaml
name: E2E gate

on:
  pull_request:

jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy preview
        id: deploy
        run: echo "url=https://pr-${{ github.event.pull_request.number }}.preview.example.com" >> "$GITHUB_OUTPUT"

      - name: Kifas E2E gate
        uses: kifasio/e2e-action@v1
        with:
          api-key: ${{ secrets.KIFAS_API_KEY }}
          target-url: ${{ steps.deploy.outputs.url }}
          environment: preview
          suite: smoke
          params: |
            locale=en-GB
            coupon_code=WELCOME10
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | Yes | — | Kifas API key. Store as a GitHub secret. |
| `target-url` | No | `''` | URL of the deployed preview to test. |
| `app-artifact` | No | `''` | Name or path of an app artifact (mobile builds, etc.). |
| `environment` | No | `''` | Logical environment label forwarded to the run (e.g. `staging`, `preview`). |
| `suite` | No | `''` | Suite to run: its slug (`smoke`), `project/slug` (`web/smoke`), or its id. Defaults to the project's **All workflows** suite — every test you have. |
| `params` | No | `''` | Suite parameters, one `key=value` per line. `base_url` comes from `target-url` and `app_build_id` from `app-artifact`; anything set here wins. |
| `api-base` | No | `https://api.kifas.io` | Kifas API base URL. Override for self-hosted or staging. |

## Behaviour

1. Reads `GITHUB_SHA`, `GITHUB_REPOSITORY`, `GITHUB_REF_NAME`, `GITHUB_RUN_ID`, and the PR number (from `GITHUB_REF` or the event payload) automatically from the runner environment.
2. POSTs to `{api-base}/v1/github/runs` with the run context and your inputs. Kifas runs the whole suite — every test in it, in the suite's own concurrency policy.
3. Polls the returned `poll_url` every 5 s until the suite reaches a terminal status (`passed` | `failed` | `aborted`), timing out after 20 minutes.
4. Exits 0 if `conclusion === 'success'`; exits 1 otherwise with an annotated error message.
5. The PR comment and the step summary list one line per test in the suite (`✅ name` / `❌ name — why`), plus the pass/fail counts.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Kifas gate **passed** (`conclusion: success`). |
| `1` | Kifas gate **failed**, timed out, or the API call errored. |

## Requirements

`jq` must be available on the runner. `ubuntu-latest` GitHub-hosted runners include it. For custom runners, install via your package manager.

## Running the tests locally

```bash
bash actions/e2e-action/run.test.sh
```

The test suite is fully hermetic — it replaces `curl` with an in-process mock script via the `KIFAS_CURL` env var and exercises the trigger, poll and reporting paths (success, failure, aborted, absolute poll URL, PR number extraction, missing API key, artifact upload, the dashboard run link, the `suite` input, and `params` line parsing).
