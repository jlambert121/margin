---
name: draft-spec
description: Turn a Margin feature or bug intent into a repository-grounded draft specification for later critique, without implementing the change.
---

# Draft a specification

Work from the repository root. Read [the planning protocol](references/planning.md) for the artifact contract and commands. Inspect relevant implementation and tests before proposing behavior. Ask only about decisions that affect the requested outcome; make ordinary implementation choices yourself.

1. Render `node tools/planning/task.mjs template` into a temporary draft file and complete it. Preserve the user's intent in at most three sentences, distinguish it from inferred requirements, and define non-goals. Remove template comments.
2. Give each observable acceptance criterion an `AC-N` ID. Map each to concrete validation steps, expected evidence, and who or what executes them. Distinguish WebKit editor behavior, Swift document behavior, native desktop interactions, and visual inspection. Check existing tests before claiming coverage.
3. Cite repository paths and checked assumptions. Record unresolved product choices with options and consequences in Open decisions; write `None` otherwise.
4. Run `node tools/planning/task.mjs init <slug> --from <draft-file>`, then `node tools/planning/task.mjs validate <slug>`. Initialization preserves the original and creates an editable spec.

Return the task path and outstanding decisions. A draft is not prepared. Do not implement application changes or publish an issue. If preparation was also requested, continue with the repository's prepare-spec skill.
