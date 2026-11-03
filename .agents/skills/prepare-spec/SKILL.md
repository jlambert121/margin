---
name: prepare-spec
description: Run Margin's planning controller to critique a task draft, preserve review history, and synthesize an implementation-ready specification.
---

# Prepare a specification

Read [the planning protocol](../draft-spec/references/planning.md). Run `node tools/planning/controller.mjs <task-slug>` from the repository root. The controller launches fresh read-only Codex sessions, records critique and dispositions through the history script, synthesizes the spec, and requires a final independent consistency review. Do not replace it with self-review or manually edit feedback, journal entries, or state to bypass its gates. Do not implement the application change.

Report stage updates and final outcome. On needs-input, present the controller's question and options. Wait for the user's actual answer; write that answer to a temporary text file and continue with `node tools/planning/controller.mjs <task-slug> --decision <answer-file>`. Do not invent a decision or treat elapsed time as approval.

On subprocess/auth/rate-limit failure, explain the error and retained attempt location; rerunning the same command retries the unfinished stage without discarding completed rounds. If three rounds cannot converge, or final consistency review fails, report incomplete preparation with the unresolved problems. Do not reset counters or rewrite the original intent to obtain a pass. A stale planning/operation.lock after abrupt termination requires confirming the old process is stopped before removing only that lock.

Use `tools/planning/history.mjs` for any additional review/disposition records, following the reference schema. The script imports existing feedback as a baseline and detects later edits. Never overwrite earlier entries. The controller itself uses the same event-writing functions.

Return the spec link, key decisions, critique count, and limitations. Only report prepared when the controller finishes successfully; prepared means ready for implementation, not implemented.
