# kifasio/e2e-action

Trigger a [Kifas](https://kifas.io) run and block until it completes.
The GitHub job's pass/fail **is** the required check — exit 0 means Kifas's outcome is `success` or `neutral` (a problem on Kifas's side never fails your job), exit 1 means a bug, an update waiting for your approval, a stopped run, a timeout, or a failed API call.

## Quick start

```yaml
- uses: kifasio/e2e-action@v1
  with:
    api-key: ${{ secrets.KIFAS_API_KEY }}
    target-url: ${{ steps.deploy.outputs.url }}
```

## Full example

```yaml
name: E2E checks

on:
  pull_request:

jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy preview
        id: deploy
        run: echo "url=https://pr-${{ github.event.pull_request.number }}.preview.example.com" >> "$GITHUB_OUTPUT"

      - name: Kifas E2E checks
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

## GitHub checks set up in Kifas

When Kifas sets up GitHub checks — or gives your coding agent the change to make — the checks' key only works together with their `gate-id`, and the job that runs the action must be able to request a GitHub identity token:

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
          gate-id: <the setup ID Kifas shows you>
          api-key: ${{ secrets.<the secret name Kifas shows you> }}
          suite: <the suite id Kifas shows you>
          target-url: ${{ needs.deploy.outputs.url }}
```

For every call the action requests a fresh token for the audience `kifas-github-gate` and sends it with the setup ID, the run and its attempt, the repository id, the workflow file and revision, the event, and both the pull request's head and the tested revision. Kifas checks all of it against the signed token and against GitHub before it stores a build or starts the suite.

A GitHub checks key carries a single scope, `github_gate:run`. Only this action's three calls accept it — the build upload, the trigger and the status poll — and the upload and trigger also require the setup ID and a GitHub identity token for a run of the checks' own repository. Every other Kifas API refuses the key. The suite only tests the hosts the Kifas setup shows under "Where Kifas will test": the project's own address, the hosts you confirmed there, and a preview host that the deployment integration recorded at setup reported for the commit under test. A `*.` entry you type covers only hosts under your own domain that the project already uses, and a shared hosting domain such as `vercel.app` is never approved. Any other address is refused. `params` may add suite parameters but cannot replace `base_url` or `app_build_id`, which come from `target-url` and `app-artifact`.

Kifas stores `target-url` as the run's `base_url`, like any other suite parameter, so it must not carry a credential. The action masks the address's query and fragment in its own log, but Kifas does not treat them as secret. Password-protected previews are not supported.

A call Kifas could not answer is retried for the same run attempt; Kifas admits each attempt once, so a retry never starts a second suite. Re-running the workflow in GitHub is a new attempt and starts a new suite run.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | Yes | — | Kifas API key. Store as a GitHub secret. |
| `gate-id` | With a GitHub checks key | `''` | The GitHub checks setup ID. Required with the key a Kifas GitHub checks setup issued; the job then needs `permissions: id-token: write`. |
| `target-url` | No | `''` | URL of the deployed preview to test. |
| `app-artifact` | No | `''` | Name or path of an app artifact (mobile builds, etc.). |
| `environment` | No | `''` | Logical environment label forwarded to the run (e.g. `staging`, `preview`). |
| `suite` | No | `''` | Suite to run: its slug (`smoke`), `project/slug` (`web/smoke`), or its id. Defaults to the project's **All workflows** suite — every test you have. |
| `params` | No | `''` | Suite parameters, one `key=value` per line. `base_url` comes from `target-url` and `app_build_id` from `app-artifact`; anything set here wins. |
| `api-base` | No | `https://api.kifas.io` | Kifas API base URL. Override for self-hosted or staging. |
| `outcome-wait-minutes` | No | `10` | After the tests finish, how long to wait for Kifas's final outcome: why a test failed, or an update to a test proven and waiting for you. |
| `wait-for-result` | No | `true` | `false` ends the job right after the tests start when Kifas posts the **Kifas** check on the commit. Require that check instead of this job first. |

## Outputs

| Output | Description |
|--------|-------------|
| `suite-run-id` | The Kifas suite run this job started. |
| `suite-result` | `passed`, `failed`, `aborted` or `unreported` (its tests reported no result) — the suite's terminal result. Set only when the run finished; a trigger failure, a timeout or a cancelled job leaves it empty, so a check that requires `passed` stays red. |
| `conclusion` | Kifas's final outcome: `success`, `failure`, `neutral` (a problem on Kifas's side), `action_required` (an update waits for your approval) or `cancelled`. |

## Behaviour

1. Reads `GITHUB_SHA`, `GITHUB_REPOSITORY`, `GITHUB_REF_NAME`, `GITHUB_RUN_ID`, and the PR number (from `GITHUB_REF` or the event payload) automatically from the runner environment.
2. POSTs to `{api-base}/v1/github/runs` with the run context and your inputs. Kifas runs the whole suite — every test in it, in the suite's own concurrency policy.
3. Polls the returned `poll_url` every 5 s until the suite finishes (timing out after 20 minutes), then waits up to `outcome-wait-minutes` for Kifas's final outcome.
4. Exits 0 when the outcome is `success` or `neutral` (a problem on Kifas's side never fails your job); exits 1 for a bug, an update waiting for your approval, a stopped run, a timeout, or a failed API call.
5. The PR comment and the step summary show the outcome, one line per test, with any test update as a diff and any multi-line error kept whole in a code block.
6. With the GitHub App's Checks permission, Kifas also posts the result as the **Kifas** check on the commit and updates it when you approve or reject a test update in Kifas.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Kifas's outcome is `success` (tests passed, possibly with an update) or `neutral` (a problem on Kifas's side — never fails your job). |
| `1` | Kifas's outcome is `failure` (a bug) or `action_required` (an update waits for your approval), the run was `cancelled`, it timed out, or the API call errored. |

## Requirements

`jq` must be available on the runner. `ubuntu-latest` GitHub-hosted runners include it. For custom runners, install via your package manager.

## Running the tests locally

```bash
bash actions/e2e-action/run.test.sh
```

The test suite is fully hermetic — it replaces `curl` with an in-process mock script via the `KIFAS_CURL` env var and exercises the trigger, poll and reporting paths (success, failure, aborted, absolute poll URL, PR number extraction, missing API key, artifact upload, the dashboard run link, the `suite` input, and `params` line parsing), and the GitHub checks calls: the identity token and context on the upload and the trigger, retries of a lost answer, a final refusal, signed-address masking, the outputs, a timeout and a cancelled job.
