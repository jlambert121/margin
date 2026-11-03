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

Drafting and preparation are separate steps. Preparation now runs fresh critique sessions, combines the findings into a specification, and gets a final consistency review automatically. It requires the Codex CLI to be installed and signed in; model calls use your configured Codex access.

If preparation asks for a decision, answer it in the conversation and ask the agent to continue. If a model call fails, ask it to retry; completed rounds are kept. Execution starts only after preparation succeeds, and handles one task at a time.

Execution creates a separate Git working copy under `.worktrees/` for the changes; `.execution/` holds its lock. Both directories are ignored by Git and kept outside `build/` so cleaning builds does not delete unfinished work. It builds and tests the app, checks each acceptance criterion, and gets an independent review, with up to three review rounds. It leaves the result ready for your review; merging, pushing, and releasing are separate actions.

## When work stops

If there are uncommitted code changes, execution lists them and stops. Task files, Markdown, dotfiles, and files inside dot-directories are allowed; these exclusions do not copy those changes into the separate working copy.

The agent also stops if it needs a product decision, cannot complete a required check, or still has unresolved findings after three reviews. Ask it to explain what remains and continue when the cause is resolved; it keeps previous results rather than discarding them.

Desktop tests use temporary test files and separate settings. Keep a normal macOS desktop session available for those checks.

## Results

The specification and planning feedback are in `docs/tasks/<task>/`. Each execution attempt has its own folder under `docs/tasks/<task>/execution/`, containing a handoff, review findings, test results, and screenshots.

Execution screenshots, logs, temporary files, runtime state, generated JSON reports, and copied inputs stay local and are ignored by Git. Keep the task specifications and readable Markdown summaries, including handoffs and review notes, in Git.

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
| Resume interrupted preparation | Saved stages, agent responses, and replayable review history | Automatic stale-lock recovery after an abruptly killed process |

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

Look into token efficency - switch models when it makes sense
