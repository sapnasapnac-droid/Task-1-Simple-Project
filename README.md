# Robust Dependency Update Workflow

A self-healing GitHub Actions workflow that automatically updates npm dependencies, verifies the project still builds and tests pass, and opens a pull request with a detailed report of what changed and what was held back.

Unlike a naïve `ncu -u && npm install` pipeline that dies on the first peer-dependency conflict or broken build, this workflow **iteratively identifies the packages causing problems and rolls them back**, producing the largest safe update set it can.

---

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [How to Run](#how-to-run)
- [Inputs](#inputs)
- [How It Works (Step by Step)](#how-it-works-step-by-step)
- [The Self-Healing Logic Explained](#the-self-healing-logic-explained)
- [What the PR Looks Like](#what-the-pr-looks-like)
- [Configuration & Customization](#configuration--customization)
- [Triggering from Slack (One-Click Button)](#triggering-from-slack-one-click-button)
- [What We Can Do Next](#what-we-can-do-next)
- [Troubleshooting](#troubleshooting)

---

## Features

- **Self-healing loop** — up to 20 attempts to converge on a working update set
- **Configurable update level** — `patch`, `minor`, or `latest` (majors)
- **Build & test verification** — runs `npm run build` and `npm test` if defined
- **Smart rollback** — identifies the major bumps responsible for failures and rejects only those
- **Network-aware** — retries transient `ETIMEDOUT`/`ECONNRESET` errors instead of dying
- **Owned-deps filter** — only rejects packages declared in your own `package.json`, never transitive noise
- **Detailed PR reports** — shows exactly which packages were held back and what versions they could have been bumped to
- **Test-failure flagging** — PRs with failing tests are titled `⚠️ [TESTS FAILING]` and labelled `tests-failing` for human review
- **No empty PRs** — skips PR creation when nothing actually changed

---

## Prerequisites

- A Node.js project with `package.json` and `package-lock.json` committed
- (Optional) `build` and `test` scripts in `package.json` — the workflow auto-detects them
- GitHub Actions enabled on the repository
- The workflow file placed at `.github/workflows/dependency-update.yml`

The workflow declares the permissions it needs (`contents: write`, `pull-requests: write`, `issues: write`), so no extra setup is required if your repo allows Actions to create PRs.

> **Note:** If your repository setting *"Allow GitHub Actions to create and approve pull requests"* is disabled, enable it under **Settings → Actions → General → Workflow permissions**.

---

## How to Run

The workflow is triggered manually via the GitHub UI:

1. Go to the **Actions** tab in your repository
2. Select **Robust Dependency Update Flow** from the left sidebar
3. Click **Run workflow**
4. Choose an `update_level` (`patch`, `minor`, or `latest`)
5. Click the green **Run workflow** button

---

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `update_level` | yes | `minor` | How far to bump dependencies. `patch` = bugfixes only, `minor` = backward-compatible features, `latest` = include majors |

**Recommendation:**
- Run `minor` regularly (e.g. monthly) — almost always safe.
- Run `latest` deliberately when you're ready to handle major-version migrations.

---

## How It Works (Step by Step)

### Step 1 — Checkout & Setup
- Checks out the repository
- Sets up Node.js 20 with npm caching
- Sets `HUSKY=0` to prevent pre-commit hooks from interfering with CI installs

### Step 2 — Baseline Install
Runs `npm ci` against the existing lockfile to establish a known-good starting point. Output is teed to `/tmp/install.log` for later diagnostics.

### Step 3 — Probe Phase
Installs `npm-check-updates` globally, then runs `ncu` against a **copy** of `package.json` to discover everything that *could* be updated at the chosen level. This list is saved as `PROBE` — it's used later to tell reviewers what was held back.

Backups of the original `package.json` and `package-lock.json` are saved to `/tmp/` so each loop iteration can start from a clean slate.

### Step 4 — Self-Healing Loop (up to 20 attempts)

Each iteration does the following:

1. **Reset** — restore `package.json` and `package-lock.json` from backup, delete `node_modules`/`lib`/`dist`
2. **Update** — run `ncu -u --target <level>` with the current reject list applied
3. **Install** — run `npm install`
   - If it succeeds → continue to build
   - If it fails with a network error → wait 10s, retry the same iteration
   - If it fails with `ERESOLVE` → parse the log, identify the conflicting packages we own, add them to the reject list, restart the loop
   - Any other install failure → abort the workflow
4. **Build** (if `scripts.build` exists)
   - If it succeeds → continue to tests
   - If it fails → identify packages that received **major** version bumps, add them to the reject list, restart
5. **Test** (if `scripts.test` exists)
   - If it passes → mark success, exit loop
   - If it fails and there are still majors to roll back → reject those, restart
   - If it fails with no more majors to roll back → mark `test_outcome=failure` and **still** exit successfully (the PR will be flagged for human review)

### Step 5 — Build the Held-Back Report
Compares the final `package.json` against the probe data to produce a Markdown-formatted list of every package that *could* have been bumped but wasn't, with old → available versions.

### Step 6 — Check for Changes
Runs `git diff --quiet` on the lockfile and manifest. If nothing changed (e.g. everything was rolled back), the workflow exits without creating an empty PR.

### Step 7 — Create Pull Request
Uses `peter-evans/create-pull-request@v7` to open a PR with:
- A descriptive title (prefixed `⚠️ [TESTS FAILING]` if tests didn't pass)
- Labels reflecting the outcome (`dependencies`, `automated`, `tests-failing`, `major-update`, etc.)
- A body containing the update summary, held-back list, and review guidance

---

## The Self-Healing Logic Explained

The loop is built around three helper functions:

### `make_reject_arg`
Combines `PERMANENT_REJECT` (packages you never want auto-bumped, e.g. `typescript`) with `REJECT_LIST` (packages discovered during this run) into a single comma-separated argument for `ncu --reject`.

### `identify_major_bumps`
Diffs the current `package.json` against the original to find every package whose **major version number** changed. This is what gets rolled back when a build or test fails — the assumption being that minor/patch bumps rarely break things, but majors often do.

### `filter_new_rejections`
Removes any package already on the reject list before adding new entries. Without this, the same package could be "rediscovered" in every iteration and the loop would spin forever.

### Loop termination
The loop exits as soon as install + build + test all pass cleanly, **or** when tests fail with no more majors available to roll back (in which case the PR is created but flagged). If 20 attempts pass without convergence, the workflow fails with a clear error message.

---

## What the PR Looks Like

### Title
```
chore: Dependency update (minor)
```
or, if tests are still failing:
```
⚠️ [TESTS FAILING] chore: Dependency update (latest)
```

### Labels
- Always: `dependencies`, `automated`
- If `update_level=latest`: also `major-update`
- If tests failed: `dependencies`, `needs-review`, `tests-failing`

### Body
```markdown
Automatic dependency update via self-healing workflow.

## Update Summary
- Update level: `minor`
- Attempts to converge: 3
- Test result: success

## Held back from this run
- **react**: `17.0.2` → `18.2.0`
- **eslint**: `8.57.0` → `9.0.0`

## Review Guidance
✅ Tests passed.
⚠️ Held-back packages above need a coordinated manual update — read each migration guide before bumping.
```

### Branch
The PR is created on a branch named:
```
chore/deps-<level>-<run_id>
```
which is auto-deleted on merge.

---

## Configuration & Customization

### Add packages to the permanent reject list
Edit the workflow:
```bash
PERMANENT_REJECT="typescript,react,webpack"
```
Anything listed here is never auto-bumped, regardless of update level.

### Change the maximum number of attempts
```bash
MAX_ATTEMPTS=20
```
Lower this if your CI minutes are precious; raise it for very large dependency trees.

### Change the Node.js version
```yaml
- name: Set up Node.js
  uses: actions/setup-node@v5
  with:
    node-version: '20'   # ← change here
```

### Add a scheduled trigger
To run automatically on a schedule, add to the `on:` block:
```yaml
on:
    workflow_dispatch:
        inputs: ...
    schedule:
        - cron: '0 9 1 * *'   # 09:00 UTC on the 1st of every month
```
Note that scheduled runs won't have `inputs.update_level`, so you'll need to default it inside the script or use `${{ inputs.update_level || 'minor' }}`.

### Add Slack notification
Append a step gated on `steps.changed.outputs.had_changes == 'true'`:
```yaml
- name: Notify Slack
  if: steps.changed.outputs.had_changes == 'true'
  run: |
    curl -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\"New dependency PR opened in ${{ github.repository }}\"}" \
      $SLACK_WEBHOOK_URL
  env:
    SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

---

## Triggering from Slack (One-Click Button)

Instead of asking team members to open GitHub → Actions → Run workflow every time, you can ship a Slack button that fires the workflow directly. Anyone on the team can trigger an update from the channel without ever leaving Slack.

### Architecture

```
┌────────────┐      ┌──────────────────┐      ┌──────────────┐
│   Slack    │ ───▶ │  Backend Endpoint │ ───▶ │  GitHub API  │
│  (Button)  │      │  (Lambda/Vercel)  │      │ (workflow    │
│            │      │                   │      │  dispatch)   │
└────────────┘      └──────────────────┘      └──────────────┘
```

Slack can't call GitHub's REST API directly (it can't store the secret token securely or attach the right headers), so a tiny backend sits in the middle. The backend's only job is: verify the Slack signature, then POST to GitHub's `workflow_dispatch` endpoint.

### Step 1 — Create a Slack App

### Step 2 — Generate a GitHub Token

### Step 3 — Deploy the Backend

### Step 4 — Post the Button to Slack

### Optional: Post the PR Link Back to Slack
Pair this with a final step inside the workflow itself that posts the resulting PR URL to the same channel via `chat.postMessage`, so the loop closes: click button → wait → PR link appears.

---

## What We Can Do Next

Ideas worth exploring once the workflow is in place:

### Quality & Safety
- **Add `npm audit` to the loop.** After tests pass, run `npm audit --audit-level=high` and either fail the build or add an "audit issues" section to the PR body.
- **Group related packages.** Treat `eslint`, `@typescript-eslint/*`, and `eslint-plugin-*` as a single rollback unit so they always move together.
- **Cross-platform testing.** Add a `strategy.matrix` over `[ubuntu-latest, windows-latest, macos-latest]` for the build/test step to catch OS-specific regressions before merging.
- **Multi-Node matrix.** Run the post-update build/test on every Node version your project supports.

### Automation & Workflow
- **Auto-merge clean PRs.** When `test_outcome=success` AND no packages were held back AND `update_level=patch`, enable GitHub's auto-merge so safe patches land without human review.
- **Scheduled cadence by level.** Run `patch` weekly, `minor` monthly, `latest` quarterly — each on its own cron schedule with sensible defaults.
- **Auto-assign reviewers.** Add `reviewers` and `team-reviewers` to `peter-evans/create-pull-request` so the right people get pinged automatically.
- **Auto-close stale dependency PRs.** If a new run supersedes an unmerged PR, close the old one with a comment pointing to the new one.

### Reporting & Visibility
- **Per-package changelogs.** For each bumped dependency, fetch the GitHub release notes between old and new version and append them to the PR body.
- **Dependency dashboard issue.** Maintain a single rolling issue that lists every held-back package across runs — a long-lived to-do list of upgrades that need manual work.
- **Slack summary.** Post a digest after each run: "Bumped 12 packages, held back 3 (react, eslint, webpack), tests passed."
- **Metrics.** Track convergence stats (attempts needed, time to converge) over time as workflow artifacts; useful for spotting when your dependency tree is getting harder to update.

### Developer Experience
- **GitHub App instead of PAT.** Use a GitHub App's short-lived installation token to dispatch the workflow from Slack, eliminating long-lived secrets.
- **PR comment commands.** Let reviewers comment `/update-deps minor` on any PR to re-run with a different level, using `issue_comment` triggers.
- **Local dry-run script.** Extract the loop logic into a standalone shell script so developers can run the same self-healing logic locally before triggering CI.

---

## Troubleshooting

### "Could not converge after 20 attempts"
The reject list grew too large or there's a fundamental conflict in your dependency tree. Check the workflow log for the final reject list — those packages may need a manual coordinated update.

### "ERESOLVE conflict with no actionable packages"
The peer-dependency conflict involves only transitive dependencies you don't directly own. You'll need to either add an `overrides` block in `package.json` or wait for the upstream package to fix it.

### "Non-ERESOLVE install failure"
Something other than a peer conflict broke the install — typically a deprecated package, a removed registry entry, or a broken postinstall script. Check `/tmp/install.log` in the workflow output.

### Tests fail every time even after rollback
If `identify_major_bumps` returns nothing but tests still fail, the regression is in a minor or patch bump. The workflow will ship the PR with `⚠️ [TESTS FAILING]` — investigate locally by checking out the branch and bisecting.

### PR isn't being created
- Confirm **Settings → Actions → General → Workflow permissions** allows PR creation
- Confirm the workflow has `pull-requests: write` permission (it does by default in this file)
- Check that the run actually produced changes — `had_changes=false` is a clean exit, not an error
