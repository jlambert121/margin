# Critique history

Append rounds and resolutions here. Preserve earlier entries.

## User scope decision

The user selected “Live preview, HTML export, and print” in response to the surface-scope question. Updated spec.md to include all three surfaces and their output validation; source mode remains excluded. This decision resolves the open choice in original.md. The initial proposal is preserved unchanged. No critique round or preparation has occurred.

## Round 1

Reviewer: fresh delegated session /root/spec_review_round1, with no inherited conversation; read all four task artifacts, repository instructions, implementation, and tests. Application source and task artifacts remained read-only for the reviewer.

Independent review verdict: not ready until F-1 is resolved. Confirmed scope is live preview, HTML export, and print; source mode is excluded.

F-1 — blocking: EOF line-count rule needs a concrete cross-surface definition.

Evidence: spec.md requires an unclosed fence to include “an empty final document line when it is part of that content,” while also specifying that a terminating newline does not add a code line and empty fenced blocks have no numbers. It does not define which rule determines whether that final line is content. web/src/live-preview.js operates on CodeMirror document lines and parser-node ranges. web/src/markdown.js renders markdown-it token content. A read-only parser probe confirms that the unclosed source "```\nx\n" and closed source "```\nx\n```\n" both yield fence content "x\n"; source "```\n" yields empty content. Implementations counting editor document lines and implementations splitting rendered token content can disagree while appearing to follow the draft. AC-1's validation should establish exact output counts as well as preview counts.

Suggested resolution: define one counting algorithm with explicit closed/unclosed examples. Empty content has zero lines; otherwise split parsed code content on newline and discard exactly one terminal empty segment. Record that this replaces the extra-final-document-line language. Add matching preview, standalone HTML, and print-DOM assertions for empty content, one content line with/without a final newline, and an actual blank content line.

F-2 — minor: AC-4 should distinguish editor copying from HTML copying.

Evidence: AC-4 says copied selections contain “the selected Markdown text only” without restricting that expectation to the editor. AC-7 separately requires copying code from exported HTML without numbers. web/src/app.js export and print paths use rendered HTML from MarginMarkdown.renderDocument, so exported selections contain rendered code content, with Markdown fences and nesting syntax already removed. A literal reading creates conflicting clipboard expectations and applies editor navigation/search/cursor requirements to output surfaces.

Suggested resolution: scope Markdown selection, editing, search, and cursor assertions in AC-4 to the editor. Exported HTML copying preserves selected rendered code text without gutter numbers; print needs presentation and pagination checks.

Implementation assumption: web/src/live-preview.js currently determines a closing fence with a regex against the physical last line that does not recognize a quote-prefixed closing fence, although the parser exposes its CodeMark. Numbering must use parsed fence boundaries so quoted closing markers remain unnumbered. This is already covered by the parser-boundary requirement, does not independently block readiness, and does not require unrelated Mermaid rendering changes.

Reviewer conclusion: remaining behavior, scope, and validation are sufficiently concrete. Resolving F-1 and incorporating F-2 would leave no blockers identified by this review.

### Proposed dispositions after Round 1

F-1: accept. Replace the ambiguous final-document-line clause in Proposed behavior, retaining AC-1's ID. Count parsed code content consistently: empty content gives zero lines; otherwise normalize newline delimiters for counting, split on newline, and drop exactly one final empty segment if present. Markdown bytes are never normalized or changed. Indented code uses only content assigned to the code block by the parser; surrounding blank separator lines are excluded. For exact examples, the JSON strings "```\n", "```\n```\n" give zero; "```\nx", "```\nx\n", "```\nx\n```\n" give one; "```\nx\n\n", "```\nx\n\n```\n" give two (second line blank); "```\n\n```\n" gives one blank line. Test the same expected sequences in preview, HTML, and print DOM, plus quoted closing markers and CRLF input. This is a technical clarification of logical content-line counting, not a new product scope choice.

F-2: accept. Limit AC-4 and its validation to editor selection and editing. Keep rendered-code copying in AC-7. Clarify output-specific wrapping and pagination in the synthesized spec. No new acceptance IDs are needed.

Preserve the parsed-boundary implementation note explicitly. spec.md remains unchanged during critique; synthesis is pending a fresh convergence review.

## Round 2

Reviewer: fresh delegated session /root/spec_review_round2, with no inherited conversation; read repository instructions, planning documentation, the prepare-spec skill, all four task artifacts, and relevant rendering, editor, CSS, and test paths. Application source and artifacts remained read-only.

Full convergence review: no new material blockers. No F-3 or later findings.

F-1's proposed resolution resolves the blocker. Empty parsed content produces zero numbers; otherwise splitting normalized newline delimiters and dropping exactly one terminal empty segment distinguishes a terminating newline from a blank content line. The explicit examples define closed and unclosed behavior consistently. Matching preview, HTML, and print-DOM assertions make the rule testable across the two parser paths: web/src/live-preview.js uses editor syntax nodes and document positions, while web/src/markdown.js renders markdown-it token content. Normalization solely for counting preserves the Markdown-byte requirement. Retaining the parsed-boundary note also addresses quoted closing markers without requiring unrelated Mermaid changes.

F-2's proposed resolution resolves the clipboard ambiguity. Restricting AC-4 to editor behavior matches web/src/app.js's document-backed selection and cursor paths. Keeping exported copying in AC-7 matches rendered output from MarginMarkdown.renderDocument, where fences and nesting markers are already absent. Print remains subject to presentation and pagination checks.

The remaining behavior and validation are sufficient for implementation preparation. Existing tests/editor.test.js and tests/bridge.test.js provide appropriate output and Mermaid test entry points; the proposed additions explicitly cover numbering, standalone output styles, real clipboard interaction, and print pagination that existing tests do not establish. Source mode exclusion and the user-confirmed live-preview/HTML/print scope remain consistent.

Convergence verdict: critique has converged. Incorporate proposed F-1/F-2 dispositions during synthesis, resolve their structured statuses, and perform final consistency review and preparation validation. The unchanged working spec still contains superseded wording, as expected during critique; this review does not claim synthesis or preparation has already occurred.

### Synthesis and finding dispositions

F-1 incorporated after convergence: replaced the conditional final-document-line wording with the reviewed parsed-content algorithm and all eight explicit fenced source/count examples. Counting-only newline normalization preserves source bytes. Clarified internal versus trailing blank lines for indented code and parsed closing markers for nested fences. AC-1 retains its ID and gains matching preview, HTML, print-DOM, standalone export, CRLF, and nesting assertions.

F-2 incorporated after convergence: AC-4 and its validation now apply only to editor behavior; AC-7 explicitly copies rendered code without fences, nesting syntax, or gutter numbers. AC-3 explicitly applies editor theme/zoom/geometry requirements to live preview. AC-7 keeps output wrapping and pagination checks, with output-specific first-row number alignment. No acceptance criteria were removed or added; IDs AC-1 through AC-7 remain mapped exactly once.

Retained the user-confirmed three-surface scope, source-mode exclusion, automatic local numbering, no preference or serialization changes, and existing Mermaid success/fallback behavior. Added the inspected print break-inside constraint as an implementation note; relaxing it only for oversized code blocks supports the already-required pagination behavior. No unrelated application change is proposed.

Controller validation evidence: read-only probes of installed MarkdownIt and CodeMirror parser paths confirmed token and marker boundaries. All eight exact count examples and a CRLF example match the reviewed counting rule. spec.md was byte-identical to its pre-review snapshot through both critique rounds. These probes establish assumptions, not implemented feature behavior.
