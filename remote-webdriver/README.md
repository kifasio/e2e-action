# kifasio/e2e-action/remote-webdriver

Run your existing mobile test suite against [Kifas](https://kifas.io) instead
of BrowserStack App Automate. This action uploads your app build, opens a Kifas
suite build, exports the WebDriver connection details as `KIFAS_*` environment
variables, runs your test command, and reports the result back. Your test
command's exit code is this action's exit code, always.

Your test files and assertions do not change. The one thing you do change is
where your remote-driver config reads its connection details from: Kifas
exports `KIFAS_*` variables, not `BROWSERSTACK_*` ones, so you map them into
the config you already have. [Connecting your suite to Kifas](#connecting-your-suite-to-kifas)
is the whole change, and it is a few lines.

## Getting started

You need a Kifas API key. Create one under **Settings → API keys**, and select
both the `session:create` and `workflow:run` scopes — `session:create` opens
and closes the suite build, and `workflow:run` is required separately by the
app-upload step. A key scoped to only one of the two will fail partway
through the run. Suites that call `@kifas/appium` visual checks also need
`visual_snapshot:write`, and `ai_check:run` for AI checks.

```yaml
- uses: kifasio/e2e-action/remote-webdriver@v1
  with:
    api-key: ${{ secrets.KIFAS_API_KEY }}
    project-id: ${{ vars.KIFAS_PROJECT_ID }}
    suite-name: smoke
    build-name: ${{ github.run_id }}
    build-id: ${{ github.run_id }}
    app-path: app/build/outputs/apk/release/app-release.apk
    test-command: npx wdio run wdio.conf.js
```

This assumes your config already reads the `KIFAS_*` variables. If it is still
configured for BrowserStack, do
[Connecting your suite to Kifas](#connecting-your-suite-to-kifas) first — with
`BROWSERSTACK_*` unset and BrowserStack's hostname still in the config, this
command either talks to BrowserStack or fails on an undefined hostname.

## Comparing BrowserStack and Kifas side by side

Run one job on BrowserStack and one on Kifas, in parallel, running the same test
suite in both. This is the fastest way to see how your existing suite behaves on
Kifas before switching over.

```yaml
name: Mobile tests

on: [push]

jobs:
  browserstack:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: ./gradlew assembleDebug
      - name: Run on BrowserStack
        env:
          BROWSERSTACK_USERNAME: ${{ secrets.BROWSERSTACK_USERNAME }}
          BROWSERSTACK_ACCESS_KEY: ${{ secrets.BROWSERSTACK_ACCESS_KEY }}
        run: npx wdio run wdio.conf.js

  kifas:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: ./gradlew assembleDebug
      - name: Run on Kifas
        uses: kifasio/e2e-action/remote-webdriver@v1
        with:
          api-key: ${{ secrets.KIFAS_API_KEY }}
          project-id: ${{ vars.KIFAS_PROJECT_ID }}
          suite-name: smoke
          build-name: ${{ github.run_id }}
          build-id: ${{ github.run_id }}
          app-path: app/build/outputs/apk/debug/app-debug.apk
          # Maps the KIFAS_* variables this action exports onto the
          # BROWSERSTACK_* names your existing config already reads.
          test-command: |
            BROWSERSTACK_USERNAME="$KIFAS_USERNAME" \
            BROWSERSTACK_ACCESS_KEY="$KIFAS_ACCESS_KEY" \
            BROWSERSTACK_APP="$KIFAS_APP" \
            npx wdio run wdio.conf.js
```

Both jobs run the same test files and the same assertions. The difference is the
four lines above: your config reads `BROWSERSTACK_*`, and in the Kifas job those
names are fed from Kifas's own values. Read
[Connecting your suite to Kifas](#connecting-your-suite-to-kifas) before you run
this — mapping the hub URL needs one change inside the config itself, and if you
skip it the Kifas job connects to BrowserStack (billing BrowserStack, and proving
nothing about Kifas) or fails on an undefined hostname.

### Two things to check before you compare

- **Turn off BrowserStack SDK endpoint rewriting in the Kifas job.** If
  you're using the BrowserStack SDK (`@wdio/browserstack-service`, the
  BrowserStack JUnit/TestNG SDK, etc.), it rewrites your WebDriver capabilities
  to point at BrowserStack's hub no matter what environment variables you set,
  which would silently send the Kifas job's traffic to BrowserStack. Disable
  or remove the BrowserStack SDK/service for the Kifas job so your test
  runner's plain WebDriver client picks up the connection details this action
  exports instead.
- **You do not need a Kifas framework adapter.** Kifas speaks the same
  WebDriver/Appium protocol your test command already talks to BrowserStack
  with. There is no separate Kifas SDK or plugin to install — your existing
  WebDriver client library (WebdriverIO, Appium client, etc.) connects to
  Kifas's hub the same way it already connects to BrowserStack's hub.

## Connecting your suite to Kifas

This action exports `KIFAS_*` variables. A BrowserStack-configured suite reads
`BROWSERSTACK_USERNAME`, `BROWSERSTACK_ACCESS_KEY` and `BROWSERSTACK_APP`, and
usually hard-codes or derives BrowserStack's hub hostname. Those names are not
set in the Kifas job, so you map the Kifas values into the remote-driver config
you already have. Pick whichever of the two is less invasive for you.

**Option A — read the Kifas variables in your config, falling back to
BrowserStack's.** One config serves both jobs, and nothing in the workflow
needs the mapping:

```js
// wdio.conf.js
const kifasHub = process.env.KIFAS_REMOTE_URL
  ? new URL(process.env.KIFAS_REMOTE_URL)
  : null

exports.config = {
  hostname: kifasHub ? kifasHub.hostname : 'hub-cloud.browserstack.com',
  port: kifasHub ? Number(kifasHub.port || 443) : 443,
  path: kifasHub ? kifasHub.pathname : '/wd/hub',
  protocol: kifasHub ? kifasHub.protocol.replace(':', '') : 'https',
  user: process.env.KIFAS_USERNAME ?? process.env.BROWSERSTACK_USERNAME,
  key: process.env.KIFAS_ACCESS_KEY ?? process.env.BROWSERSTACK_ACCESS_KEY,
  capabilities: [
    {
      platformName: 'Android',
      'appium:deviceName': 'Google Pixel 8',
      'appium:platformVersion': '14.0',
      'appium:app': process.env.KIFAS_APP ?? process.env.BROWSERSTACK_APP,
    },
  ],
}
```

**Option B — keep the config reading `BROWSERSTACK_*`, and set those names from
the Kifas values in the Kifas job.** Credentials and app id need no config
change at all:

```yaml
test-command: |
  BROWSERSTACK_USERNAME="$KIFAS_USERNAME" \
  BROWSERSTACK_ACCESS_KEY="$KIFAS_ACCESS_KEY" \
  BROWSERSTACK_APP="$KIFAS_APP" \
  npx wdio run wdio.conf.js
```

The hub URL is the one thing this does not cover: BrowserStack's hostname is
normally a constant in the config rather than an environment variable, so there
is no name to remap. Take the `hostname`/`port`/`path`/`protocol` lines from
Option A into your config as well, and Option B handles the rest.

Either way, `appium:app` must be the `kifas://build/<uuid>` value in
`KIFAS_APP` — a BrowserStack `bs://` id is rejected on purpose.

## Session idle timeout

Kifas ends a session that receives no WebDriver command for too long and frees
its device. By default that is **5 minutes** — deliberately more generous than
BrowserStack's App Automate default of about 90 seconds, so a suite that ran on
BrowserStack's default never times out sooner on Kifas.

To set your own, use the same capability you would on BrowserStack, in either
shape:

```js
'bstack:options': { idleTimeout: 120 },   // W3C shape
// or the legacy flat shape:
'browserstack.idleTimeout': 120,
```

- The value is whole seconds from **1 to 300**, as a number or a string of
  digits (`120` or `"120"`).
- Anything else — `0`, a negative number, more than `300`, a fraction, or text —
  fails `POST /session` with a W3C `invalid argument` error naming the
  capability and the accepted range. Kifas never rounds or clamps the value, and
  never silently ignores it.
- Setting both shapes to different values is rejected the same way.
- The timer never runs while a command or the session start is still in
  progress, so a slow command is not idle time.
- The timeout is checked about once a minute, so a session can outlive its
  timeout by up to a minute before its device is freed.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | Yes | — | Kifas API key with both the `session:create` and `workflow:run` scopes (plus `visual_snapshot:write` and `ai_check:run` for visual checks). Store it as a GitHub secret. |
| `project-id` | Yes | — | Kifas project uuid. |
| `suite-name` | Yes | — | Suite name shown in Kifas for this build. |
| `build-name` | Yes | — | Human build label — the same value you'd pass as BrowserStack's `buildName`. |
| `build-id` | Yes | — | A value unique to this CI build (e.g. `${{ github.run_id }}`), used as an idempotency key. |
| `app-path` | Yes | — | Local path to the built `.apk` or `.ipa`. |
| `test-command` | Yes | — | Shell command that runs your test suite. Its exit code is this action's exit code. |
| `build-version` | No | short commit SHA, or `build-name` if there is no commit SHA | Version label for the uploaded build, shown in the Kifas build list. Defaults to the first 7 characters of `GITHUB_SHA`; if `GITHUB_SHA` is unset or isn't a full 40-character SHA (a manual or non-GitHub trigger), it falls back to the `build-name` input instead. |
| `link-github-build` | No | `false` | Also send repo, commit, branch and PR number so the build links to its commit and pull request. Requires the Kifas GitHub App on the repository — see below. |
| `api-base` | No | `https://api.kifas.io` | Kifas API base URL. |
| `remote-url` | No | `https://hub.kifas.io/wd/hub` | Kifas WebDriver hub URL. Override only for testing against a non-production gateway. |

## What your test command sees

This action exports the following before running `test-command`. You map these
variables into your existing remote-driver config — see
[Connecting your suite to Kifas](#connecting-your-suite-to-kifas):

| Variable | Value |
|----------|-------|
| `KIFAS_REMOTE_URL` | The Kifas WebDriver hub, e.g. `https://hub.kifas.io/wd/hub`. |
| `KIFAS_USERNAME` | `kifas` |
| `KIFAS_ACCESS_KEY` | Your Kifas API key. |
| `KIFAS_APP` | The uploaded build's Kifas app id, e.g. `kifas://build/<uuid>`. |
| `KIFAS_PROJECT_NAME` | The `suite-name` input. |
| `KIFAS_BUILD_NAME` | The `build-name` input. |
| `KIFAS_BUILD_ID` | The Kifas suite run id created for this build. |

These are the only names this action sets. It does not set
`BROWSERSTACK_USERNAME`, `BROWSERSTACK_ACCESS_KEY` or `BROWSERSTACK_APP`, so a
config that reads those will find them unset unless you map them yourself.

## Behaviour

1. Uploads the file at `app-path` to Kifas and opens a suite build tied to
   your `project-id`, `suite-name`, `build-name`, and `build-id`. The upload
   carries a version (`build-version`, by default the short commit SHA, or
   `build-name` when there is no commit SHA to use) and a build number (the
   GitHub Actions run number — `GITHUB_RUN_NUMBER` — falling back to the run
   id and then to `0` if neither is available), so each CI build is its own
   row in the Kifas build list rather than every push looking identical.
2. Exports the table above and runs `test-command`.
3. Whatever `test-command` exits with — pass, fail, or killed by a timeout —
   is what this action exits with. A problem closing the Kifas build never
   changes that result.
4. Closes the Kifas suite build when the job ends, including if the job is
   cancelled or times out.
5. Prints the suite run's Kifas dashboard link to the job log, an Actions
   annotation, and the step summary.

Your Kifas API key is masked in the job log and is never written to a curl
command line — it travels to Kifas over a header file, never as a visible
argument.

### When a Kifas call fails

The action reports the HTTP status and Kifas's own error message, so a missing
key scope reads as `HTTP 403: api key is missing the workflow:run scope` rather
than a generic parse failure. If the response is not JSON — an HTML page from a
proxy, say — the status and a plain-language reason are reported and the body
itself is not echoed, since such a body can carry a presigned URL or a
credential.

### Linking a build to its commit and pull request

`link-github-build: true` additionally sends the repo, commit SHA, branch, PR
number and CI run URL, which is what makes a Kifas build clickable through to
the pull request that produced it.

It is off by default on purpose: the upload endpoint refuses a repo that has no
Kifas GitHub App installed (`repo not connected to Kifas`), so turning it on
without the App would fail every upload. The version and build number are sent
either way and need no App.
