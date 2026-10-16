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

- Editable rendered Markdown with headings, inline formatting, nested lists, task lists, quotes, tables, links, images, and fenced code blocks.
- An exact-text Markdown source editor. Switching modes preserves the original source until an edit is made.
- Folder tree, file filtering, and a clickable document outline.
- Native Open, Open Recent, Save, Save As, autosave, undo/redo, and unsaved-document handling, with multiple document windows.
- Search, word and character counts, line counts, and estimated reading time.
- Settings (⌘,) for Light, Dark, and Auto appearance (follows macOS) and a choice of six Dock icons. The bundled icon shown in Finder is always Night.
- Paragraph focus and typewriter scrolling in live preview.
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
| ⇧⌘F | Paragraph focus |
| ⇧⌘L | Toggle sidebar |
| ⌘P | Print / Save as PDF |

Command-click links to open them. Clicking a file in the sidebar switches the current document, using native document handling for unsaved changes. Opening through File → Open creates a separate document window. The last workspace, appearance, and app icon are remembered.

## Implementation

- `Sources/Margin.swift`: AppKit application, NSDocument lifecycle, menus, file panels, folder browsing, export/printing, and restricted local-image URL handler.
- `web/src/app.js`: editor integration, bridge messages, source buffer, navigation, search, formatting, and view state.
- `web/src/style.css`: writing typography, application layout, themes, and print styles.
- `web/vendor/`: pinned TOAST UI Editor 3.2.2 and DOMPurify 3.4.17, with upstream license files. The current sanitizer overrides the editor's bundled legacy sanitizer.
- `Resources/`: editable welcome document, Info.plist, the bundle icon, and the icon choices in `Resources/Icons/`.
- `scripts/build.sh`: compiles Swift, copies web assets into the app bundle, and applies an ad hoc signature.

For Swift changes, rebuild the app. Web files are copied during every build. Run `./scripts/make-icon.sh` to regenerate the bundle icon and the icon choices from the Core Graphics source.

## Verification

The application builds with the installed Swift compiler. The default suite has 38 checks: nine app-bundle/native registration, startup, recovery, and routing checks, thirteen document/filesystem/session checks, and sixteen editor/bridge behavior checks. Recovery tests exercise exact text persistence, corrupt drafts, failed writes, undo/redo, stale editor messages, and ordering of queued writes and cleanup. Bridge tests cover initialization errors, unavailable preference storage, load acknowledgements, save snapshots, and failed serialization. The editor checks use a DOM emulator and do not verify layout.

With Node.js 20.19 or later installed:

```sh
npm install
npm test
```

This installs a development-only DOM emulator. Building and running the app do not require Node.js or npm.

For visible windows on launch and file opening, the native Open → edit → Save As → Save → reopen flow, menu validation, and a simulated editor-process failure followed by retry, run this in a normal macOS desktop session:

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

Save and Save As read a current editor snapshot before proceeding when the editor is available. Load identifiers and edit revisions prevent delayed messages from overwriting newer text. A known failure to serialize rich text blocks saving an older version as if it were current, and blocks switching to source mode until the text can be read. The native failure view explicitly saves only the last received version displayed there.

## First-version boundaries

This implements the core Markdown editing workflow. Math typesetting, Mermaid rendering, advanced syntax highlighting, footnote tooling, custom CSS theme import, Pandoc formats, and iCloud coordination are not implemented. Code fences display their contents as plain code.

Rich-text edits serialize Markdown and can normalize spacing or unsupported syntax. Use source mode for documents whose exact syntax must be retained, especially front matter, math, and custom extensions. Reading or toggling modes without editing preserves the original bytes as UTF-8 text. The app rejects files that are not UTF-8.

Local image paths must stay within the document directory; parent-directory and symbolic-link escapes are rejected. Exported HTML retains relative image references, so save it beside its Markdown file or use embedded/remote images. The folder browser skips hidden files, symlinks, dependency/build directories, and limits scans to 5,000 entries and 12 directory levels.
