---
name: prepare-spec
description: Critique and synthesize an existing Margin task draft into an implementation-ready specification, preserving original intent and review history.
---

# Prepare a specification

Read [the planning protocol](../draft-spec/references/planning.md) for commands and state schema. Validate the named task and read all four files. Preserve `original.md` byte-for-byte and all previous feedback. Application source remains read-only.

## Critique

Use a fresh reviewer session with the task artifacts, repository instructions, and access to relevant implementation and tests. Request incorrect assumptions, missing behavior, untestable criteria, and scope expansion, supported by evidence and consequences. One reviewer per round is enough. A separate session may be manual or delegated when available and authorized. If unavailable, report incomplete preparation and provide a concrete review prompt; never represent self-review as independent critique.

Append full findings to `feedback.md` under numbered rounds. Mirror each finding in `state.json` using the documented schema and unique IDs. Subsequent reviewers see the original and all feedback. Keep `spec.md` unchanged during critique; record proposed resolutions in feedback. Deduplicate repeated findings and explain incorporated, rejected, and awaiting-user dispositions.

Only material correctness, feasibility, scope, or validation problems block readiness. Resolve minor suggestions explicitly without expanding scope. If a disproven assumption or scope change leaves a real product choice, set status to `needs-input` and present options. Record the user's answer in feedback and the resolution. Routine technical choices need no escalation.

Use at most three rounds. Stop early when a fresh reviewer reports no new blockers and confirms proposed resolutions address prior blockers. If blockers remain at the limit, set status to `incomplete`. Never equate the round limit with readiness.

## Synthesis

Once critique converges, synthesize `spec.md` from the original and accepted feedback. Preserve Original intent exactly. Explain changed or removed criteria in feedback. Review the synthesized spec against intent, finding dispositions, code references, and validation mappings. New blockers leave the task incomplete or needing a product decision.

Record the specific consistency review and limitations in state `finalReview`. Set status to `critique` after resolving a stopped task. Run `node tools/planning/task.mjs prepare <slug>` and only report prepared if it succeeds. Later spec edits require renewed review and preparation.

Return the spec link, key decisions, rounds, and limitations. Prepared means ready for implementation; structural validation does not establish correctness.
