/* Native bridge and presentation layer. All editor dependencies are bundled locally. */
(() => {
  'use strict';
  const $ = (selector) => document.querySelector(selector);
  const native = Boolean(window.webkit?.messageHandlers?.native);
  const post = (action, payload = {}) => {
    if (native) window.webkit.messageHandlers.native.postMessage({ action, ...payload });
    else if (action === 'changed') sessionStorage.setItem('margin-draft', payload.text);
    else if (action === 'openExternal') window.open(payload.url, '_blank', 'noopener');
    else if (['undo', 'redo', 'outline', 'contextMenu'].includes(action)) return;
    else toast('Open the macOS app to use native file operations.');
  };
  const welcome = '# A little room to think.\n\nWelcome to **Margin**. A quiet place for your notes, ideas, and everything in between.\n\n## Just start writing\n\nYour words take shape as you type. Use Markdown shortcuts for headings, **bold**, *italics*, and lists — the formatting appears right here on the page.\n\n> The secret of getting ahead is getting started.\n\n## Make yourself at home\n\n- Open a Markdown file with **⌘O**\n- Browse a folder with **⇧⌘O**\n- Switch to source mode with **⌘/**\n- Save your work with **⌘S**\n\n### A few things to try\n\n- [x] Find a little space to write\n- [ ] Put an idea into words\n- [ ] Make something worth keeping\n\n## For the details\n\nCode, tables, links, and images all have a place here.\n\n```swift\nlet thought = "Something worth writing down."\nprint(thought)\n```\n\n| Shortcut | A small superpower |\n| --- | --- |\n| ⌘B | A little emphasis |\n| ⌘F | Find the right words |\n\n---\n\nTake your time. The page is yours.\n';
  const { EditorState, EditorSelection, ChangeSet, Compartment, Annotation, Prec, EditorView, keymap, placeholder, drawSelection,
    defaultKeymap, indentWithTab, markdown, markdownLanguage, codeLanguages, syntaxTree, ensureSyntaxTree, syntaxHighlighting, languageDataProp,
    tags, tagHighlighter, closeBrackets, closeBracketsKeymap, yamlLanguage, parseMixed,
    unifiedMergeView, getChunks, getOriginalDoc, originalDocChangeEffect } = MarginEditor;
  let raw = native ? '' : sessionStorage.getItem('margin-draft') ?? welcome;
  let sourceMode = false;
  let currentPath = '';
  let currentName = '';
  let documentToken = null;
  let editRevision = 0;
  let toastTimer;
  let refreshTimer;
  let activeMatch = -1;
  let insertKind = 'link';
  // The file's text on disk while it differs from unsaved edits, and the mode to restore after comparing them.
  let diskText = null;
  let comparing = null;

  // In the app, WebKit matches this to the window's appearance, which follows Settings.
  const systemAppearance = window.matchMedia('(prefers-color-scheme: dark)');
  const applyTheme = () => { document.body.dataset.theme = systemAppearance.matches ? 'dark' : 'light'; };
  systemAppearance.addEventListener('change', applyTheme);
  applyTheme();

  // Text that arrives from the app is not an edit to report back to it.
  const fromApp = Annotation.define();
  const preview = new Compartment();
  const comparison = new Compartment();
  function readImages(files) {
    return Promise.all(files.map(file => new Promise(resolve => {
      const reader = new FileReader();
      reader.onload = () => resolve(`![${(file.name || 'Image').replace(/[[\]]/g, '')}](${reader.result})`);
      reader.onerror = () => resolve('');
      reader.readAsDataURL(file);
    })));
  }
  // Pasted and dropped images are embedded as data URLs; nothing is uploaded.
  function insertImages(files, pos) {
    readImages(files).then(images => {
      const text = images.filter(Boolean).join('\n');
      if (text) view.dispatch({ changes: { from: pos, insert: text }, selection: { anchor: pos + text.length }, userEvent: 'input.paste' });
    });
  }
  // Front matter is a block of its own, parsed as YAML, so its closing "---" does not
  // turn the YAML above it into a heading.
  const fm = MarginMarkdown.frontmatter;
  const frontmatterSyntax = {
    defineNodes: [{ name: 'Frontmatter', block: true }, 'FrontmatterMark', 'FrontmatterContent'],
    parseBlock: [{
      name: 'Frontmatter',
      before: 'HorizontalRule',
      parse(cx, line) {
        if (cx.lineStart !== 0 || !fm.open.test(line.text) || !fm.key.test(cx.peekLine())) return false;
        const children = [cx.elt('FrontmatterMark', 0, line.text.length)];
        let contentFrom = -1, end = line.text.length, closed = false;
        while (cx.nextLine()) {
          const from = cx.lineStart, to = from + line.text.length;
          if (fm.close.test(line.text)) {
            if (contentFrom >= 0) children.push(cx.elt('FrontmatterContent', contentFrom, end));
            children.push(cx.elt('FrontmatterMark', from, to));
            end = to; closed = true; cx.nextLine();
            break;
          }
          if (contentFrom < 0) contentFrom = from;
          end = to;
        }
        // Without a closing line it runs to the end of the document.
        if (!closed && contentFrom >= 0) children.push(cx.elt('FrontmatterContent', contentFrom, end));
        cx.addElement(cx.elt('Frontmatter', 0, end, children));
        return true;
      },
    }],
    wrap: parseMixed(node => node.name === 'FrontmatterContent' ? { parser: yamlLanguage.parser } : null),
  };
  // GFM Markdown with list continuation on Enter, pasting a URL over text as a link,
  // and fenced code parsed in the language its info string names.
  const markdownSupport = markdown({ base: markdownLanguage, codeLanguages, completeHTMLTags: false, extensions: frontmatterSyntax });
  // Single quotes are left out because they are usually apostrophes in prose.
  const markdownBrackets = markdownSupport.language.data.of({ closeBrackets: { brackets: ['(', '[', '{', '"', '`'] } });
  // Typing an emphasis marker over a selection wraps it rather than replacing it.
  const wrapSelectionMarkers = EditorView.inputHandler.of((view, from, to, text) => {
    if (!['*', '_', '~'].includes(text) || view.state.selection.ranges.every(range => range.empty)) return false;
    view.dispatch(view.state.changeByRange(range => range.empty
      ? { changes: { from: range.from, insert: text }, range: EditorSelection.cursor(range.from + 1) }
      : { changes: [{ from: range.from, insert: text }, { from: range.to, insert: text }], range: EditorSelection.range(range.anchor + 1, range.head + 1) }), { userEvent: 'input.type' });
    return true;
  });
  // Token classes for code inside fenced blocks. Markdown's own syntax is left to live preview.
  const codeHighlighter = tagHighlighter([
    { tag: [tags.keyword, tags.modifier, tags.self, tags.operatorKeyword, tags.controlKeyword, tags.definitionKeyword, tags.moduleKeyword], class: 'cm-code-keyword' },
    { tag: [tags.string, tags.special(tags.string), tags.character, tags.attributeValue, tags.docString], class: 'cm-code-string' },
    { tag: [tags.number, tags.bool, tags.null, tags.atom, tags.unit, tags.color], class: 'cm-code-number' },
    { tag: [tags.comment, tags.lineComment, tags.blockComment, tags.docComment], class: 'cm-code-comment' },
    { tag: [tags.function(tags.variableName), tags.function(tags.propertyName), tags.macroName], class: 'cm-code-function' },
    { tag: [tags.typeName, tags.className, tags.namespace, tags.standard(tags.variableName)], class: 'cm-code-type' },
    { tag: [tags.propertyName, tags.attributeName, tags.labelName], class: 'cm-code-property' },
    { tag: [tags.tagName, tags.angleBracket], class: 'cm-code-tag' },
    { tag: [tags.regexp, tags.escape, tags.special(tags.variableName)], class: 'cm-code-regexp' },
    { tag: [tags.meta, tags.annotation, tags.processingInstruction, tags.heading], class: 'cm-code-meta' },
    { tag: tags.inserted, class: 'cm-code-inserted' },
    { tag: tags.deleted, class: 'cm-code-deleted' },
    { tag: tags.invalid, class: 'cm-code-invalid' },
  ], { scope: type => type.prop(languageDataProp) !== markdownSupport.language.data });
  const imageFiles = list => [...(list ?? [])].filter(file => file.type.startsWith('image/'));
  function linkTarget(pos) {
    for (let node = syntaxTree(view.state).resolve(pos, 1); node; node = node.parent) {
      if (node.name === 'Link') { const url = node.getChild('URL'); return url ? view.state.sliceDoc(url.from, url.to).replace(/^<|>$/g, '') : null; }
      if (node.name === 'URL') return view.state.sliceDoc(node.from, node.to);
      if (node.name === 'Autolink') return view.state.sliceDoc(node.from + 1, node.to - 1);
    }
    return null;
  }
  const view = new EditorView({
    parent: $('#editor'),
    state: EditorState.create({ doc: raw, extensions: [
      markdownSupport,
      markdownBrackets,
      closeBrackets(),
      wrapSelectionMarkers,
      syntaxHighlighting(codeHighlighter),
      EditorView.lineWrapping,
      drawSelection(),
      EditorView.contentAttributes.of({ spellcheck: 'true', 'aria-label': 'Markdown document' }),
      placeholder('Begin anywhere…'),
      preview.of(MarginLivePreview.extension),
      comparison.of([]),
      keymap.of([...closeBracketsKeymap, indentWithTab, ...defaultKeymap]),
      EditorView.updateListener.of(update => {
        if (update.docChanged && !update.transactions.some(tr => tr.annotation(fromApp))) changed(update.state.doc.toString());
        // The comparison can finish with a view update of its own, which cannot start inside this one.
        if (comparing) queueMicrotask(updateComparison);
        if (update.selectionSet || update.docChanged) updateCursorPosition(update.state);
        if (update.selectionSet && document.body.classList.contains('typewriter') && update.view.hasFocus) {
          setTimeout(() => view.dispatch({ effects: EditorView.scrollIntoView(view.state.selection.main.head, { y: 'center' }) }));
        }
      }),
      EditorView.domEventHandlers({
        paste(event) {
          const files = imageFiles(event.clipboardData?.files);
          if (files.length) { event.preventDefault(); insertImages(files, view.state.selection.main.from); return true; }
          // Code keeps the plain text.
          const at = syntaxTree(view.state).resolve(view.state.selection.main.from, -1);
          for (let node = at; node; node = node.parent) if (['FencedCode', 'CodeBlock', 'InlineCode', 'Frontmatter'].includes(node.name)) return false;
          const markdown = MarginMarkdown.fromHTML(event.clipboardData?.getData('text/html'), event.clipboardData?.getData('text/plain'));
          if (markdown === null) return false;
          event.preventDefault();
          insertText(markdown);
          return true;
        },
        drop(event) {
          const files = imageFiles(event.dataTransfer?.files);
          if (!files.length) return false;
          event.preventDefault();
          insertImages(files, view.posAtCoords({ x: event.clientX, y: event.clientY }) ?? view.state.selection.main.from);
          return true;
        },
        // Right-click selects the word under the pointer, which spelling suggestions and Look Up
        // use. On a blank line or between words that is only spacing, so the cursor goes there
        // instead, and text already selected stays selected for Cut and Copy.
        contextmenu(event) {
          const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
          if (pos !== null) {
            const line = view.state.doc.lineAt(pos);
            const around = line.text.slice(Math.max(0, pos - line.from - 1), pos - line.from + 1);
            const inSelection = view.state.selection.ranges.some(range => range.from <= pos && range.to >= pos && /\S/.test(view.state.sliceDoc(range.from, range.to)));
            if (!inSelection && !/\S/.test(around)) view.dispatch({ selection: { anchor: pos } });
          }
          // The app adds the document's commands to the menu that follows.
          post('contextMenu');
          return false;
        },
        // Command-click follows a link; a plain click places the cursor to edit it.
        mousedown(event) {
          if (!(event.metaKey || event.ctrlKey)) return false;
          const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
          const href = pos == null ? null : linkTarget(pos);
          if (!href) return false;
          event.preventDefault();
          if (href.startsWith('#')) {
            const heading = headings().find(h => h.text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-') === href.slice(1));
            if (heading) revealPosition(heading.pos, 'start');
          } else post('openExternal', { url: href });
          return true;
        },
      }),
    ] }),
  });

  function insertText(text) {
    view.dispatch(view.state.replaceSelection(text), { userEvent: 'input.paste', scrollIntoView: true });
  }
  // Paste and Match Style goes to a focused field, such as Find, or else the document.
  function pastePlain(text) {
    const field = document.activeElement;
    if (field?.matches?.('input, textarea, [contenteditable]') && !view.contentDOM.contains(field)) document.execCommand('insertText', false, text);
    else { insertText(text); view.focus(); }
  }
  function toast(message) {
    clearTimeout(toastTimer);
    $('#toast').textContent = message;
    $('#toast').hidden = false;
    toastTimer = setTimeout(() => $('#toast').hidden = true, 3000);
  }
  function updateCursorPosition(state) {
    const head = state.selection.main.head, line = state.doc.lineAt(head);
    $('#cursor-position').textContent = `Ln ${line.number.toLocaleString()}, Col ${(head - line.from + 1).toLocaleString()}`;
  }
  function changed(text) {
    raw = text;
    post('changed', { text: raw, token: documentToken, revision: ++editRevision });
    $('#modified-dot').hidden = false;
    $('#save-status').textContent = 'Edited';
    refresh();
  }
  function refresh() {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => {
      const plain = MarginMarkdown.renderFragment(raw).replace(/<[^>]*>/g, ' ').replace(/&[^;]+;/g, ' ');
      const words = plain.trim().split(/\s+/u).filter(Boolean).length;
      $('#word-count').textContent = `${words.toLocaleString()} ${words === 1 ? 'word' : 'words'}`;
      $('#word-count').title = `${raw.length.toLocaleString()} characters · ${raw.split('\n').length.toLocaleString()} lines`;
      $('#reading-time').textContent = `${Math.max(1, Math.ceil(words / 225))} min read`;
      postOutline();
    }, 80);
  }
  // Reloading the same document (such as after native undo) applies only the
  // changed span, so the cursor and scroll position stay near the edit.
  function replaceText(text, sameDocument) {
    const current = view.state.doc.toString();
    if (!sameDocument) {
      view.dispatch({ changes: { from: 0, to: current.length, insert: text }, selection: { anchor: 0 }, effects: EditorView.scrollIntoView(0), annotations: fromApp.of(true) });
      return;
    }
    const change = spanChange(current, text);
    if (change) view.dispatch({ changes: change, annotations: fromApp.of(true) });
  }
  // The single replacement that turns current into text, leaving their shared start and end alone.
  function spanChange(current, text) {
    let start = 0;
    while (start < current.length && start < text.length && current[start] === text[start]) start++;
    let endCurrent = current.length, endText = text.length;
    while (endCurrent > start && endText > start && current[endCurrent - 1] === text[endText - 1]) { endCurrent--; endText--; }
    return start === endCurrent && start === endText ? null : { from: start, to: endCurrent, insert: text.slice(start, endText) };
  }
  function loadDocument(data) {
    const name = data.name || 'Untitled.md';
    const sameDocument = name === currentName && (data.path || '') === currentPath;
    raw = data.text;
    currentPath = data.path || '';
    currentName = name;
    replaceText(raw, sameDocument);
    $('#document-name').textContent = name;
    $('#document-name').title = currentPath || 'Untitled document';
    $('#modified-dot').hidden = !data.modified;
    $('#save-status').textContent = data.modified ? 'Edited' : currentPath ? 'Saved locally' : 'Ready to write';
    if (typeof data.sidebarOpen === 'boolean') document.body.classList.toggle('sidebar-open', data.sidebarOpen);
    if (data.textZoom != null) setTextZoom(Number(data.textZoom));
    if (data.titlebar) setTitlebar(data.titlebar);
    refresh();
    documentToken = data.token ?? null;
    editRevision = 0;
    if (data.notice) toast(data.notice);
    if (native) post('loaded', { token: documentToken });
  }
  // Native sends the disk text while it conflicts with unsaved edits, and null once resolved.
  function setDiskText(text) {
    diskText = typeof text === 'string' ? text : null;
    if (comparing && diskText === null) endComparison();
    else if (comparing) {
      const original = getOriginalDoc(view.state).toString();
      const change = spanChange(original, diskText);
      if (!change) return;
      view.dispatch({ effects: originalDocChangeEffect(view.state, ChangeSet.of(change, original.length)) });
      toast('The file changed on disk again. The comparison now shows the newest version.');
      return;
    }
    $('#disk-banner').hidden = diskText === null;
  }
  function keepMine() {
    $('#disk-banner').hidden = true;
    post('diskKeepMine');
  }
  // In a unified merge view the document is your text and the original is the
  // disk's, so accepting a change keeps yours and rejecting it takes the disk's.
  function chunkButton(type, action) {
    const button = document.createElement('button');
    button.name = type;
    button.textContent = type === 'accept' ? 'Keep mine' : 'Use disk version';
    button.onmousedown = action;
    return button;
  }
  // Comparing uses source mode, where no live preview widgets sit among the changes.
  function startComparison() {
    if (diskText === null || comparing) return;
    comparing = { wasSource: sourceMode };
    toggleSource(true);
    closeMenus();
    $('#disk-banner').hidden = true;
    $('#compare-bar').hidden = false;
    view.dispatch({ effects: comparison.reconfigure(unifiedMergeView({ original: diskText, gutter: false, syntaxHighlightDeletions: false, mergeControls: chunkButton })) });
    const first = getChunks(view.state)?.chunks[0];
    if (first) revealPosition(first.fromB);
    updateComparison();
  }
  // Resolving the last change finishes the comparison.
  function updateComparison() {
    if (!comparing) return;
    const count = getChunks(view.state)?.chunks.length ?? 0;
    if (!count) { finishComparison(); return; }
    $('#compare-status').textContent = `${count} ${count === 1 ? 'change differs' : 'changes differ'} from the disk version, which is shown above your text.`;
  }
  function endComparison() {
    const { wasSource } = comparing;
    comparing = null;
    view.dispatch({ effects: comparison.reconfigure([]) });
    $('#compare-bar').hidden = true;
    toggleSource(wasSource);
  }
  function finishComparison() {
    endComparison();
    keepMine();
  }
  function useDiskForAll() {
    if (!comparing) return;
    const change = spanChange(view.state.doc.toString(), getOriginalDoc(view.state).toString());
    if (change) view.dispatch({ changes: change, userEvent: 'revert' });
    finishComparison();
  }
  function cancelComparison() {
    if (!comparing) return;
    endComparison();
    $('#disk-banner').hidden = diskText === null;
  }
  function updateMetadata(data) {
    currentPath = data.path || '';
    currentName = data.name || 'Untitled.md';
    $('#document-name').textContent = currentName;
    $('#document-name').title = currentPath || 'Untitled document';
    $('#modified-dot').hidden = !data.modified;
    $('#save-status').textContent = data.modified ? 'Edited' : 'Saved locally';
  }
  // Source mode is the same editor with the live preview layer switched off.
  function toggleSource(force) {
    const next = typeof force === 'boolean' ? force : !sourceMode;
    if (next === sourceMode) return;
    sourceMode = next;
    view.dispatch({ effects: preview.reconfigure(sourceMode ? [] : MarginLivePreview.extension) });
    $('#editor').classList.toggle('source-mode', sourceMode);
    $('#source-button').setAttribute('aria-pressed', String(sourceMode));
    closeMenus();
    view.focus();
  }
  function headings() {
    const state = view.state;
    const tree = ensureSyntaxTree(state, state.doc.length, 100) ?? syntaxTree(state);
    const result = [];
    tree.iterate({ enter(node) {
      // Fenced code is parsed in its own language, which may itself be Markdown.
      if (['FencedCode', 'CodeBlock', 'Frontmatter'].includes(node.name)) return false;
      const match = /^(?:ATX|Setext)Heading(\d)$/.exec(node.name);
      if (!match) return;
      const firstLine = state.doc.lineAt(node.from);
      const text = (node.name.startsWith('ATX') ? firstLine.text.replace(/^\s*#{1,6}\s*/, '').replace(/\s+#+\s*$/, '') : state.sliceDoc(node.from, state.doc.lineAt(node.to).from).trim()).trim();
      if (text) result.push({ level: +match[1], text, pos: node.from });
      return false;
    } });
    return result;
  }
  function revealPosition(pos, y = 'center') {
    view.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y, yMargin: 40 }) });
    view.focus();
  }
  // The native sidebar lists the outline; only send it when it changes.
  let sentOutline = '';
  function postOutline() {
    const outline = JSON.stringify(headings());
    if (outline === sentOutline) return;
    sentOutline = outline;
    post('outline', { headings: JSON.parse(outline) });
  }
  function setTypewriter() {
    const on = document.body.classList.toggle('typewriter');
    $('#typewriter-check').textContent = on ? '✓' : '';
    closeMenus();
  }
  function closeMenus() {
    $('#format-menu').hidden = true; $('#view-menu').hidden = true;
    $('#format-button').setAttribute('aria-expanded', 'false'); $('#more-button').setAttribute('aria-expanded', 'false');
  }
  function openMenu(id, trigger) {
    const wasHidden = $(id).hidden; closeMenus(); $(id).hidden = !wasHidden; $(trigger).setAttribute('aria-expanded', String(wasHidden));
  }
  function insertDialog(kind) {
    insertKind = kind;
    const { from, to } = view.state.selection.main;
    $('#insert-title').textContent = kind === 'image' ? 'Insert image' : 'Insert link';
    $('#insert-url').value = ''; $('#insert-description').value = view.state.sliceDoc(from, to);
    $('#insert-dialog').showModal(); $('#insert-url').focus();
  }
  $('#insert-dialog').addEventListener('close', () => {
    if ($('#insert-dialog').returnValue !== 'insert') return;
    const url = $('#insert-url').value.trim(); const description = $('#insert-description').value.trim();
    if (!url || /^(javascript|vbscript|file):/i.test(url) || (insertKind === 'link' && /^data:/i.test(url))) { toast('Please use a web address or a relative file path.'); return; }
    const label = (insertKind === 'image' ? description : description || url).replace(/[[\]]/g, '\\$&');
    const target = /\s|[()]/.test(url) ? `<${url}>` : url;
    const text = `${insertKind === 'image' ? '!' : ''}[${label}](${target})`;
    const { from, to } = view.state.selection.main;
    view.dispatch({ changes: { from, to, insert: text }, selection: { anchor: from + text.length }, userEvent: 'input.format' });
    view.focus();
  });
  // Formatting edits the Markdown text, so it works the same in both modes.
  function wrapSelection(marker) {
    view.dispatch(view.state.changeByRange(range => {
      const before = view.state.sliceDoc(range.from - marker.length, range.from);
      const after = view.state.sliceDoc(range.to, range.to + marker.length);
      const outside = view.state.sliceDoc(range.from - marker.length - 1, range.from - marker.length) + view.state.sliceDoc(range.to + marker.length, range.to + marker.length + 1);
      if (before === marker && after === marker && !outside.includes(marker[0])) {
        return { changes: [{ from: range.from - marker.length, to: range.from }, { from: range.to, to: range.to + marker.length }],
          range: EditorSelection.range(range.from - marker.length, range.to - marker.length) };
      }
      return { changes: [{ from: range.from, insert: marker }, { from: range.to, insert: marker }],
        range: EditorSelection.range(range.from + marker.length, range.to + marker.length) };
    }), { userEvent: 'input.format' });
  }
  function selectedLines() {
    const { doc, selection } = view.state;
    const lines = new Map();
    for (const range of selection.ranges) {
      for (let pos = range.from; pos <= range.to;) { const line = doc.lineAt(pos); lines.set(line.number, line); pos = line.to + 1; }
    }
    return [...lines.values()].sort((a, b) => a.number - b.number);
  }
  function setHeading(level) {
    const changes = selectedLines().map(line => {
      const existing = /^#{1,6}[ \t]+|^#{1,6}$/.exec(line.text)?.[0].length ?? 0;
      return { from: line.from, to: line.from + existing, insert: level ? `${'#'.repeat(level)} ` : '' };
    });
    view.dispatch({ changes, userEvent: 'input.format' });
  }
  const listPrefix = /^(\s*)(?:[-*+] \[[ xX]\] |[-*+] |\d+[.)] )?/;
  const listKinds = {
    bulletList: { test: /^\s*[-*+] (?!\[[ xX]\] )/, prefix: () => '- ' },
    orderedList: { test: /^\s*\d+[.)] /, prefix: index => `${index + 1}. ` },
    taskList: { test: /^\s*[-*+] \[[ xX]\] /, prefix: () => '- [ ] ' },
  };
  function toggleList(kind) {
    const lines = selectedLines();
    const { test, prefix } = listKinds[kind];
    const removing = lines.every(line => test.test(line.text));
    const changes = lines.map((line, index) => {
      const [whole, indent] = listPrefix.exec(line.text);
      return { from: line.from + indent.length, to: line.from + whole.length, insert: removing ? '' : prefix(index) };
    });
    view.dispatch({ changes, userEvent: 'input.format' });
  }
  function toggleQuote() {
    const lines = selectedLines();
    const removing = lines.every(line => /^>/.test(line.text));
    const changes = lines.map(line => removing ? { from: line.from, to: line.from + (/^> ?/.exec(line.text)[0].length) } : { from: line.from, insert: '> ' });
    view.dispatch({ changes, userEvent: 'input.format' });
  }
  function insertBlock(text, cursorOffset) {
    const line = view.state.doc.lineAt(view.state.selection.main.head);
    const blank = !line.text.trim();
    const lead = blank ? '' : '\n\n';
    const from = blank ? line.from : line.to;
    view.dispatch({ changes: { from, to: line.to, insert: lead + text }, selection: { anchor: from + lead.length + cursorOffset }, userEvent: 'input.format' });
  }
  function codeBlock() {
    const lines = selectedLines();
    const { from, to } = view.state.selection.main;
    if (from === to && !lines[0].text.trim()) { insertBlock('```\n\n```', 4); return; }
    const first = lines[0], last = lines[lines.length - 1];
    view.dispatch({ changes: [{ from: first.from, insert: '```\n' }, { from: last.to, insert: '\n```' }], userEvent: 'input.format' });
  }
  function format(kind) {
    closeMenus();
    if (kind === 'link' || kind === 'image') { insertDialog(kind); return; }
    if (/^h[1-6]$/.test(kind)) setHeading(+kind[1]);
    else if (kind === 'paragraph') setHeading(0);
    else if (kind === 'bold') wrapSelection('**');
    else if (kind === 'italic') wrapSelection('*');
    else if (kind === 'strike') wrapSelection('~~');
    else if (kind === 'code') wrapSelection('`');
    else if (kind in listKinds) toggleList(kind);
    else if (kind === 'blockquote') toggleQuote();
    else if (kind === 'codeBlock') codeBlock();
    else if (kind === 'table') insertBlock('| Column | Column | Column |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |', 2);
    view.focus();
  }
  const useRegex = () => $('#find-regex').getAttribute('aria-pressed') === 'true';
  // Null without a query, and undefined when the regular expression does not compile.
  function findPattern() {
    const query = $('#find-input').value;
    if (!query) return null;
    try { return new RegExp(useRegex() ? query : query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gimu'); } catch { return undefined; }
  }
  function findMatches(pattern) {
    const matches = [];
    for (const match of view.state.doc.toString().matchAll(pattern)) if (match[0]) matches.push({ from: match.index, to: match.index + match[0].length, match });
    return matches;
  }
  // With after, selects the first match starting there or later; otherwise steps from the current match.
  function find(direction = 1, after = null) {
    const pattern = findPattern();
    if (!pattern) { $('#find-result').textContent = pattern === null ? '' : 'Invalid pattern'; return; }
    const matches = findMatches(pattern);
    if (!matches.length) { $('#find-result').textContent = 'No matches'; return; }
    if (after === null) activeMatch = (activeMatch + direction + matches.length) % matches.length;
    else activeMatch = Math.max(0, matches.findIndex(match => match.from >= after));
    const { from, to } = matches[activeMatch];
    view.dispatch({ selection: { anchor: from, head: to }, effects: EditorView.scrollIntoView(from, { y: 'center' }) });
    $('#find-result').textContent = `${activeMatch + 1} of ${matches.length}`;
  }
  // In regular expression mode the replacement expands $$, $&, $`, $', $1–$99 and $<name> as
  // String.replace does. It is done here because WebKit's replace ignores lastIndex on a sticky
  // pattern, so a single match cannot be replaced in place with the document as context.
  function replacementFor(text, { match }) {
    const replacement = $('#replace-input').value;
    if (!useRegex()) return replacement;
    return replacement.replace(/\$(?:([$&`'])|(\d\d?)|<([^>]*)>)/g, (token, symbol, digits, name) => {
      if (symbol === '$') return '$';
      if (symbol === '&') return match[0];
      if (symbol === '`') return text.slice(0, match.index);
      if (symbol === "'") return text.slice(match.index + match[0].length);
      if (name !== undefined) return match.groups ? match.groups[name] ?? '' : token;
      if (digits.length === 2 && +digits > 0 && +digits < match.length) return match[+digits] ?? '';
      return +digits[0] > 0 && +digits[0] < match.length ? (match[+digits[0]] ?? '') + digits.slice(1) : token;
    });
  }
  function replaceOne() {
    const pattern = findPattern();
    if (!pattern) return;
    const { from, to } = view.state.selection.main;
    const current = findMatches(pattern).find(match => match.from === from && match.to === to);
    if (!current) { find(1, from); return; }
    const insert = replacementFor(view.state.doc.toString(), current);
    view.dispatch({ changes: { from, to, insert }, selection: { anchor: from + insert.length }, userEvent: 'input.replace' });
    find(1, from + insert.length);
  }
  function replaceAll() {
    const pattern = findPattern();
    if (!pattern) return;
    const text = view.state.doc.toString();
    const matches = findMatches(pattern);
    if (!matches.length) return;
    view.dispatch({ changes: matches.map(match => ({ from: match.from, to: match.to, insert: replacementFor(text, match) })), userEvent: 'input.replace.all' });
    activeMatch = -1;
    $('#find-result').textContent = `Replaced ${matches.length.toLocaleString()}`;
  }
  function showFind(replacing = false) {
    $('#goto-bar').hidden = true;
    $('#find-bar').hidden = false;
    $('#find-bar').classList.toggle('replacing', replacing);
    const input = replacing && $('#find-input').value ? $('#replace-input') : $('#find-input');
    input.focus(); input.select();
  }
  function showGoToLine() {
    $('#find-bar').hidden = true;
    $('#goto-bar').hidden = false;
    $('#goto-input').placeholder = `Go to line (1–${view.state.doc.lines.toLocaleString()}), or line:column`;
    $('#goto-result').textContent = '';
    $('#goto-input').focus(); $('#goto-input').select();
  }
  // Line and column count from 1 and are clamped to the document.
  function goToLine() {
    const match = /^\s*(\d+)\s*(?:[:,]\s*(\d+))?\s*$/.exec($('#goto-input').value);
    if (!match) { $('#goto-result').textContent = 'Enter a line number'; return; }
    const doc = view.state.doc;
    const line = doc.line(Math.min(Math.max(+match[1], 1), doc.lines));
    const column = Math.min(Math.max(+(match[2] ?? 1), 1), line.length + 1);
    $('#goto-bar').hidden = true;
    revealPosition(line.from + column - 1);
  }
  // The native title bar, and its tab bar when shown, cover the top of the page.
  function setTitlebar({ inset = 0, tabBar = false } = {}) {
    document.documentElement.style.setProperty('--titlebar-inset', `${Math.max(0, Number(inset) || 0)}px`);
    document.body.classList.toggle('tab-bar', Boolean(tabBar));
  }
  function setTextZoom(zoom) {
    if (Number.isFinite(zoom) && zoom > 0) { $('#editor').style.setProperty('--text-zoom', String(zoom)); view.requestMeasure(); }
  }
  function exportHTML() {
    return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Markdown document</title><style>body{max-width:760px;margin:60px auto;padding:0 30px;color:#303633;font:17px/1.8 Georgia,serif}h1,h2,h3{font-family:system-ui;line-height:1.3}pre,code{background:#f5f6f3;border-radius:4px}pre{padding:20px;overflow:auto}code{font:13px/1.7 monospace}blockquote{border-left:3px solid #a0b39a;margin-left:0;padding-left:20px;color:#777}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:8px}img{max-width:100%}a{color:#537460}.task-list-item{list-style:none}</style></head><body>' + MarginMarkdown.renderDocument(raw) + '</body></html>';
  }
  // Printing shows the rendered document, not the editor with its markers.
  function preparePrint() { $('#print-view').innerHTML = MarginMarkdown.renderDocument(raw); }
  function command(name, value) {
    if (name === 'source' && comparing) toast('Finish or cancel the comparison to leave source mode.');
    else if (name === 'source') toggleSource();
    else if (name === 'sidebar') document.body.classList.toggle('sidebar-open', Boolean(value?.open));
    else if (name === 'reveal') revealPosition(Number(value), 'start');
    else if (name === 'find') showFind();
    else if (name === 'replace') showFind(true);
    else if (name === 'goToLine') showGoToLine();
    else if (name === 'textZoom') setTextZoom(Number(value));
    else if (name === 'titlebar') setTitlebar(value ?? {});
    else if (name === 'typewriter') setTypewriter();
    else if (name === 'exportHTML') post('exportHTML', { html: exportHTML() });
    else if (name === 'print') post('print');
    else if (name === 'metadata') updateMetadata(value);
    else if (name === 'format') format(value);
    else if (name === 'diskChanged') setDiskText(value);
    else if (name === 'toast') toast(value);
    else if (name === 'pastePlain' && typeof value === 'string') pastePlain(value);
  }
  document.addEventListener('click', event => {
    const actionButton = event.target.closest('[data-action]');
    if (actionButton) command(actionButton.dataset.action);
    const formatButton = event.target.closest('[data-format]'); if (formatButton) format(formatButton.dataset.format);
    if (!event.target.closest('.popover,#format-button,#more-button')) closeMenus();
  });
  // App shortcuts run before the editor's own key handling. Undo belongs to the
  // native document, so inside the document the undo keys go there.
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') { closeMenus(); $('#find-bar').hidden = true; $('#goto-bar').hidden = true; }
    if (!(event.metaKey || event.ctrlKey) || event.altKey) return;
    const key = event.key.toLowerCase();
    const inDocument = view.contentDOM.contains(event.target);
    let handled = true;
    if (inDocument && native && (key === 'z' || (key === 'y' && !event.shiftKey))) post(key === 'y' || event.shiftKey ? 'redo' : 'undo');
    else if (inDocument && key === 'b' && !event.shiftKey) format('bold');
    else if (inDocument && key === 'i' && !event.shiftKey) format('italic');
    else if (inDocument && key === 'k' && !event.shiftKey) format('link');
    else if (key === '/') command('source');
    else if (key === 'f' && !event.shiftKey) command('find');
    else if (key === 'l' && !event.shiftKey) command('goToLine');
    else if (key === 'l' && event.shiftKey) post('toggleSidebar');
    else if (/^[1-6]$/.test(key)) format(`h${key}`);
    else if (key === 's') post(event.shiftKey ? 'saveAs' : 'save');
    else if (key === 'o') post(event.shiftKey ? 'openFolder' : 'open');
    else if (key === 'n' && !event.shiftKey) post('new');
    else handled = false;
    if (handled) { event.preventDefault(); event.stopPropagation(); }
  }, true);
  $('#toggle-sidebar').onclick = () => post('toggleSidebar');
  $('#source-button').onclick = () => command('source');
  $('#format-button').onclick = () => openMenu('#format-menu', '#format-button');
  $('#more-button').onclick = () => openMenu('#view-menu', '#more-button');
  $('#typewriter-button').onclick = () => command('typewriter');
  $('#word-count').onclick = () => toast($('#word-count').title);
  $('#find-input').oninput = () => { activeMatch = -1; find(); };
  $('#find-input').onkeydown = event => { if (event.key === 'Enter') { event.preventDefault(); find(event.shiftKey ? -1 : 1); } };
  $('#find-regex').onclick = () => { $('#find-regex').setAttribute('aria-pressed', String(!useRegex())); activeMatch = -1; find(); $('#find-input').focus(); };
  $('#replace-input').onkeydown = event => { if (event.key === 'Enter') { event.preventDefault(); replaceOne(); } };
  $('#replace-one').onclick = replaceOne; $('#replace-all').onclick = replaceAll;
  $('#goto-input').onkeydown = event => { if (event.key === 'Enter') { event.preventDefault(); goToLine(); } };
  $('#goto-close').onclick = () => { $('#goto-bar').hidden = true; view.focus(); };
  $('#cursor-position').onclick = showGoToLine;
  $('#find-prev').onclick = () => find(-1); $('#find-next').onclick = () => find(1);
  $('#find-close').onclick = () => { $('#find-bar').hidden = true; view.focus(); };
  $('#disk-reload').onclick = () => post('diskReload');
  $('#disk-keep-mine').onclick = keepMine;
  $('#disk-compare').onclick = startComparison;
  $('#compare-use-disk').onclick = useDiskForAll;
  $('#compare-keep-mine').onclick = finishComparison;
  $('#compare-cancel').onclick = cancelComparison;
  const snapshot = () => ({ text: raw, token: documentToken, revision: editRevision });
  window.app = { load: loadDocument, command, getMarkdown: () => raw, snapshot, getHTML: () => MarginMarkdown.renderDocument(raw), headings, view, isSource: () => sourceMode, isComparing: () => Boolean(comparing), preparePrint, welcome };
  // Resolves local images through the restricted native asset handler, while keeping
  // the Markdown URLs themselves relative and portable.
  if (native) {
    const base = document.createElement('base'); base.href = 'markdown-asset://local/'; document.head.append(base);
  }
  refresh();
  if (native) post('ready');
})();
