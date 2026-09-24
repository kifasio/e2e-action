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

## Merge gates set up in Kifas

When Kifas sets up a merge gate — or gives your coding agent the change to make — the gate's key only works together with its `gate-id`, and the job that runs the action must be able to request a GitHub identity token:

```yaml
jobs:
  kifas:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write   # this job only
    outputs:
      kifas_result: ${{ steps.kifas.outputs.suite-result }}
    steps:
      - id: kifas
        uses: kifasio/e2e-action@v1
        with:
          gate-id: <the gate id Kifas shows you>
          api-key: ${{ secrets.<the secret name Kifas shows you> }}
          suite: <the suite id Kifas shows you>
          target-url: ${{ needs.deploy.outputs.url }}
```

For every call the action requests a fresh token for the audience `kifas-github-gate` and sends it with the gate id, the run and its attempt, the repository id, the workflow file and revision, the event, and both the pull request's head and the tested revision. Kifas checks all of it against the signed token and against GitHub before it stores a build or starts the suite.

A gate key carries a single scope, `github_gate:run`. Only this action's three calls accept it — the build upload, the trigger and the status poll — and the upload and trigger also require the gate id and a GitHub identity token for a run of the gate's own repository. Every other Kifas API refuses the key. The suite only tests hosts the gate approved: the project's own address, hosts already seen in the repository's non-production deployments, a preview host that the deployment integration recorded at setup reported for the commit under test, or a preview subdomain of the project's own domain. A shared hosting domain such as `vercel.app` is never approved as a whole. Any other address is refused. `params` may add suite parameters but cannot replace `base_url` or `app_build_id`, which come from `target-url` and `app-artifact`.

Kifas stores `target-url` as the run's `base_url`, like any other suite parameter, so it must not carry a credential. The action masks the address's query and fragment in its own log, but Kifas does not treat them as secret. Password-protected previews are not supported.

A call Kifas could not answer is retried for the same run attempt; Kifas admits each attempt once, so a retry never starts a second suite. Re-running the workflow in GitHub is a new attempt and starts a new suite run.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | Yes | — | Kifas API key. Store as a GitHub secret. |
| `gate-id` | With a gate key | `''` | The merge gate's id. Required with the key a Kifas gate setup issued; the job then needs `permissions: id-token: write`. |
| `target-url` | No | `''` | URL of the deployed preview to test. |
| `app-artifact` | No | `''` | Name or path of an app artifact (mobile builds, etc.). |
| `environment` | No | `''` | Logical environment label forwarded to the run (e.g. `staging`, `preview`). |
| `suite` | No | `''` | Suite to run: its slug (`smoke`), `project/slug` (`web/smoke`), or its id. Defaults to the project's **All workflows** suite — every test you have. |
| `params` | No | `''` | Suite parameters, one `key=value` per line. `base_url` comes from `target-url` and `app_build_id` from `app-artifact`; anything set here wins. |
| `api-base` | No | `https://api.kifas.io` | Kifas API base URL. Override for self-hosted or staging. |

## Outputs

| Output | Description |
|--------|-------------|
| `suite-run-id` | The Kifas suite run this job started. |
| `suite-result` | `passed`, `failed` or `aborted` — the suite's terminal result. Set only when the run finished; a trigger failure, a timeout or a cancelled job leaves it empty, so a check that requires `passed` stays red. |

## Behaviour

1. Reads `GITHUB_SHA`, `GITHUB_REPOSITORY`, `GITHUB_REF_NAME`, `GITHUB_RUN_ID`, and the PR number (from `GITHUB_REF` or the event payload) automatically from the runner environment.
2. POSTs to `{api-base}/v1/github/runs` with the run context and your inputs. Kifas runs the whole suite — every test in it, in the suite's own concurrency policy.
3. Polls the returned `poll_url` every 5 s until the suite reaches a terminal status (`passed` | `failed` | `aborted`), timing out after 20 minutes.
4. Exits 0 if `conclusion === 'success'`; exits 1 otherwise with an annotated error message, and also when the job is cancelled.
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

The test suite is fully hermetic — it replaces `curl` with an in-process mock script via the `KIFAS_CURL` env var and exercises the trigger, poll and reporting paths (success, failure, aborted, absolute poll URL, PR number extraction, missing API key, artifact upload, the dashboard run link, the `suite` input, and `params` line parsing), and the merge-gate calls: the identity token and context on the upload and the trigger, retries of a lost answer, a final refusal, signed-address masking, the outputs, a timeout and a cancelled job.
