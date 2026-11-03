# Smell baseline provenance

The first default `mise exec -- qlty smells --all` scan in the untouched execution worktree reported exactly the eight captured baseline findings before implementation. The captured prepared specification lists their counts and thresholds. The source checkout remains at base `b080c3f32a4bea7636cbfe39a39bffd1bd27f55e` for application code.

`logs/baseline.sarif` is a later default all-files scan of that source checkout. Its first eight records reproduce the original production findings. It also reports archived temporary copies created by Qlty under this run's verification TMPDIRs, and duplication against those copies. Those extra records describe retained execution artifacts rather than the production baseline. The raw report is retained without suppressing records or changing exclusions.

The canonical final default scans run at the execution worktree root. The run artifacts reside in the source checkout, outside that worktree. Final file metrics cover 54 production targets, including every extracted file. No threshold, exclusion, suppression, test-pattern, or Qlty configuration changed.

Workflow improvement: capture the machine-readable baseline before the first verification attempt. Qlty retains copies beneath TMPDIR; later source-checkout scans can include those copies. Do not change the feature's scan configuration to hide them.
