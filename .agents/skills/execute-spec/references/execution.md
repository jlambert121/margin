# Execution protocol for agents


Agent reference for execute-spec and review-change. Human instructions are in [DEVELOPMENT.md](../../../../DEVELOPMENT.md).

## Inputs and isolation

Before starting or resuming, the tool checks the source checkout for tracked and untracked changes. `docs/tasks/` artifacts, Markdown files (`.md`, `.markdown`, `.mdown`, `.mkdn`, `.mkd`, and `.mdx`, case-insensitive), and dotfiles or files inside dot-directories are allowed; normal Git-ignored build/dependency files are excluded. Renames check both paths. Other dirty files are listed and execution stops without stashing, committing, or copying them.

The base is the source checkout's HEAD, recorded at start. The tool validates a prepared task, snapshots its four planning files, and creates a branch/worktree from that base under the primary checkout's `.worktrees/<run-id>/`. Uncommitted prepared specs are captured explicitly; unrelated dirty source is never copied. Subsequent commands check that the source base and planning inputs still match. The agent edits and commits implementation only in the execution worktree.

The primary checkout's `.execution/active.json` enforces one active run across worktrees sharing this repository. Both `.worktrees/` and `.execution/` are Git-ignored and outside protected `.git`; source edits and builds do not require access to Git metadata, while Git setup and commits may still require approval. Existing run paths are not migrated. Source checks on resume apply to the original checkout; expected implementation edits belong in the execution worktree. Verification and review require committed implementation and a clean execution worktree except those same allowed paths.

## Commands

Run these from the source checkout; the run ID and worktree path are printed by start:

```sh
node tools/execution/task.mjs gate
node tools/execution/task.mjs start code-block-line-numbers
node tools/execution/task.mjs status code-block-line-numbers <run-id>
node tools/execution/task.mjs resume code-block-line-numbers <run-id>
node tools/execution/task.mjs verify code-block-line-numbers <run-id>
node tools/execution/task.mjs review code-block-line-numbers <run-id> /path/to/report.json
node tools/execution/task.mjs finish code-block-line-numbers <run-id>
node tools/execution/task.mjs stop code-block-line-numbers <run-id> 'Reason for stopping'
```

Use `stop` to retain an incomplete run and release its active slot, including when the source or inputs have changed. A stopped run is terminal; start a new run after resolving the cause. Worktrees and branches remain for inspection. Cleanup, merge, push, PR creation, and release are separate actions.

## Artifacts

```text
docs/tasks/<task>/
  original.md
  feedback.md
  spec.md
  state.json
  execution/<run-id>/
    state.json
    inputs/                  # captured planning files
    evidence.md
    reviews.md
    review-1.json            # added for each fresh review
    handoff.md
    logs/verification-1/     # commands, result.json, test home, temporary files
    screenshots/
```

Execution state records the base, branch/worktree, input hashes, verification attempts, review rounds, and stage. Stages are implementing, verifying, awaiting-review, reviewed, ready-for-review, and incomplete. Scripts manage state; do not manually edit it to bypass gates. `status` shows saved state; `resume` rechecks source and input validity before continuing. It does not automatically launch an agent or recover a crashed subprocess.

Planning files and handoff/review summaries can be committed as task artifacts. Logs and screenshots are retained locally; inspect generated test homes and temporary files before deciding what to commit. Previous attempts are not overwritten.

## Verification and desktop checks

Verification runs in the worktree, sequentially: Qlty formatting of changed existing/new files, npm test, the additional native UI path, app build, Qlty smells, and Qlty check. Formatting changes must be inspected and committed before revalidation. Existing findings remain visible; nonzero checks prevent passing verification. The scripted timeout is ten minutes per command; failures and timeout details are logged.

Each attempt uses a fresh `CFFIXED_USER_HOME` preferences directory and `TMPDIR`; native/document runners use their existing fixture recovery stores and test identities. A machine-local lock prevents simultaneous desktop verification by this tool. This isolates test state; it is not an operating-system sandbox. Do not launch the user's normal Margin instance for acceptance checks. Additional interaction checks must use a fixture host with equivalent isolation; otherwise record unavailable evidence. Screenshots produced by the WebKit runner are copied into screenshots/ with the verification attempt number.

Commands are tied to the committed revision. Changed source, changed captured planning inputs, altered verification logs, or a changed reviewed revision prevent completion. The test home is not the user's home. When a process is killed abruptly, operation.lock or the desktop lock may remain: inspect the recorded path and confirm no process is running before manually removing only the stale lock. The desktop lock is named margin-desktop-verification.lock in the invoking user's temporary directory. An active run remains reserved until finish or stop.

## Independent review

A fresh reviewer receives the run path, source checkout and execution worktree paths, captured spec, repository instructions, prior findings, and access to implementation/tests. The skill coordinates this session; scripts do not launch reviewer subprocesses. Save a JSON report like this (use the actual revision, paths, and observations):

```json
{
  "revision": "full-worktree-commit-sha",
  "reviewer": "fresh session identity",
  "summary": "What was inspected and exercised, including limitations.",
  "verdict": "pass",
  "criteria": [
    {
      "id": "AC-1",
      "result": "passed",
      "summary": "Concrete observation and expected result.",
      "evidence": ["logs/verification-1/tests.log", "screenshots/verification-1.png"]
    }
  ],
  "findings": [],
  "resolutions": []
}
```

Include every criterion exactly once. Results are passed, failed, or unavailable; evidence paths must refer to nonempty files inside this run. The tool captures their hashes when recording the report. A verdict of pass requires all criteria passed and all findings resolved. Evidence.md provides the readable criterion-to-evidence handoff; JSON reports supply the checked mappings.

Use changes-requested when changes are needed. Findings use unique IDs across the whole run, severity blocking or minor, summary, and evidence describing the defect and consequence. A later report resolves a prior finding with `{"id":"F-1","summary":"Fix or reason for rejection, independently checked."}` in resolutions. Review reports are retained and hashed; at most three rounds can be recorded. At the limit, stop incomplete if findings remain. A genuine scope/spec problem returns to planning rather than rewriting acceptance criteria during execution.

## Completion

Complete handoff.md with delivered behavior, criterion evidence, limitations, and problems or proposed workflow improvements. Finish requires passing verification and a fresh passing review of the exact current commit, unchanged evidence/logs, and a completed handoff. It marks ready-for-review and releases the active slot. It does not mean merged or released.

Freshness of the reviewer and truth of behavioral evidence remain agent judgments. These scripts enforce recorded structure and revision consistency, not semantic correctness or tamper-proof history. The first version is coordinated by the execute-spec skill; a standalone autonomous controller, automated crash recovery, dependency graphs, integration branches, PR/CI management, and release smoke tests remain deferred.

