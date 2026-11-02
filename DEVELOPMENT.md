# Development

## Skills

- `$draft-spec <intent>` investigates the code and writes a draft with your intent, acceptance criteria, and a test plan.
- `$prepare-spec <task-slug>` gets independent reviews of the draft and produces a specification ready to implement; run it after drafting.
- `$execute-spec <task-slug>` implements the prepared specification, runs checks, and coordinates independent review and fixes.
- `$review-change` reviews the implementation; execute-spec calls it, so you do not need to invoke it separately.

## Using the workflow

Describe the change with `$draft-spec`, then use the task name it returns for the next two steps. For example:

```text
$draft-spec Add line numbers to code blocks
$prepare-spec code-block-line-numbers
$execute-spec code-block-line-numbers
```

Drafting and preparation are separate steps. Execution starts only after preparation succeeds, and handles one task at a time.

Execution creates a separate Git working copy for the changes. It builds and tests the app, checks each acceptance criterion, and gets an independent review, with up to three review rounds. It leaves the result ready for your review; merging, pushing, and releasing are separate actions.

## When work stops

If there are uncommitted code changes, execution lists them and stops. Task files, Markdown, dotfiles, and files inside dot-directories are allowed; these exclusions do not copy those changes into the separate working copy.

The agent also stops if it needs a product decision, cannot complete a required check, or still has unresolved findings after three reviews. Ask it to explain what remains and continue when the cause is resolved; it keeps previous results rather than discarding them.

Desktop tests use temporary test files and separate settings. Keep a normal macOS desktop session available for those checks.

## Results

The specification and planning feedback are in `docs/tasks/<task>/`. Each execution attempt has its own folder under `docs/tasks/<task>/execution/`, containing a handoff, review findings, test results, and screenshots.

Start with `handoff.md` for what changed, which checks passed, and any remaining limitations. The agent provides the working copy and branch for inspecting the changes.

If a new skill does not appear in an already-open session, refresh the session or ask the agent to read its SKILL.md under `.agents/skills/`.

## Checks

```sh
npm test                # loop tools, syntax, workspace, native, document, and WebKit tests
npm run test:loops      # planning and execution tools only
npm run test:native     # additional desktop UI checks
npm run build           # build the app
mise exec -- qlty smells --all
mise exec -- qlty check --all
```

The agent runs these checks during execution and reports failures. You do not need to run them again to use the skills.

## TODO

Reference: [Loops, graphs & harnesses – getting quality out of a software factory](https://www.ivokund.com/loops-graphs-harnesses-getting-quality-out-of-a-software-factory/).

### Planning

Delta between the article's first loop and this implementation:

| Capability | Current implementation | Missing |
| --- | --- | --- |
| Start and repeat critique | `prepare-spec` tells the agent how | A controller that launches reviewers, collects results, and advances rounds |
| Preserve review history | Append-only instructions; original hash checking | Scripted append operations that prevent accidental history replacement |
| Resolve findings and escalate | Skill instructions and structured statuses | Commands to record dispositions and pause/resume around user decisions |
| Enforce convergence | Checks require reviews and resolved findings | Explicit evidence that a final fresh review confirmed convergence; currently this is prose |
| Synthesize the final spec | Agent follows the skill | Controller-managed synthesis stage and saved intermediate results |
| Resume interrupted preparation | Files retain the work | Automatic recovery from the last completed stage |
| Report progress | `status` shows status, rounds, unresolved findings | A stage-by-stage run summary showing what ran and what happens next |

The article also includes GitHub issue creation/labels, batch preparation, and parallel reviewers from multiple vendors. These are deliberately deferred.

### Execution

Delta between the article's second loop and this implementation:

| Capability | Current implementation | Missing |
| --- | --- | --- |
| Run the implementation/review loop | execute-spec coordinates agents; scripts enforce checks and review limits | A standalone controller that launches work and advances stages |
| Resume interrupted execution | Saved results and a resume check | Automatic recovery of interrupted work and stale locks |
| Exercise changed behavior | Acceptance criteria map to evidence; the reviewer runs additional checks | A reusable isolated app host for interactive checks beyond the existing test runners |
| Review visible changes | Screenshots and findings are saved | An optional user UX approval step before integration |
| Merge and monitor CI | Stops at a branch ready for review | PR creation, merge, CI monitoring, and follow-up fixes |
| Validate after release | Local build and tests | Release smoke tests against the distributed app |
| Feed problems back into planning | Handoff records problems and proposed workflow improvements | Independent review of the handoff and creation of follow-up planning tasks |

Parallel tasks, dependency graphs, and integration branches are deliberately deferred; execution handles one task at a time.
