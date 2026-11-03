# Planning protocol for agents

Agent reference for draft-spec and prepare-spec. Human instructions are in [DEVELOPMENT.md](../../../../DEVELOPMENT.md).

## Draft initialization

```sh
node tools/planning/task.mjs template > /private/tmp/margin-draft.md
# Complete the draft before initialization.
node tools/planning/task.mjs init <task> --from /private/tmp/margin-draft.md
node tools/planning/task.mjs validate <task>
node tools/planning/task.mjs status <task>
```

Initialization refuses to overwrite a task. The four task files remain original.md (immutable proposal), spec.md (working/final specification), feedback.md (append-only review projection), and state.json (status and structured round projection). Use the template's level-two headings. Original intent captures the request in at most three sentences. Criteria use unique `- AC-1: observable behavior` lines, and Validation maps each ID exactly once to an executor, concrete steps, and expected evidence. Cite relevant source paths and checked assumptions. Record unresolved product choices with options; Open decisions is `None` when resolved.

Validation choices include npm test (syntax, loop tools, workspace, default native, document, WebKit), npm run test:native (additional --ui path), and npm run build. Desktop checks require a normal macOS desktop session. Check actual existing coverage before claiming it validates new behavior; screenshots alone do not prove save/undo behavior. These are future implementation checks, not checks passed by preparing a spec.

## Controller

```sh
node tools/planning/controller.mjs <task>
node tools/planning/controller.mjs <task> --decision /path/to/user-answer.txt
```

Each critique is a fresh `codex exec --sandbox read-only --ephemeral` session with structured output, the original, working spec, all feedback, and access to repository source/tests. It inherits the configured model and authentication; it does not inherit conversation history. Local subprocess commands require no API key setup beyond the user's existing CLI access. The controller never disables the sandbox or ignores project rules. Child approval policy is never; an unavailable required tool must be reported rather than bypassed.

At most three critique rounds run. A critique returns summary, converged, decision, new findings, and explicit dispositions of earlier findings. Findings use globally unique F-N IDs, severity blocking/minor, summary, and evidence/consequences. The script records new findings as open; dispositions are incorporated, rejected, or awaiting-user and require reasons. Incorporated during critique means an accepted proposed change for later synthesis. Repeated findings should reference existing IDs through dispositions rather than invent duplicates.

Original.md and spec.md remain unchanged during critique. Genuine scope/assumption decisions pause with needs-input and concrete options. Only an explicit answer supplied through --decision resumes that task; the answer is recorded in history. No new round or model call runs while waiting. If round three still cannot converge, preparation stops incomplete; do not reset its counter. A decision supplied after the third round remains recorded but does not grant extra rounds.

After a fresh critique confirms convergence and all findings are resolved, a separate synthesis session returns the complete spec as data. The controller validates its headings, intent, criterion mapping, and resolved decisions before writing spec.md. It records the exact proposed spec and rationale in history. A final fresh session checks consistency against original intent, feedback/dispositions, code assumptions, and validation. Only a passing final review with no findings can produce prepared. Direct task prepare also enforces these controller-managed readiness fields and the final spec hash.

The controller does not start execution. Previously prepared legacy tasks remain readable and are not re-prepared automatically.

## Durable history

history/baseline.json captures the existing feedback and rounds on first use, preserving legacy manual work. Subsequent numbered JSON files are immutable event records linked by hashes. state.json stores the baseline/head hashes. feedback.md and rounds in state.json are derived views. Hash checks detect accidental event edits, deletions, reordered sequences, and replaced feedback; this is not tamper-proof storage against someone deliberately rewriting all files.

The writer creates a new event with exclusive creation and appends feedback without replacing earlier text. Stable event keys make replay idempotent; reusing a key with different content fails. Recovery accepts only an earlier valid projection and appends/restores the missing derived updates. Arbitrary edits fail instead of being silently overwritten. Preserve the journal with feedback/state in Git; subprocess logs and controller checkpoints under planning/ are ignored.

For an additional manually obtained review or disposition, write an event file and run:

```sh
node tools/planning/history.mjs append <task> /path/to/event.json
node tools/planning/history.mjs sync <task>
```

Round event example:

```json
{
  "kind": "round",
  "key": "manual-round-1",
  "data": {
    "number": 1,
    "reviewer": "fresh session identity",
    "summary": "What was inspected and found.",
    "findings": [
      {"id":"F-1","severity":"blocking","summary":"Ambiguous behavior","evidence":"Relevant source and consequence","status":"open"}
    ]
  }
}
```

Resolution event example:

```json
{
  "kind": "resolution",
  "key": "resolve-f-1",
  "data": [{"id":"F-1","status":"incorporated","resolution":"Accepted proposed correction and its criterion."}]
}
```

The controller also records decision, synthesis, and final-review events. Round events retain raw findings and dispositions while their state projection reflects current statuses. Do not use manual event insertion to make an unreviewed spec appear converged. Use validate/status to inspect integrity; sync repairs an interrupted derived update without deleting event history.

## Failure and resume

planning/controller.json records the next stage and any returned response pending application. Attempts under planning/attempts/ retain prompts, output schema, JSONL events, stderr, and structured responses. Each subprocess has a fifteen-minute timeout; timeouts kill its process group. No automatic retry storm: failed calls stop and the same command retries the unfinished stage when invoked again. Previously completed rounds and valid pending responses are reused.

One planning/operation.lock serializes changes to a task. If abruptly terminated, confirm the process is no longer running before removing only that stale lock. Automatic stale-lock cleanup and automatic recovery of an interrupted agent process are not implemented. State projection replay and successful-response replay are implemented.

Task-file changes during an agent call invalidate its response. Manual changes to the working spec between stages stop the controller for inspection. Application source is read-only to the child agents. A failed final consistency review leaves the task incomplete with its findings recorded; resolve the planning problem explicitly rather than silently running unbounded revisions.

The scripts enforce recorded integrity, bounds, and shape. They cannot prove reviewer evidence is true or that acceptance criteria capture every product expectation.
