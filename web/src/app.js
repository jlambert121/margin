/* Native bridge and presentation layer. All editor dependencies are bundled locally. */
(() => {
  'use strict';
  const $ = (selector) => document.querySelector(selector);
  const native = Boolean(window.webkit?.messageHandlers?.native);
  const post = (action, payload = {}) => {
    if (native) window.webkit.messageHandlers.native.postMessage({ action, ...payload });
    else if (action === 'changed') sessionStorage.setItem('margin-draft', payload.text);
    else if (action === 'openExternal') window.open(payload.url, '_blank', 'noopener');
    else if (action === 'editorSerializationError') toast('The latest edit could not be converted to Markdown. Copy your text before closing.');
    else toast('Open the macOS app to use native file operations.');
  };
  const welcome = '# A little room to think.\n\nWelcome to **Margin**. A quiet place for your notes, ideas, and everything in between.\n\n## Just start writing\n\nYour words take shape as you type. Use Markdown shortcuts for headings, **bold**, *italics*, and lists — the formatting appears right here on the page.\n\n> The secret of getting ahead is getting started.\n\n## Make yourself at home\n\n- Open a Markdown file with **⌘O**\n- Browse a folder with **⇧⌘O**\n- Switch to source mode with **⌘/**\n- Save your work with **⌘S**\n\n### A few things to try\n\n- [x] Find a little space to write\n- [ ] Put an idea into words\n- [ ] Make something worth keeping\n\n## For the details\n\nCode, tables, links, and images all have a place here.\n\n```swift\nlet thought = "Something worth writing down."\nprint(thought)\n```\n\n| Shortcut | A small superpower |\n| --- | --- |\n| ⌘B | A little emphasis |\n| ⌘F | Find the right words |\n| ⇧⌘F | Focus on the present paragraph |\n\n---\n\nTake your time. The page is yours.\n';
  let raw = native ? '' : sessionStorage.getItem('margin-draft') ?? welcome;
  let programmatic = false;
  let sourceMode = false;
  let currentPath = '';
  let documentToken = null;
  let editRevision = 0;
  let needsSerialization = false;
  let folder = null;
  let toastTimer;
  let refreshTimer;
  let activeMatch = -1;
  let matches = [];
  let insertKind = 'link';
  const editor = new toastui.Editor({
    el: $('#editor'), height: '100%', initialEditType: 'wysiwyg', initialValue: raw,
    hideModeSwitch: true, usageStatistics: false, toolbarItems: [], autofocus: false,
    customHTMLSanitizer: html => DOMPurify.sanitize(html),
    placeholder: 'Begin anywhere…',
    hooks: { addImageBlobHook(blob, callback) {
      const reader = new FileReader();
      reader.onload = () => callback(reader.result, blob.name || 'Image');
      reader.readAsDataURL(blob);
      return false;
    } },
  });
  const source = document.createElement('textarea');
  source.id = 'source-editor';
  source.setAttribute('aria-label', 'Markdown source');
  source.spellcheck = false;
  source.hidden = true;
  $('#editor').after(source);
  const sourceStyle = document.createElement('style');
  sourceStyle.textContent = '#source-editor{flex:1;min-height:0;resize:none;border:0;outline:0;display:block;width:100%;background:var(--paper);color:var(--text);font:14px/1.85 ui-monospace,SFMono-Regular,Menlo,monospace;padding:48px max(40px,calc((100% - 680px)/2)) 35vh;tab-size:2;white-space:pre-wrap}';
  document.head.append(sourceStyle);
  const editable = $('.toastui-editor-ww-container .ProseMirror');
  editable.setAttribute('aria-label', 'Markdown document');
  editable.setAttribute('role', 'textbox');
  editable.setAttribute('aria-multiline', 'true');

  function toast(message) {
    clearTimeout(toastTimer);
    $('#toast').textContent = message;
    $('#toast').hidden = false;
    toastTimer = setTimeout(() => $('#toast').hidden = true, 3000);
  }
  function changed(text, force = false) {
    if (text === raw && !force) return;
    raw = text;
    post('changed', { text: raw, token: documentToken, revision: ++editRevision });
    $('#modified-dot').hidden = false;
    $('#save-status').textContent = 'Edited';
    refresh();
  }
  editor.on('change', () => {
    if (!programmatic && !sourceMode) {
      const retry = needsSerialization;
      needsSerialization = true;
      try {
        const next = editor.getMarkdown();
        needsSerialization = false;
        changed(next, retry);
      } catch { post('editorSerializationError', { token: documentToken }); }
    }
  });
  source.addEventListener('input', () => changed(source.value));
  source.addEventListener('keydown', event => {
    if (event.key === 'Tab') {
      event.preventDefault();
      source.setRangeText('  ', source.selectionStart, source.selectionEnd, 'end');
      changed(source.value);
    }
  });
  function setRich(text) {
    programmatic = true;
    try { editor.setMarkdown(text, false); }
    finally { programmatic = false; }
  }
  function refresh() {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => {
      const plain = sourceMode ? raw : editor.getHTML().replace(/<[^>]*>/g, ' ').replace(/&[^;]+;/g, ' ');
      const words = plain.trim().split(/\s+/u).filter(Boolean).length;
      $('#word-count').textContent = `${words.toLocaleString()} ${words === 1 ? 'word' : 'words'}`;
      $('#word-count').title = `${raw.length.toLocaleString()} characters · ${raw.split('\n').length.toLocaleString()} lines`;
      $('#reading-time').textContent = `${Math.max(1, Math.ceil(words / 225))} min read`;
      renderOutline();
    }, 80);
  }
  function loadDocument(data) {
    raw = data.text;
    currentPath = data.path || '';
    source.value = raw;
    setRich(raw);
    needsSerialization = false;
    $('#document-name').textContent = data.name || 'Untitled.md';
    $('#document-name').title = currentPath || 'Untitled document';
    $('#modified-dot').hidden = !data.modified;
    $('#save-status').textContent = data.modified ? 'Edited' : currentPath ? 'Saved locally' : 'Ready to write';
    if (data.folder) { folder = data.folder; renderFiles(); }
    else if (folder) renderFiles();
    refresh();
    documentToken = data.token ?? null;
    editRevision = 0;
    if (native) post('loaded', { token: documentToken });
  }
  function updateMetadata(data) {
    currentPath = data.path || '';
    $('#document-name').textContent = data.name || 'Untitled.md';
    $('#document-name').title = currentPath || 'Untitled document';
    $('#modified-dot').hidden = !data.modified;
    $('#save-status').textContent = data.modified ? 'Edited' : 'Saved locally';
    renderFiles();
  }
  function toggleSource(force) {
    const next = typeof force === 'boolean' ? force : !sourceMode;
    if (next === sourceMode) return;
    if (next && needsSerialization) {
      try { snapshot(); }
      catch { toast('The latest edit could not be read. Copy your text before switching modes.'); return; }
    }
    if (next) source.value = raw;
    else setRich(raw);
    sourceMode = next;
    source.hidden = !sourceMode;
    $('#editor').hidden = sourceMode;
    $('#source-button').setAttribute('aria-pressed', String(sourceMode));
    $('#mode-label').textContent = sourceMode ? 'MARKDOWN SOURCE' : 'LIVE PREVIEW';
    $('#format-button').disabled = sourceMode;
    closeMenus();
    sourceMode ? source.focus() : editor.focus();
    refresh();
  }
  function renderOutline() {
    const nav = $('#outline');
    nav.replaceChildren();
    let headings;
    if (sourceMode) {
      let fenced = false;
      let fence = '';
      let offset = 0;
      headings = [];
      for (const line of raw.split('\n')) {
        const marker = line.match(/^\s*(`{3,}|~{3,})/);
        if (marker) {
          if (!fenced) { fenced = true; fence = marker[1][0]; }
          else if (marker[1][0] === fence) fenced = false;
        }
        const match = !fenced && line.match(/^(#{1,6})\s+(.+?)\s*#*$/);
        if (match) headings.push({ level: match[1].length, text: match[2], offset });
        offset += line.length + 1;
      }
    } else headings = [...editable.querySelectorAll('h1,h2,h3,h4,h5,h6')].map(el => ({ level: +el.tagName[1], text: el.textContent, el }));
    if (!headings.length) {
      const empty = document.createElement('div'); empty.className = 'empty'; empty.textContent = 'Add a heading to give your words a little structure.'; nav.append(empty);
    }
    headings.forEach(h => {
      const button = document.createElement('button');
      button.textContent = h.text; button.title = h.text;
      button.style.paddingLeft = `${12 + (h.level - 1) * 12}px`;
      button.onclick = () => {
        if (h.el) h.el.scrollIntoView({ behavior: 'smooth', block: 'start' });
        else { source.focus(); source.setSelectionRange(h.offset, h.offset + h.text.length + h.level + 1); source.scrollTop = (raw.slice(0, h.offset).split('\n').length - 1) * 26; }
      };
      nav.append(button);
    });
  }
  function showTab(which) {
    for (const tab of ['files', 'outline']) {
      $(`#${tab}-tab`).setAttribute('aria-selected', String(which === tab));
      $(`#${tab}-panel`).hidden = which !== tab;
    }
  }
  function renderFiles() {
    const tree = $('#file-tree'); tree.replaceChildren();
    $('#empty-workspace').hidden = Boolean(folder);
    $('#file-filter').hidden = !folder;
    $('#refresh-folder').hidden = !folder;
    $('#folder-name').textContent = folder?.name?.toUpperCase() || 'WORKSPACE';
    if (!folder) return;
    const query = $('#file-filter').value.toLowerCase();
    function add(entries, parent, depth = 0) {
      let count = 0;
      for (const entry of entries) {
        if (entry.children) {
          const details = document.createElement('details'); details.className = 'tree-folder'; details.open = Boolean(query) || depth === 0;
          const summary = document.createElement('summary'); summary.textContent = entry.name; details.append(summary);
          const children = document.createElement('div'); children.style.paddingLeft = '12px';
          if (add(entry.children, children, depth + 1)) { details.append(children); parent.append(details); count++; }
        } else if (!query || entry.name.toLowerCase().includes(query)) {
          const button = document.createElement('button'); button.className = `file-row${entry.path === currentPath ? ' active' : ''}`;
          const icon = document.createElement('span'); icon.className = 'file-icon'; icon.textContent = '≡';
          const name = document.createElement('span'); name.textContent = entry.name;
          button.append(icon, name); button.title = entry.path;
          button.onclick = () => post('openPath', { path: entry.path }); parent.append(button); count++;
        }
      }
      return count;
    }
    if (!add(folder.children, tree)) { const empty = document.createElement('p'); empty.className = 'empty'; empty.textContent = query ? 'No matching files.' : 'No Markdown files in this folder.'; tree.append(empty); }
  }
  function toggleFocus() {
    const on = document.body.classList.toggle('focus-mode');
    $('#focus-button').setAttribute('aria-pressed', String(on));
    highlightBlock();
  }
  function highlightBlock() {
    editable.querySelectorAll('.active-block').forEach(el => el.classList.remove('active-block'));
    let node = window.getSelection()?.anchorNode;
    if (node?.nodeType === Node.TEXT_NODE) node = node.parentElement;
    if (!node || !editable.contains(node)) node = editable.firstElementChild;
    while (node && node.parentElement !== editable) node = node.parentElement;
    node?.classList.add('active-block');
    if (document.body.classList.contains('typewriter') && editable.contains(document.activeElement)) node?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }
  document.addEventListener('selectionchange', highlightBlock);
  function closeMenus() {
    $('#format-menu').hidden = true; $('#view-menu').hidden = true;
    $('#format-button').setAttribute('aria-expanded', 'false'); $('#more-button').setAttribute('aria-expanded', 'false');
  }
  function openMenu(id, trigger) {
    const wasHidden = $(id).hidden; closeMenus(); $(id).hidden = !wasHidden; $(trigger).setAttribute('aria-expanded', String(wasHidden));
  }
  const systemAppearance = window.matchMedia('(prefers-color-scheme: dark)');
  let selectedTheme = 'auto';
  function applyTheme() {
    const dark = selectedTheme === 'dark' || (selectedTheme === 'auto' && systemAppearance.matches);
    document.body.dataset.theme = dark ? 'dark' : 'light';
    $('.toastui-editor-defaultUI').classList.toggle('toastui-editor-dark', dark);
  }
  systemAppearance.addEventListener('change', applyTheme);
  // The native app owns the appearance setting and sends it after each load.
  function theme(name) {
    selectedTheme = ['light', 'dark', 'auto'].includes(name) ? name : 'auto';
    applyTheme();
  }
  function insertDialog(kind) {
    insertKind = kind;
    $('#insert-title').textContent = kind === 'image' ? 'Insert image' : 'Insert link';
    $('#insert-url').value = ''; $('#insert-description').value = editor.getSelectedText() || '';
    $('#insert-dialog').showModal(); $('#insert-url').focus();
  }
  $('#insert-dialog').addEventListener('close', () => {
    if ($('#insert-dialog').returnValue !== 'insert') return;
    const url = $('#insert-url').value.trim(); const description = $('#insert-description').value.trim();
    if (!url || /^(javascript|vbscript|file):/i.test(url) || (insertKind === 'link' && /^data:/i.test(url))) { toast('Please use a web address or a relative file path.'); return; }
    editor.focus();
    editor.exec(insertKind === 'image' ? 'addImage' : 'addLink', insertKind === 'image' ? { imageUrl: url, altText: description } : { linkUrl: url, linkText: description || url });
  });
  function format(kind) {
    if (sourceMode) { toast('Switch to live preview to use formatting commands.'); return; }
    closeMenus();
    if (kind === 'link' || kind === 'image') { insertDialog(kind); return; }
    editor.focus();
    if (/^h[1-6]$/.test(kind)) editor.exec('heading', { level: +kind[1] });
    else if (kind === 'paragraph') editor.exec('heading', { level: 0 });
    else if (kind === 'table') editor.exec('addTable', { rowCount: 3, columnCount: 3 });
    else editor.exec(kind);
  }
  function find(direction = 1) {
    const query = $('#find-input').value.toLocaleLowerCase();
    matches = [];
    if (!query) { $('#find-result').textContent = ''; return; }
    if (sourceMode) {
      const text = raw.toLocaleLowerCase();
      let index = text.indexOf(query);
      while (index !== -1) { matches.push({ index }); index = text.indexOf(query, index + Math.max(query.length, 1)); }
    } else {
      const walker = document.createTreeWalker(editable, NodeFilter.SHOW_TEXT);
      let node; while ((node = walker.nextNode())) {
        const text = node.textContent.toLocaleLowerCase();
        let index = text.indexOf(query);
        while (index !== -1) { matches.push({ node, index }); index = text.indexOf(query, index + Math.max(query.length, 1)); }
      }
    }
    if (!matches.length) { $('#find-result').textContent = 'No matches'; return; }
    activeMatch = (activeMatch + direction + matches.length) % matches.length;
    const match = matches[activeMatch];
    if (sourceMode) { source.setSelectionRange(match.index, match.index + query.length); source.scrollTop = raw.slice(0, match.index).split('\n').length * 26 - source.clientHeight / 2; }
    else { const range = document.createRange(); range.setStart(match.node, match.index); range.setEnd(match.node, match.index + query.length); const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range); match.node.parentElement.scrollIntoView({ block: 'center', behavior: 'smooth' }); }
    $('#find-result').textContent = `${activeMatch + 1} of ${matches.length}`;
  }
  function showFind() { $('#find-bar').hidden = false; $('#find-input').focus(); $('#find-input').select(); }
  function command(name, value) {
    if (name === 'source') toggleSource();
    else if (name === 'sidebar') document.body.classList.toggle('no-sidebar');
    else if (name === 'outline') { document.body.classList.remove('no-sidebar'); showTab('outline'); }
    else if (name === 'focus') toggleFocus();
    else if (name === 'find') showFind();
    else if (name === 'theme') theme(value);
    else if (name === 'typewriter') { const on = document.body.classList.toggle('typewriter'); $('#typewriter-check').textContent = on ? '✓' : ''; closeMenus(); }
    else if (name === 'exportHTML') {
      if (sourceMode) setRich(raw);
      post('exportHTML', { html: '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Markdown document</title><style>body{max-width:760px;margin:60px auto;padding:0 30px;color:#303633;font:17px/1.8 Georgia,serif}h1,h2,h3{font-family:system-ui;line-height:1.3}pre,code{background:#f5f6f3;border-radius:4px}pre{padding:20px;overflow:auto}code{font:13px/1.7 monospace}blockquote{border-left:3px solid #a0b39a;margin-left:0;padding-left:20px;color:#777}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:8px}img{max-width:100%}a{color:#537460}</style></head><body>' + editor.getHTML() + '</body></html>' });
    } else if (name === 'print') { if (sourceMode) toggleSource(false); post('print'); }
    else if (name === 'metadata') updateMetadata(value);
    else if (name === 'saved') { $('#modified-dot').hidden = true; $('#save-status').textContent = 'Saved locally'; }
    else if (name === 'folder') { folder = value; renderFiles(); }
    else if (name === 'format') format(value);
  }
  document.addEventListener('click', event => {
    const actionButton = event.target.closest('[data-action]');
    if (actionButton) {
      const action = actionButton.dataset.action;
      if (['exportHTML', 'print'].includes(action)) command(action); else post(action);
    }
    const formatButton = event.target.closest('[data-format]'); if (formatButton) format(formatButton.dataset.format);
    if (!event.target.closest('.popover,#format-button,#more-button')) closeMenus();
    const link = event.target.closest('.toastui-editor-contents a');
    if (link) {
      event.preventDefault();
      if (event.metaKey || event.ctrlKey) {
        const href = link.getAttribute('href');
        if (href?.startsWith('#')) { const heading = [...editable.querySelectorAll('h1,h2,h3,h4,h5,h6')].find(h => h.textContent.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-') === href.slice(1)); heading?.scrollIntoView({ block: 'start', behavior: 'smooth' }); }
        else post('openExternal', { url: href });
      }
    }
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') { closeMenus(); $('#find-bar').hidden = true; }
    if (!(event.metaKey || event.ctrlKey)) return;
    const key = event.key.toLowerCase();
    if (key === '/') { event.preventDefault(); command('source'); }
    else if (key === 'f') { event.preventDefault(); command(event.shiftKey ? 'focus' : 'find'); }
    else if (key === 'l' && event.shiftKey) { event.preventDefault(); command('sidebar'); }
    else if (/^[0-6]$/.test(key)) { event.preventDefault(); format(key === '0' ? 'paragraph' : `h${key}`); }
    else if (key === 's') { event.preventDefault(); post(event.shiftKey ? 'saveAs' : 'save'); }
    else if (key === 'o') { event.preventDefault(); post(event.shiftKey ? 'openFolder' : 'open'); }
    else if (key === 'n') { event.preventDefault(); post('new'); }
  });
  $('#toggle-sidebar').onclick = () => command('sidebar');
  $('#source-button').onclick = () => command('source');
  $('#focus-button').onclick = () => command('focus');
  $('#format-button').onclick = () => openMenu('#format-menu', '#format-button');
  $('#more-button').onclick = () => openMenu('#view-menu', '#more-button');
  $('#files-tab').onclick = () => showTab('files'); $('#outline-tab').onclick = () => showTab('outline');
  $('#file-filter').oninput = renderFiles;
  $('#refresh-folder').onclick = () => post('refreshFolder');
  $('#typewriter-button').onclick = () => command('typewriter');
  $('#word-count').onclick = () => toast($('#word-count').title);
  $('#find-input').oninput = () => { activeMatch = -1; find(); };
  $('#find-input').onkeydown = event => { if (event.key === 'Enter') { event.preventDefault(); find(event.shiftKey ? -1 : 1); } };
  $('#find-prev').onclick = () => find(-1); $('#find-next').onclick = () => find(1);
  $('#find-close').onclick = () => { $('#find-bar').hidden = true; sourceMode ? source.focus() : editor.focus(); };
  function snapshot() {
    if (needsSerialization) {
      const next = editor.getMarkdown();
      needsSerialization = false;
      changed(next, true);
    }
    return { text: raw, token: documentToken, revision: editRevision };
  }
  window.app = { load: loadDocument, command, getMarkdown: () => raw, snapshot, getHTML: () => editor.getHTML(), editor, isSource: () => sourceMode, welcome };
  // Resolves local images through the restricted native asset handler, while keeping
  // the Markdown URLs themselves relative and portable.
  if (native) {
    const base = document.createElement('base'); base.href = 'markdown-asset://local/'; document.head.append(base);
  }
  applyTheme();
  renderFiles(); refresh();
  if (native) post('ready');
})();
