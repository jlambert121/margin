# Handoff

Implementation, verification and independent review are complete at `3532e16eb50d8876d5ff4fe917862634685fd597`.

Branch: `execute/qlty-smell-refactoring/20261102220854917-77c8acf4`.

Worktree: `/Users/jlambert/Documents/projects/margin/.git/margin-execution/worktrees/20261102220854917-77c8acf4`.

## Delivered behavior

Behavior-preserving responsibility splits remove the eight baseline smells. Table navigation accepts a named movement value; render separates ordinary-input refresh, rebuilding and focus restoration. Table parsing/source edits and view behavior have separate modules. Preview widgets and inline/list/block decorators share one transaction context. The web editor composes document session, input, syntax, formatting, search, output and controls with one owner per state value. All source scripts load locally and receive syntax checks.

The sidebar separates model/tree construction, row presentation and file actions while retaining expansion/reload guards. Each window owns its sidebar coordinator, observer lifetime, workspace tree and scan generation; restoration uses an explicit snapshot with unchanged keys. Existing native application types moved intact into domain files. Menu construction, workspace operations, and document reconstruction are separate responsibilities; AppDelegate remains the launch/window coordinator.

The native document and editor classes measured below threshold after intact moves, so their existing disk/save/recovery and message-routing bodies stay together. No router was extracted. AppDelegate still measured 64 after menu/workspace extraction; cohesive recovery/restoration reconstruction moved into ApplicationDocumentRestorer, leaving the delegate at 39 and the restorer at 25. No protocol, persistence, undo, dependency, threshold, or exclusion change was made.

## Criterion evidence

See [the criterion-by-criterion record](evidence.md), verification logs and independent review. Final file metrics cover 54 production targets. Maximum file complexity is 48. Table render cognitive complexity is 3; refresh/build/focus helpers are 3/8/3.

Verification attempt 16 passes formatting, npm test (including WebKit/bridge suites), native UI tests, app build, Qlty smells and Qlty check. Final default worktree scan has zero findings, with unchanged configuration.

Fresh independent review [passed every criterion](review-1.json), including source/diff inspection, focused disposable-base diagnostics, final raw verification results, and all four final screenshots. No implementation defect or unresolved finding remains. Earlier failed attempts are retained and superseded by the successful final revision; none was waived.

## Limitations and safeguards

All desktop checks use disposable fixtures and isolated preferences/TMPDIR. No normal Margin instance or working documents were used. Native composition is exercised through the real NSTextInputClient marked-text/update/commit path and trusted WebKit DOM events; this does not exercise every physical keyboard or input-method candidate UI. Screenshots support representative appearance; source, undo, persistence, focus and node identity have behavioral assertions.

The main checkout's application source remains unchanged. This worktree and local commits remain available for inspection. Nothing was merged, pushed, published or released.

## Problems and workflow improvements

- The execution tool places its worktree inside protected `.git`, requiring elevated writes/commits/builds. Explain that path before starting; consider a separately authorized writable worktree root in future harness work. The harness was not changed here.
- Attempt 1 failed sandbox writes. Later verification ran with authorized elevated access.
- Attempt 6 was invalidated when the next coordinator file was created before verification ended. Subsequent source mutations were serialized after verification. No invalid attempt is used as final evidence.
- New native test helpers initially needed explicit main-actor annotations. The corrected checks compile on the repository's Swift toolchain.
- Cocoa's hasMarkedText cache stayed false while native trusted composition events and marked text were active. Independent disposable-base diagnostics established this fixture-oracle issue and the base table whitespace contract; assertions now await actual trusted composition/update/commit, exact source, cell identity and caret. No failed acceptance check was waived.
- Initial sidebar screenshots used Outline mode and transparent AppKit backing, and preview capture preceded focus/layout settling. Fixture mode, background and focus/timing were corrected before final visual inspection.
- Direct CLI test-host focus requires completing AppKit launch, measured native activation and dispatching native events as well as RunLoop timers. The fixture runs last to isolate this lifecycle state from legacy undo checks. Its compatibility activation option produces a test-only SDK deprecation warning; the nondeprecated empty-options variant failed in independent diagnostics. No warning suppression or production change was added.
- Capture machine-readable baseline evidence before verification creates retained Qlty temporary source copies. Later source-checkout scans include those artifacts; see [baseline provenance](baseline-notes.md). Canonical final scans run from the execution worktree with unchanged configuration.
- Finish validated the handoff and saved ready-for-review, then sandbox protection blocked releasing `.git`'s active marker. A retry hit the terminal-status guard. The existing finish/release helpers revalidated source/input integrity, verification, review and evidence before releasing this run's marker with authorized access. Future harness work could make that transition recoverable; no harness change was made here.
