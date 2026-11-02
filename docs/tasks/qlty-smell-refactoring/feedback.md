# Critique history

Append rounds and resolutions here. Preserve earlier entries.

## Round 1

Reviewer: fresh delegated session /root/smells_review1 (fork_turns=none), supplied repository instructions and all four task artifacts with access to implementation, tests, and build scripts. All source and artifacts remained read-only for the reviewer. No implementation tests were run.

Readiness verdict: not ready yet. The decomposition addresses all eight smells and is technically plausible, but two behavior contracts need clarification before synthesis. One minor validation claim should also be corrected.

F-1 — blocking: S-4's shortcut isolation requirement conflicts with existing behavior.

Evidence: S-4 says “Keep document-input shortcuts from intercepting find/dialog fields.” In web/src/app.js, only native undo and bold/italic/link branches use inDocument. Heading shortcuts apply formatting without that guard; source mode, find, go-to-line, file switching, save/open/new also run globally. Heading formatting therefore remains intercepted when the key originates in a find/dialog input. tests/bridge.test.js verifies field-local undo, not blanket isolation of all document-changing shortcuts.

Consequence: an implementer could add a broad field guard and change established shortcut behavior while claiming to preserve it. The prose combines an unchanged-behavior goal with an improvement current code does not provide.

Suggested resolution: replace the blanket requirement with the actual routing contract: preserve current inDocument guards for undo and bold/italic/link; preserve other branches' global scope, modifier handling, capture order, and propagation behavior. Add targeted assertions from document, find, and insert-dialog targets, including the currently global heading branch. Broader field isolation belongs in a separate behavior-change task.

F-2 — blocking: S-8 does not state the pending-focus exception to the same-shape fast path.

Evidence: web/src/table-editor.js refreshes existing cells only when editing exists, shape matches, and !dom.focusAfterRender. edits.moveRow and edits.moveColumn return focus requests while preserving table shape; apply stores the requests before dispatch. render consequently rebuilds and restores focus even for some same-shape changes. S-8 broadly requires same-shape editing to retain the contenteditable node and explicitly associates rebuilds only with structural changes.

Consequence: a shape-only fast-path condition would retain the wrong editing cell after moves and leave the focus request unconsumed. The helper and acceptance language must preserve the three-part condition.

Suggested resolution: define the node/caret-preservation path as ordinary same-shape cell input with no pending focus request. Pending focus takes precedence regardless of shape, is consumed exactly once, and follows existing coordinate/null-default/clamping behavior. Extend AC-8 validation with same-shape row/column moves while editing, asserting destination and consumed request separately from ordinary-input identity/caret checks.

F-3 — minor: AC-2 describes session-unit coverage as bridge-routing coverage.

Evidence: tests/DocumentTests.swift's “stale editor messages” test calls EditorSession directly. Actual document lifetime, frameInfo.isMainFrame, payload decoding, and session.acceptChange guards occur in Sources/Margin.swift's production message handler. tests/bridge.test.js records outgoing JS payloads through a no-op native sink in tests/EditorTests.swift; it does not exercise Swift rejection of incoming stale edits. Native integration covers late messages after close, but not an explicit stale-token/revision or subframe routing matrix.

Consequence: the cited tests establish session policy and outgoing protocol shape, but do not establish that an extracted router still invokes guards correctly.

Suggested resolution: describe existing coverage precisely. If routing is extracted, require focused behavioral coverage through the production routing boundary for stale token/revision and subframe rejection, retaining session-unit and close-before-load cases. This clarifies the existing ownership-boundary coverage rather than adding a new testing architecture.

Additional reviewer checks: Swift discovery is compatible with direct-child file splits because scripts/build.sh, scripts/test.sh, and scripts/test-native.sh compile Sources/*.swift. scripts/test-workspace.sh compiles only WorkspaceScanner.swift intentionally; no scanner declaration moves are proposed. Existing cell tests assert node identity/connectivity but not caret survival, so selection assertions are appropriate. Navigation tests already cover right Tab, Enter down, same-row Shift+Tab and final-row creation; additional boundary/modifier cases are genuine coverage gaps. No other material blockers identified.

### Proposed dispositions after Round 1

F-1: accept. Replace the blanket field-isolation requirement with preservation of the current branch-by-branch routing scope and modifiers. Keep undo/bold/italic/link editor-scoped and currently global branches global. Add document/find/insert-dialog target assertions for editor-only branches and global heading/application shortcuts, including defaultPrevented/native messages/Markdown outcomes as applicable. No shortcut usability change is authorized; it would require separate scope.

F-2: accept. Preserve the exact fast-path predicate (active editing cell AND same table shape AND no pending focusAfterRender). All other cases use the rebuild path. A pending focus request overrides prior active-cell coordinates even when shape is unchanged; consume it once and preserve current null defaults and upper-bound clamps, then restore the requested cell. Extend validation with row/column moves while editing that leave shape unchanged, asserting consumed request and destination before subsequent typing. Ordinary input without a pending request must preserve node/selection. This is a technical correction, not new product behavior.

F-3: accept. Label tests/DocumentTests.swift as EditorSession unit-policy coverage and tests/bridge.test.js as outgoing JS protocol coverage. If message routing is extracted, add focused production-boundary cases for valid edits, stale/wrong tokens, decreasing/duplicate revisions, malformed payloads, subframe messages, and closed-document late messages. Assert rejected messages leave document text/dirty/undo state unchanged and valid messages reach the document exactly once. Inspect the existing session revision comparison to preserve its actual duplicate-revision policy rather than assume a new one. A narrow test seam may call the same production handler used after WKScriptMessage decoding; do not duplicate router logic in a test-only implementation. Tests may inject decoded frame/body inputs while preserving their production checks. Retain native integration through WKWebView for valid delivery and close-before-load behavior.

The controller refreshed the Qlty baseline during preparation: exactly the same eight findings remain, now across 24 production targets because unrelated execution tooling was added. Those workspace changes are outside this task. spec.md remains unchanged until critique convergence.

## Round 2

Reviewer: fresh delegated session /root/smells_review2 (fork_turns=none), read repository instructions, all task artifacts and relevant implementation/tests. Review was read-only. No application tests, formatting or Qlty checks were run by this reviewer; the refreshed eight-finding baseline is controller-supplied evidence.

Convergence verdict: no new blockers; proceed to synthesis with proposed Round 1 dispositions. Round 2 findings: none.

F-1 is resolved by the proposed contract. web/src/app.js gates native undo and bold/italic/link with inDocument, while heading and application shortcuts remain global. Preserving each branch's target scope, modifiers, capture priority, and propagation behavior corrects the conflicting blanket isolation requirement. Document/find/dialog assertions provide behavioral evidence without introducing a shortcut change.

F-2 is resolved by the proposed contract. web/src/table-editor.js uses editing && dom.tableShape === shape && !dom.focusAfterRender. Row and column moves request focus while retaining shape. Preserving this predicate, pending-focus precedence, one-time consumption, null defaults and existing upper clamps maintains current behavior. Same-shape move assertions cover the gap separately from ordinary-input node/caret preservation.

F-3 is resolved by the proposed coverage correction. tests/DocumentTests.swift exercises EditorSession directly; tests/EditorTests.swift installs a no-op native sink for the outgoing bridge suite. Focused tests through the actual production routing boundary are appropriate if routing is extracted. Sources/RecoveryStore.swift requires next > revision, so duplicate and decreasing revisions remain rejected. Decoded frame/body injection is acceptable only when tests retain production frame/lifetime/payload/session checks.

The eight-smell decomposition remains plausible, measurable and within behavior-preserving scope. Existing build scripts compile direct-child Sources/*.swift files and package the full web tree. Proposed script-order/syntax-check updates address JS extraction needs. Exact collaborator interfaces and measured fallback splits can remain implementation decisions.

spec.md is still identical to original.md, as required during critique. Synthesis must incorporate these resolutions into affected behavior, acceptance, validation and coverage statements before final consistency review and preparation.

### Synthesis and dispositions

F-1 incorporated: replaced S-4's blanket field isolation with the actual editor/global branch routing contract. AC-4 and its validation now explicitly retain field-target behavior, event modifiers, capture/propagation, and document/find/dialog regression assertions. Broader shortcut field isolation is outside scope.

F-2 incorporated: S-8 now states the exact three-part fast-path predicate. Pending focus overrides previous coordinates even at the same shape; current null defaults and upper clamps remain. AC-8 distinguishes ordinary input without pending focus from moves requesting a destination, and validation covers both same-shape row/column moves plus subsequent typing.

F-3 incorporated: corrected AC-2 validation and source assumptions to distinguish EditorSession unit coverage, outgoing JS bridge tests and native integration. If production routing moves, focused tests must exercise its frame/lifetime/payload/session guards, including strictly increasing revisions. A test seam must invoke production logic, not a duplicate test router. Existing real WKWebView integration remains required.

No acceptance IDs were added or removed. AC-1 through AC-9 still map exactly once to validation. All eight smell proposals, threshold targets, cohesive responsibility boundaries, measured fallback splits, staged implementation order and no-suppression policy remain. Removed an obsolete proposal-stage non-goal about preparation, replacing it with the continuing boundary against publishing/implementing/shipping during preparation. Clarified that filenames are implementation choices within the specified responsibilities.

Controller consistency checks: the original SHA-256 remains 1aa8e806c1f1d1102d20ac57bdd74c5fafcf6caee93a41fd70d9352769ff1520; cmp confirmed spec.md remained unchanged through critique. Refreshed Qlty inventory still contains exactly the eight original smells. Source/build/test inspection confirms direct-child Swift discovery, full web-tree packaging, current shortcut predicates, table fast-path behavior and strictly increasing session revisions. No application source was edited. These observations support the spec; they do not prove future refactors or predicted per-file scores.
