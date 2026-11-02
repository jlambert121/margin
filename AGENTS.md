# Verification

Use `mise exec -- qlty fmt <changed-file-paths>` to apply automatic formatting
before running the final checks. Swift files are formatted by SwiftFormat using
the repository's `.swiftformat` configuration. Review the resulting diff.
Other languages do not yet have configured formatters; preserve their existing
style rather than treating a successful no-op as formatting verification.

Before completing changes, run both Qlty checks from the repository root:

```sh
mise exec -- qlty smells --all
mise exec -- qlty check --all
```

Review the results and address findings introduced by your changes. Report any
remaining findings or checks that could not run in the final response. These
checks supplement the tests appropriate to the change.
