# Verification

Use `qlty fmt <changed-file-paths>` to apply automatic formatting
before running the final checks. Swift files are formatted by SwiftFormat using
the repository's `.swiftformat` configuration. Review the resulting diff.
Other languages do not yet have configured formatters; preserve their existing
style rather than treating a successful no-op as formatting verification.

Before completing changes, run both Qlty checks from the repository root:

```sh
qlty smells --all
qlty check --all
```

Review the results and address findings introduced by your changes. Report any
remaining findings or checks that could not run in the final response. These
checks supplement the tests appropriate to the change.
- I run the app from build/Margin.app. `npm test` and scripts/test-native.sh build elsewhere, so that bundle goes stale. After changes I'll try in the app, run ./scripts/build.sh and tell me to quit (⌘Q) and reopen.
- When I report a fix not working, compare the bundle's binary mtime with the sources before debugging.
