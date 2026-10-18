# Margin

A macOS Markdown editor with a single-pane writing experience. Native AppKit document windows wrap an offline WebKit editor.

## Run

Requires macOS 13 or later and Xcode Command Line Tools. No production package installation or web server is needed.

```sh
./scripts/run.sh
```

The built application is `build/Margin.app`. Open it directly or copy it into Applications. It is signed locally for development, and built for the current Mac's architecture. Distribution signing and notarization are not configured.

After rebuilding, quit the running copy with ⌘Q and reopen the app; rebuilding does not replace a copy that is already running. Window restoration follows the macOS “Close windows when quitting an application” setting.

## Included

- Live preview editing: the document is always the exact Markdown text. Headings, emphasis, strikethrough, inline code, links, quotes, lists, task checkboxes, horizontal rules, fenced code blocks, and images render in place, and their Markdown syntax appears as editable text only where the cursor is. Typing Markdown (such as `## Heading`) renders once the cursor moves on.
- Tables edit as a grid: click a cell to edit its Markdown; Tab/Shift-Tab, Enter, and the up/down arrows move between cells, and Tab in the last cell adds a row. Right-click a cell to insert, delete, or move rows and columns, set column alignment, or edit the table as Markdown. Cell edits rewrite only that cell's text; column changes rewrite the table's rows.
- Right-click the document to insert a table, link, image, or code block, or to change a paragraph's style or format text, alongside the usual spelling, Look Up, and Cut/Copy/Paste items. Right-clicking a blank line puts the cursor there.
- Source mode (⌘/) shows the same document with all syntax visible.
- A native sidebar that runs the full window height beside the tabs, with the open files, the workspace folder tree and its filter, and a clickable document outline. The tabs in a window share it: whether it is shown, its width, Files or Outline, opened folders, and the filter stay the same when switching tabs. Its toggle sits at its top, and moves to the toolbar while the sidebar is hidden.
- Native Open, Open Recent, Save, Save As, autosave, undo/redo, and unsaved-document handling. Documents open as native macOS tabs and can be dragged out into their own windows.
- Files changed by another application reload automatically when there are no unsaved changes. With unsaved changes, a banner offers Reload, Keep mine, or Compare, which shows each disk change inline in source mode to keep or take one at a time or all at once.
- Find and replace, optionally with regular expressions (`$1`, `$&`, and `$<name>` in replacements), and Go to Line (`line` or `line:column`; also opened by clicking the cursor position in the status bar).
- Fenced code blocks are syntax highlighted in the language their info string names, for every language CodeMirror ships.
- Brackets, double quotes, and backticks close as you type; typing `*`, `_`, or `~` over a selection wraps it.
- Pasting from a web page or a document converts its formatting to Markdown: headings, emphasis, links, lists, tables, and code. Clipboard HTML without such structure, such as code copied from an editor, pastes as plain text, as does anything pasted into code or with Paste and Match Style.
- YAML front matter at the top of a document shows as a labeled metadata block, and stays out of the outline, word count, HTML export, and printing.
- Quick Open finds a file by name among the window's tabs, other open documents, recent files, and the workspace.
- Right-click the workspace in the sidebar to create a file, rename one in place, or show it in Finder. Renaming a file that is open keeps its tab and unsaved edits.
- Word and character counts, line counts, estimated reading time, and the cursor's line and column.
- Text zoom for the document text, remembered across windows and launches.
- Settings (⌘,) for Light, Dark, and Auto appearance (follows macOS) and a choice of six Dock icons. The bundled icon shown in Finder is always Night.
- Typewriter scrolling.
- HTML export and native printing with Save as PDF.
- Local images underneath the Markdown file's directory. Dropped or pasted image files are embedded as data URLs; no upload service is used.
- Bundled editor and sanitizer assets; no analytics or network dependency at launch. Images with remote URLs load from their original hosts.

| Shortcut | Action |
| --- | --- |
| ⌘N | New document |
| ⌘O / ⇧⌘O | Open file / folder |
| ⌥⌘P | Quick Open |
| ⌘S / ⇧⌘S | Save / Save As |
| ⌘W | Close |
| ⌘P | Print / Save as PDF |
| ⌘Z / ⇧⌘Z (or ⌘Y) | Undo / Redo |
| ⌥⇧⌘V | Paste and Match Style |
| ⌘F / ⌥⌘F | Find / Find and Replace |
| ⌘L | Go to Line |
| ⌘B / ⌘I / ⌘K | Bold / Italic / Link |
| ⌘1–6 / ⌥⌘0 | Heading / Body |
| ⌘/ | Toggle Markdown source |
| ⇧⌘L | Toggle sidebar |
| ⌘+ (or ⌘=) / ⌘− / ⌘0 | Zoom in / Zoom out / Actual size |
| ⌃⌘F | Enter or exit full screen |
| ⌘, | Settings |

The standard macOS shortcuts also work: ⌘X / ⌘C / ⌘V, ⌘A, ⌘M, ⌘H, ⌥⌘H, and ⌘Q.

In the find bar, Enter and ⇧Enter go to the next and previous match, Enter in the replace field replaces one, and Esc closes it. In Quick Open, ↑ and ↓ choose, Enter opens, and Esc closes. While renaming in the sidebar, Enter keeps the name and Esc cancels. Table cells have their own keys, listed above.

Command-click links to open them. New documents, File → Open, Open Recent, Finder and Dock opens, workspace clicks, and Markdown files dropped on the editor all open as tabs in the current window. In the sidebar's Open Files, click a tab to switch to it, or × to close it. The workspace list refreshes when Margin becomes the active app, or with its refresh button. The last workspace, appearance, app icon, and text zoom are remembered.

## Implementation

- `Sources/Margin.swift`: AppKit application, NSDocument lifecycle, editor windows and their bridge to the web editor, menus, file panels, workspace scanning, export/printing, and the restricted local-image URL handler.
- `Sources/Sidebar.swift`: the native sidebar and the sidebar state shared by a window's tabs.
- `Sources/QuickOpen.swift`: the Quick Open panel and its file matching.
- `Sources/Settings.swift`: stored settings and the Settings window.
- `Sources/RecoveryStore.swift`: recovery copies of unsaved edits.
- `web/src/app.js`: CodeMirror editor setup, bridge messages, navigation, search, formatting commands, and view state.
- `web/src/live-preview.js`: the live preview, built from CodeMirror decorations over the Markdown syntax tree.
- `web/src/table-editor.js`: the grid table editor, a CodeMirror widget that edits the table's Markdown text.
- `web/src/markdown.js`: Markdown to sanitized HTML (markdown-it and DOMPurify) for export, printing, statistics, and table previews; pasted HTML to Markdown (Turndown); and the front matter rule.
- `web/src/style.css`: writing typography, application layout, themes, and print styles.
- `web/vendor/`: `codemirror.bundle.js` (CodeMirror 6 with GFM Markdown parsing and every CodeMirror code language, markdown-it, DOMPurify, and Turndown), built from the exact versions pinned in `package.json`, with every bundled package's license in `codemirror.bundle.LICENSES.txt`.
- `tools/editor-bundle/` and `scripts/build-editor.sh` (`npm run build:editor`): rebuild the vendored bundle with Rollup. Only needed after changing the bundle entry or a dependency version, and the only step that needs `npm install` (Node.js 20 or later).
- `Resources/`: editable welcome document, Info.plist, the bundle icon, and the icon choices in `Resources/Icons/`.
- `scripts/build.sh`: compiles Swift, copies web assets into the app bundle, and applies an ad hoc signature.

For Swift changes, rebuild the app. Web files are copied during every build. Run `./scripts/make-icon.sh` to regenerate the bundle icon and the icon choices from the Core Graphics source.

## Tests

```sh
npm test               # syntax checks, native unit checks, and WebKit editor checks
npm run test:native    # desktop checks: windows, tabs, the sidebar, open and save, files changed on disk
npm run test:webkit    # WebKit editor checks only; writes build/editor-screenshot.png
```

Node.js is used only for the syntax checks in `npm test`; building and running the app do not need it. The desktop checks need a normal macOS desktop session.

## Errors and recovery

The app reports editor startup failures, failed JavaScript commands, uncaught JavaScript/promise errors, and editor-process termination. Loading has a 15-second timeout. A failed editor shows a native view containing the last text received by the app, with Copy support, Save As, and Retry Editor. Retry loads that native text rather than rereading the original file. Ordinary script errors report the failure while retaining the editor. The native document's undo history remains in memory across editor retries; selection, scroll position, and view mode are not restored.

Edits are sent to the native document as they happen. Recovery copies are written atomically on a background queue, at most once per 750-millisecond interval during continuous typing, in `~/Library/Application Support/Margin/Recovery`. A detected editor failure requests an immediate checkpoint. Recovery-write failures are reported. This supplements native autosaving and the usual Save/Don't Save/Cancel handling. In-flight editor messages and edits since the last completed disk write can still be lost in a crash or power failure.

On launch, recovery copies open as unsaved documents named `Recovered …`, without overwriting the original files. Identical documents already restored are not duplicated. Save As lets you choose the destination. Successful saves, Revert, and intentional document closes remove the corresponding recovery copy. Damaged recovery files are reported and retained for inspection.

When another application changes an open file, a document without unsaved changes reloads and shows "Reloaded from disk". One with unsaved changes keeps its text and shows a banner. Reload asks before discarding the edits. Keep mine saves the edits over the disk version without AppKit's "changed by another application" alert, which still appears if the file changes again before saving. Compare switches to source mode and shows the disk version above each changed part of your text; resolving the last change, or choosing Use disk version for all or Keep mine for all, saves the result. Cancel leaves the edits unsaved and the banner in place. A newer disk version during a comparison updates it in place. While the banner is unresolved, periodic autosave waits; closing or quitting still autosaves and shows AppKit's alert. macOS does not report another application's write that lands within about half a second of Margin's own save, so the app checks the file again 1.5 seconds after each save. Reloading clears the undo history.

Save and Save As read the editor's current text first when the editor is available. The failure view saves only the last text the app received, which it displays.

## First-version boundaries

This implements the core Markdown editing workflow. Math typesetting, Mermaid rendering, footnote tooling, custom CSS theme import, Pandoc formats, and iCloud coordination are not implemented. Code highlighting is in the editor only; HTML export and printing show code fences as plain code.

The editor edits the Markdown text directly, so the file keeps exactly what was typed; nothing is reformatted. Syntax the live preview does not render, such as math and HTML, stays visible as text. The app rejects files that are not UTF-8.

Local image paths must stay within the document directory; parent-directory and symbolic-link escapes are rejected. Exported HTML retains relative image references, so save it beside its Markdown file or use embedded/remote images. The folder browser skips hidden files, symlinks, dependency/build directories, and limits scans to 5,000 entries and 12 directory levels.
