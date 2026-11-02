# Planning protocol for agents


Agent reference for draft-spec and prepare-spec. Human instructions are in [DEVELOPMENT.md](../../../../DEVELOPMENT.md).

## Task initialization

```sh
node tools/planning/task.mjs template > /private/tmp/margin-draft.md
# Complete the draft, then:
node tools/planning/task.mjs init table-navigation --from /private/tmp/margin-draft.md
node tools/planning/task.mjs validate table-navigation
node tools/planning/task.mjs status table-navigation
```

Replace the example slug with the requested task slug. Run commands from any directory. `--from` is relative to the caller's current directory. Initialization refuses to overwrite an existing task.

Each task lives in `docs/tasks/<slug>/`:

- `original.md`: the initial proposal, including the user's intent; preserve it byte-for-byte.
- `spec.md`: the implementation specification synthesized after critique.
- `feedback.md`: append-only findings, proposed resolutions, and user decisions.
- `state.json`: status and structured review metadata, maintained by the preparing agent.

Keep these artifacts under version control. The original hash detects accidental edits; Git history preserves the audit trail. This is not tamper-proof storage. The script does not enforce append-only feedback or assess whether a reviewer is independent.

## Specification format

Use the template's level-two headings. Original intent captures the request in at most three sentences; preserve that section in the final spec. Criteria use `- AC-1: observable behavior` lines. Validation uses the same IDs exactly once, with a method, executor, concrete steps, and expected evidence. Code references should identify paths and checked assumptions rather than freezing incidental line numbers.

Margin validation can include `npm test` (syntax, workspace, default native, document, and WebKit checks), `npm run test:native` (the native runner's additional `--ui` path), and `npm run build`. New behavior may require new tests. Desktop tests require a macOS desktop session. A screenshot proves appearance, not save/undo correctness. Specify manual checks when automation cannot establish a criterion; never describe unavailable validation as passed.

## Review state

Initialization writes version, status, originalSha256, rounds, and finalReview. Keep the generated hash. Allowed statuses are `draft`, `critique`, `needs-input`, `incomplete`, and `prepared`. Here is a round entry for the `rounds` array:

```json
{
  "number": 1,
  "reviewer": "fresh session; identify session or manual reviewer",
  "summary": "Checked the proposal against document save behavior.",
  "findings": [
    {
      "id": "F-1",
      "severity": "blocking",
      "summary": "The expected behavior for unsaved edits is unspecified.",
      "evidence": "Describe the relevant source path, behavior, and consequence.",
      "status": "incorporated",
      "resolution": "Record the chosen behavior and resulting criterion here."
    }
  ]
}
```

Finding severity is `blocking` or `minor`; status is `open`, `incorporated`, `rejected`, or `awaiting-user`. Resolved findings require a resolution. IDs are unique across rounds. A clean round has an empty findings array. Append full review prose under an exact `## Round 1` heading in feedback.md, including finding IDs. Log subsequent dispositions underneath without deleting the original review.

A fresh reviewer receives the original, existing feedback, state, repository instructions, and access to relevant source and tests. It should check assumptions, missing behavior, validation gaps, and scope drift; every finding needs evidence and consequences. Later rounds should check proposed resolutions and report genuinely new problems rather than repeat resolved suggestions. The controller is currently the agent or human; no subprocess is launched by the script.

Use at most three rounds. Keep the original proposal and working spec unchanged during critique. Resolve findings in the feedback, then synthesize spec.md once critique converges. Escalate only real product choices. If blockers remain at the limit, retain `incomplete`; do not reset the round count to hide failure. Further work after a limit requires an explicit decision to revise the task/process, preserving its history.

## Readiness

After synthesis, review the final spec against intent, accepted/rejected feedback, code assumptions, and validation. Record a specific summary in `finalReview`, resolve every finding, write `None` in Open decisions, and run:

```sh
node tools/planning/task.mjs prepare table-navigation
```

Preparation requires at least one critique round and records the exact spec hash. An edited prepared spec fails validation. To revise it, set status to `critique`, record renewed final review, and prepare again. `validate` checks structural integrity at every stage; passing validation on a draft does not mean ready. `status` reports unresolved findings. Commands return nonzero on malformed artifacts or invalid readiness.

These checks cannot establish whether criteria are sensible, evidence is true, resolutions are adequate, or a session was actually fresh. Those judgments belong to the skills and reviewer. Prepared is a handoff to a later implementation loop, not authorization to implement or ship.

