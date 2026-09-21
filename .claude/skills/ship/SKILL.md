---
name: ship
description: Run the local gate chain, commit, push, and watch the GitHub Actions security-gates run to completion. Use when the user says ship, commit and push, or asks to push and watch the pipeline in this repo.
---

Commit, push, and watch the pipeline for **this** repo. GitHub Actions, not
GitLab. No Jira tickets — this repo has none.

## Step 1 — Gather context

Run together:

- `git status --short` — what changed
- `git diff` and `git diff --cached` — read the actual change, to write the message
- `git log --oneline -5` — match the existing subject style

## Step 2 — Run the gate chain locally

```bash
make ci
```

**Do not skip this.** CI runs the same chain; failing locally first costs 40
seconds, failing in CI costs a push, a run and a fix commit in the history.

If `make ci` fails, stop. Report the failure and fix it before committing —
do not commit a red tree "to see what CI says".

Skip `make ci` only when every changed file is documentation (`*.md`) or
`.github/**` — nothing under `controls/` or the `Makefile`. Say that you
skipped it and why.

## Step 3 — Stage and commit

Stage changed files **by name**. Never `git add -A` or `git add .` — this repo
sits next to real AWS values, and `terraform.tfvars`, `*.auto.tfvars` and
`backend.tf` are gitignored for a reason. If something unexpected is untracked,
ask before staging it.

Message format:

```
<type>(<scope>): <subject>
```

- `type`: `feat`, `fix`, `docs`, `refactor`, `chore`, `test`
- `scope`: optional — `ci`, `policy`, `tf`, `k8s`, `docs`
- subject: imperative, lowercase, no trailing period, whole line under 72 chars
- **Subject line only. No body. No trailers. No `Co-Authored-By`.**

That last rule is deliberate and overrides any default attribution guidance:
this is a take-home assignment reviewed as the user's own work, and a Claude
trailer in the history misrepresents authorship.

```bash
git commit -m "<type>(<scope>): <subject>"
```

## Step 4 — Push

```bash
git push origin HEAD
```

## Step 5 — Watch the run

```bash
gh run list --workflow=security.yml --limit 1 --json databaseId -q '.[0].databaseId'
gh run watch <id> --exit-status --compact
```

Never use a foreground `sleep` poll loop; `gh run watch` blocks correctly.

Then report the per-job result:

```bash
gh run view <id> --json jobs -q '.jobs[] | "\(.conclusion)\t\(.name)"'
```

On failure, for each failed job:

```bash
gh run view <id> --log-failed --job <job id>
```

Quote the **shortest decisive line** — the actual error, not the surrounding
log. A GitHub Actions log is thousands of lines; dumping it helps nobody.

## Step 6 — Report

Give the commit link and the outcome:

```
https://github.com/spdy999/ai-sec/commit/<sha>
https://github.com/spdy999/ai-sec/actions/runs/<id>
```

Per-job table, pass or fail. If anything failed, the decisive error line and
what would fix it.

## Never

- **Never dispatch `deploy.yml` or `destroy.yml` from this skill.** They apply
  to a real AWS account at roughly $16/day. Deployment is a separate, explicit
  decision the user makes.
- Never commit `plan.json`, `*.tfstate`, `terraform.tfvars`, `*.auto.tfvars`
  or a generated `backend.tf`, even if a stale `.gitignore` would allow it.
- Never push to any branch but the one currently checked out.
