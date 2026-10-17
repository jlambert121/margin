# Margin

A macOS Markdown editor with a single-pane writing experience. Native AppKit document windows wrap an offline WebKit editor.

## Run

Requires macOS 13 or later and Xcode Command Line Tools. No production package installation or web server is needed.

```sh
./scripts/run.sh
```

The built application is `build/Margin.app`. Open it directly or copy it into Applications. It is signed locally for development, and built for the current Mac's architecture. Distribution signing and notarization are not configured.

After rebuilding, quit the running copy with ⌘Q and reopen the app. macOS keeps an already-running copy in memory; rebuilding its bundle does not replace that process. Version 0.1.5 uses the Margin name throughout, with app identifier `com.infiniteviewtech.margin`. The welcome appears only when no documents are restored, recovered, or opening. Window restoration follows the macOS “Close windows when quitting an application” setting.

## Included

- Live preview editing: the document is always the exact Markdown text. Headings, emphasis, strikethrough, inline code, links, quotes, lists, task checkboxes, horizontal rules, fenced code blocks, and images render in place, and their Markdown syntax appears as editable text only where the cursor is. Typing Markdown (such as `## Heading`) renders once the cursor moves on.
- Tables edit as a grid: click a cell to edit its Markdown; Tab/Shift-Tab, Enter, and the up/down arrows move between cells, and Tab in the last cell adds a row. Right-click a cell to insert, delete, or move rows and columns, set column alignment, or edit the table as Markdown. Cell edits rewrite only that cell's text; column changes rewrite the table's rows.
- Source mode (⌘/) shows the same document with all syntax visible.
- Open files list, folder tree, file filtering, and a clickable document outline.
- Native Open, Open Recent, Save, Save As, autosave, undo/redo, and unsaved-document handling. Documents open as native macOS tabs and can be dragged out into their own windows.
- Files changed by another application reload automatically when there are no unsaved changes. With unsaved changes, a banner offers Reload, Keep mine, or Compare, which shows each disk change inline in source mode to keep or take one at a time or all at once.
- Search, word and character counts, line counts, and estimated reading time.
- Settings (⌘,) for Light, Dark, and Auto appearance (follows macOS) and a choice of six Dock icons. The bundled icon shown in Finder is always Night.
- Typewriter scrolling.
- HTML export and native printing with Save as PDF.
- Local images underneath the Markdown file's directory. Dropped or pasted image files are embedded as data URLs; no upload service is used.
- Bundled editor and sanitizer assets; no analytics or network dependency at launch. Images with remote URLs load from their original hosts.

| Shortcut | Action |
| --- | --- |
| ⌘N | New document |
| ⌘O / ⇧⌘O | Open file / folder |
| ⌘S / ⇧⌘S | Save / Save As |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘/ | Toggle Markdown source |
| ⌘B / ⌘I / ⌘K | Bold / Italic / Link |
| ⌘1–6 / ⌘0 | Heading / Body |
| ⌘F | Find |
| ⇧⌘L | Toggle sidebar |
| ⌘P | Print / Save as PDF |

Command-click links to open them. New documents, File → Open, Open Recent, Finder and Dock opens, workspace clicks, and Markdown files dropped on the editor all open as tabs in the current window. The sidebar's Open Files section lists that window's tabs; click one to switch to it, or × to close it with the usual unsaved-changes handling. Dropped images are still embedded in the document. The last workspace, appearance, and app icon are remembered.

## Implementation

- `Sources/Margin.swift`: AppKit application, NSDocument lifecycle, menus, file panels, folder browsing, export/printing, and restricted local-image URL handler.
- `web/src/app.js`: CodeMirror editor setup, bridge messages, navigation, search, formatting commands, and view state.
- `web/src/live-preview.js`: the live preview, built from CodeMirror decorations over the Markdown syntax tree.
- `web/src/table-editor.js`: the grid table editor, a CodeMirror widget that edits the table's Markdown text.
- `web/src/markdown.js`: Markdown to sanitized HTML (markdown-it and DOMPurify) for export, printing, statistics, and table previews.
- `web/src/style.css`: writing typography, application layout, themes, and print styles.
- `web/vendor/`: `codemirror.bundle.js` (CodeMirror 6 with GFM Markdown parsing, markdown-it, and DOMPurify), built from the exact versions pinned in `package.json`, with every bundled package's license in `codemirror.bundle.LICENSES.txt`.
- `tools/editor-bundle/` and `scripts/build-editor.sh` (`npm run build:editor`): rebuild the vendored bundle with Rollup. Only needed after changing the bundle entry or a dependency version, and the only step that needs `npm install` (Node.js 20 or later).
- `Resources/`: editable welcome document, Info.plist, the bundle icon, and the icon choices in `Resources/Icons/`.
- `scripts/build.sh`: compiles Swift, copies web assets into the app bundle, and applies an ad hoc signature.

For Swift changes, rebuild the app. Web files are copied during every build. Run `./scripts/make-icon.sh` to regenerate the bundle icon and the icon choices from the Core Graphics source.

## Verification

The application builds with the installed Swift compiler. The default suite has 62 checks: fourteen app-bundle/native registration, settings, startup, recovery, and open-queue checks, sixteen document/filesystem/session/disk-change checks, and thirty-two editor checks in WebKit: twenty behavior checks and twelve native bridge checks. Recovery tests exercise exact text persistence, corrupt drafts, failed writes, undo/redo, stale editor messages, and ordering of queued writes and cleanup. Disk-change tests cover reloading, keeping edits while periodic autosave waits, Keep mine, Reload, and matching or unreadable disk versions. Bridge tests cover initialization errors, unavailable browser storage, load acknowledgements, save snapshots, text from the app not being reported back as edits, undo keys reaching native undo, the open-files list, color scheme changes, the disk-change banner, and comparing with the disk version. The WebKit checks cover live preview rendering, markers appearing at the cursor, typed Markdown rendering, task checkboxes, grid table editing (cells, keyboard movement, the table menu, and Edit as Markdown), source mode, formatting commands, outline, search, sanitizing, export and print rendering, and that the page raises no uncaught errors. The bridge checks load the page in native mode against a recording message handler (`tests/bridge.setup.js`).

With Node.js installed (used only for syntax checks; no packages are needed):

```sh
npm test
```

Building and running the app do not require Node.js or npm.

For the 25 desktop checks — visible windows on launch and file opening, tabs and the open-files list, Markdown drops, ordered opens, editor undo, appearance and Dock icon, window frames, the native Open → edit → Save As → Save → reopen flow, files changed by another application, menu validation, and a simulated editor-process failure followed by retry — run this in a normal macOS desktop session:

```sh
npm run test:native
```

These checks need LaunchServices and desktop access and are explicitly skipped by the default sandbox-compatible suite. To send an actual file-opening event to the built app from a desktop Terminal:

```sh
open -a "$PWD/build/Margin.app" "$PWD/Resources/Welcome.md"
```

For real WebKit behavior checks and a screenshot:

```sh
npm run test:webkit
```

The WebKit runner writes `build/editor-screenshot.png`. In the development sandbox, desktop processes and LaunchServices metadata access are unavailable, so the full desktop checks, physical Dock drag-and-drop, visual appearance, native dialogs, and print output remain unverified here.

## Errors and recovery

The app reports editor startup failures, failed JavaScript commands, uncaught JavaScript/promise errors, and editor-process termination. Loading has a 15-second timeout. A failed editor shows a native view containing the last text received by the app, with Copy support, Save As, and Retry Editor. Retry loads that native text rather than rereading the original file. Ordinary script errors report the failure while retaining the editor. The native document's undo history remains in memory across editor retries; selection, scroll position, and view mode are not restored.

Edits are sent to the native document as they happen. Recovery copies are written atomically on a background queue, at most once per 750-millisecond interval during continuous typing, in `~/Library/Application Support/Margin/Recovery`. A detected editor failure requests an immediate checkpoint. Recovery-write failures are reported. This supplements native autosaving and the usual Save/Don't Save/Cancel handling. In-flight editor messages and edits since the last completed disk write can still be lost in a crash or power failure.

On launch, recovery copies open as unsaved documents named `Recovered …`, without overwriting the original files. Identical documents already restored are not duplicated. Save As lets you choose the destination. Successful saves, Revert, and intentional document closes remove the corresponding recovery copy. Damaged recovery files are reported and retained for inspection.

When another application changes an open file, a document without unsaved changes reloads and shows "Reloaded from disk". One with unsaved changes keeps its text and shows a banner. Reload asks before discarding the edits. Keep mine saves the edits over the disk version without AppKit's "changed by another application" alert, which still appears if the file changes again before saving. Compare switches to source mode and shows the disk version above each changed part of your text; resolving the last change, or choosing Use disk version for all or Keep mine for all, saves the result. Cancel leaves the edits unsaved and the banner in place. A newer disk version during a comparison updates it in place. While the banner is unresolved, periodic autosave waits; closing or quitting still autosaves and shows AppKit's alert. macOS does not report another application's write that lands within about half a second of Margin's own save, so the app checks the file again 1.5 seconds after each save. Reloading clears the undo history.

Save and Save As read a current editor snapshot before proceeding when the editor is available. Load identifiers and edit revisions prevent delayed messages from overwriting newer text. The native failure view explicitly saves only the last received version displayed there.

## First-version boundaries

This implements the core Markdown editing workflow. Math typesetting, Mermaid rendering, advanced syntax highlighting, footnote tooling, custom CSS theme import, Pandoc formats, and iCloud coordination are not implemented. Code fences display their contents as plain code.

The editor edits the Markdown text directly, so the file keeps exactly what was typed; nothing is reformatted. Syntax the live preview does not render, such as front matter, math, and HTML, stays visible as text. The app rejects files that are not UTF-8.

Local image paths must stay within the document directory; parent-directory and symbolic-link escapes are rejected. Exported HTML retains relative image references, so save it beside its Markdown file or use embedded/remote images. The folder browser skips hidden files, symlinks, dependency/build directories, and limits scans to 5,000 entries and 12 directory levels.
