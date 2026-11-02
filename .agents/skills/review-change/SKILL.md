---
name: review-change
description: Independently review a Margin execution run against its prepared specification, test behavior, and produce a structured report for execute-spec.
---

# Review an execution run

Read [the execution protocol](../execute-spec/references/execution.md) for the report schema. Use a fresh session; disclose if you participated in implementation and do not present that as independent review. Review the identified run, not unrelated working changes.

Read captured original intent, spec, planning feedback, prior execution reviews, and current verification results. Inspect the diff from the recorded base through the current worktree commit. Confirm the worktree is clean except task artifacts, Markdown, and dotfile/dot-directory changes and the current revision has passing verification. Do not edit implementation or planning inputs.

Assess every acceptance criterion against observable behavior. Inspect relevant tests, run focused checks when needed, and use screenshots for visible changes. Reproduce important failure paths instead of trusting the implementer's summary. Use disposable fixtures and isolated test state; serialize desktop tests and do not interact with the user's normal running app or documents. If an interactive check cannot be run safely, mark its criterion unavailable. Save outputs under the run directory, identifying the tested revision. Do not change verification logs or prior evidence.

Return JSON using the documented schema: revision, reviewer identity, summary, verdict, criterion results with run-relative evidence paths, findings, and explicit resolutions of prior findings. Every finding needs a globally unique F-N ID, severity, concrete evidence, and consequence. Reject scope expansion and incidental wishlists. Distinguish code defects from a faulty spec that needs a product decision.

Pass only when every criterion passes and all earlier findings are resolved, including minor findings explicitly rejected with a reason. A changed revision requires new verification and review. Return the report file and a concise assessment to the coordinator; do not merge, release, or mark the run complete yourself.
