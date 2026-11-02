/* Native bridge checks, run by tests/EditorTests.swift with tests/bridge.setup.js. */
(async () => {
  const results = [];
  const app = window.app;
  const messages = window.__messages;
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const test = async (name, fn) => { try { await fn(); results.push({ name, passed: true }); } catch (error) { results.push({ name, passed: false, error: error.message }); } };
  await test('Unavailable browser storage does not prevent native editor readiness', () => {
    assert(messages.some(message => message.action === 'ready'), 'No ready message after storage failure');
  });
  await test('Native loads are acknowledged and edits carry their load token and revision', () => {
    app.load({ text: '# Preserve this\r\n', token: 'first-load' });
    assert(messages.some(message => message.action === 'loaded' && message.token === 'first-load'), 'Load not acknowledged');
    app.view.dispatch({ changes: { from: 0, to: app.view.state.doc.length, insert: '# My unsaved work\n' } });
    const edit = messages.findLast(message => message.action === 'changed');
    assert(edit.text === '# My unsaved work\n' && edit.token === 'first-load' && edit.revision === 1, 'Edit cannot be associated with the correct load');
    const snapshot = app.snapshot();
    assert(snapshot.text === edit.text && snapshot.token === edit.token && snapshot.revision === edit.revision, 'Save snapshot missed current edits');
    const count = messages.length;
    app.load({ text: '# My unsaved work\n\nRestored by undo.\n', token: 'second-load' });
    assert(!messages.slice(count).some(message => message.action === 'changed'), 'Text from the app was reported back as an edit');
  });
  await test('Save completion keeps the dirty indicator when newer edits remain unsaved', () => {
    app.command('metadata', { name: 'Saved.md', path: '/notes/Saved.md', modified: true });
    assert(!document.querySelector('#modified-dot').hidden, 'Save incorrectly cleared newer unsaved edits');
  });
  await test('The outline goes to native when headings change, and native can reveal one', async () => {
    const wait = () => new Promise(resolve => setTimeout(resolve, 150));
    const outlines = () => messages.filter(message => message.action === 'outline');
    app.load({ text: '# One\n\nText\n\n## Two\n', token: 'outline-load' }); await wait();
    assert(JSON.stringify(outlines().at(-1)?.headings) === JSON.stringify([{ level: 1, text: 'One', pos: 0 }, { level: 2, text: 'Two', pos: 13 }]), 'Outline not sent: ' + JSON.stringify(outlines().at(-1)));
    const count = outlines().length;
    app.view.dispatch({ changes: { from: app.view.state.doc.length, insert: 'More text.\n' } }); await wait();
    assert(outlines().length === count, 'An edit that kept the headings sent the outline again');
    app.command('reveal', 13);
    assert(app.view.state.selection.main.head === 13, 'Reveal did not move the cursor to the heading');
  });
  await test('The toolbar sidebar toggle shows only while the sidebar is collapsed and asks native to toggle', () => {
    const toggle = document.querySelector('#toggle-sidebar');
    app.command('sidebar', { open: true });
    assert(getComputedStyle(toggle).display === 'none', 'Toolbar toggle shown beside an open sidebar');
    app.command('sidebar', { open: false });
    assert(getComputedStyle(toggle).display !== 'none', 'Toolbar toggle hidden while the sidebar is collapsed');
    toggle.click();
    assert(messages.at(-1).action === 'toggleSidebar', 'Toolbar toggle did not reach native');
  });
  await test('Right-click places the cursor on spacing, keeps words and selections, and tells native', () => {
    const view = app.view;
    app.load({ text: 'First line\n\nThird words here\n', token: 'menu-load' });
    const rightClick = pos => {
      const { left, top, bottom } = view.coordsAtPos(pos);
      view.contentDOM.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, button: 2, clientX: left + 1, clientY: (top + bottom) / 2 }));
    };
    const blank = view.state.doc.line(2).from;
    // WebKit selects the line break under the pointer before the menu event.
    view.dispatch({ selection: { anchor: blank, head: blank + 1 } });
    const count = messages.length;
    rightClick(blank);
    const { from, to } = view.state.selection.main;
    assert(from === blank && to === blank, `Right-click on a blank line left ${from}–${to} selected`);
    assert(messages.slice(count).some(message => message.action === 'contextMenu'), 'The right-click was not reported to native');
    const word = view.state.doc.line(3).from + 7;
    view.dispatch({ selection: { anchor: word - 1, head: word + 4 } });
    rightClick(word + 2);
    assert(view.state.selection.main.from === word - 1 && view.state.selection.main.to === word + 4, 'Right-click inside a selection changed it');
  });
  await test('Command-Shift-[ and ] ask native to switch files; plain Command-[ and ] change indentation', () => {
    app.load({ text: '    indented line\n', token: 'switch-load' });
    app.view.dispatch({ selection: { anchor: 6 } });
    // With Command held, WebKit reports Shift-[ as "[".
    const presses = [['[', 'BracketLeft'], [']', 'BracketRight']];
    for (const [key, code] of presses) {
      const action = code === 'BracketLeft' ? 'previousFile' : 'nextFile';
      for (const target of [app.view.contentDOM, document.body]) {
        const count = messages.length;
        const event = new KeyboardEvent('keydown', { key, code, shiftKey: true, metaKey: true, bubbles: true, cancelable: true });
        target.dispatchEvent(event);
        assert(event.defaultPrevented && messages.slice(count).some(message => message.action === action), `Command-Shift-${key} from ${target.className || target.nodeName} did not reach native`);
      }
    }
    const plain = key => app.view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key, code: key === '[' ? 'BracketLeft' : 'BracketRight', metaKey: true, bubbles: true, cancelable: true }));
    plain('['); assert(app.getMarkdown() === '  indented line\n', 'Command-[ did not outdent: ' + JSON.stringify(app.getMarkdown()));
    plain(']'); assert(app.getMarkdown() === '    indented line\n', 'Command-] did not indent: ' + JSON.stringify(app.getMarkdown()));
  });
  await test('Undo keys in the document go to native undo instead of the editor histories', () => {
    app.load({ text: '# Keep me\n', token: 'undo-load' });
    const key = (target, init) => {
      const event = new KeyboardEvent('keydown', { bubbles: true, cancelable: true, metaKey: true, ...init });
      target.dispatchEvent(event); return event;
    };
    const editable = app.view.contentDOM;
    for (const [init, action] of [[{ key: 'z' }, 'undo'], [{ key: 'z', shiftKey: true }, 'redo'], [{ key: 'y' }, 'redo']]) {
      const event = key(editable, init);
      assert(event.defaultPrevented && messages.at(-1).action === action, `${JSON.stringify(init)} did not reach native ${action}`);
    }
    assert(app.getMarkdown() === '# Keep me\n', 'The editor changed its own text on undo');
    app.command('source');
    const sourceEvent = key(editable, { key: 'z' });
    assert(sourceEvent.defaultPrevented && messages.at(-1).action === 'undo', 'Source mode undo did not reach native undo');
    app.command('source');
    const count = messages.length;
    const findEvent = key(document.querySelector('#find-input'), { key: 'z' });
    assert(!findEvent.defaultPrevented && messages.length === count, 'Undo in the find field was taken from the field');
  });
  await test('Shortcut scope and capture behavior stay consistent in document, find, and insert fields', () => {
    const field = selector => document.querySelector(selector);
    const dialog = field('#insert-dialog');
    for (const target of [app.view.contentDOM, field('#find-input'), field('#insert-url')]) {
      const inDocument = target === app.view.contentDOM;
      for (const key of ['z', 'b', 'i', 'k']) {
        app.load({ text: 'word\n', token: 'shortcut-scope' });
        app.view.dispatch({ selection: { anchor: 0, head: 4 } });
        let reachedTarget = false;
        const observe = () => { reachedTarget = true; };
        target.addEventListener('keydown', observe);
        const count = messages.length;
        const event = new KeyboardEvent('keydown', { key, metaKey: true, bubbles: true, cancelable: true });
        target.dispatchEvent(event);
        target.removeEventListener('keydown', observe);
        assert(event.defaultPrevented === inDocument && reachedTarget !== inDocument, `Capture/guard changed for ${key} in ${target.id || 'document'}`);
        if (!inDocument) assert(app.getMarkdown() === 'word\n' && messages.length === count && !dialog.open, 'Field shortcut edited document or posted native command');
        else if (key === 'z') assert(messages.at(-1).action === 'undo', 'Document undo not routed');
        else if (key === 'b') assert(app.getMarkdown() === '**word**\n', 'Document bold changed');
        else if (key === 'i') assert(app.getMarkdown() === '*word*\n', 'Document italic changed');
        else assert(dialog.open, 'Document link dialog missing');
        if (dialog.open) dialog.close('cancel');
      }
      app.load({ text: 'word\n', token: 'global-scope' });
      app.view.dispatch({ selection: { anchor: 0 } });
      const heading = new KeyboardEvent('keydown', { key: '2', metaKey: true, bubbles: true, cancelable: true });
      target.dispatchEvent(heading);
      assert(heading.defaultPrevented && app.getMarkdown() === '## word\n', 'Global heading scope changed');
      const count = messages.length;
      const save = new KeyboardEvent('keydown', { key: 's', metaKey: true, shiftKey: true, bubbles: true, cancelable: true });
      target.dispatchEvent(save);
      assert(save.defaultPrevented && messages.slice(count).filter(message => message.action === 'saveAs').length === 1, 'Global Save As scope/count changed');
      const modified = new KeyboardEvent('keydown', { key: 's', metaKey: true, altKey: true, bubbles: true, cancelable: true });
      const before = messages.length;
      target.dispatchEvent(modified);
      assert(!modified.defaultPrevented && messages.length === before, 'Option modifier bypass changed');
    }
  });
  await test('A color scheme change switches the theme without touching the document', () => {
    app.load({ text: '# Theme\n\nKeep this text.\n', token: 'theme-load' });
    const count = messages.length;
    window.__setColorScheme(true);
    assert(document.body.dataset.theme === 'dark', 'Dark scheme not applied');
    assert(app.getMarkdown() === '# Theme\n\nKeep this text.\n' && !messages.slice(count).some(message => message.action === 'changed'), 'Theme change touched the document');
    window.__setColorScheme(false);
    assert(document.body.dataset.theme === 'light', 'Light scheme not applied');
  });
  const $ = selector => document.querySelector(selector);
  const settle = (ms = 50) => new Promise(resolve => setTimeout(resolve, ms));
  const mine = '# Title\n\nFirst mine\n\nMiddle\n\nLast mine\n';
  const disk = '# Title\n\nFirst disk\n\nMiddle\n\nLast disk\n';
  await test('A disk change with unsaved edits offers Reload, Overwrite, and Save As', () => {
    app.load({ text: mine, token: 'disk-load' });
    const banner = $('#disk-banner');
    assert(banner.hidden, 'Banner shown without a disk change');
    app.command('diskChanged', disk);
    assert(!banner.hidden && app.getMarkdown() === mine, 'Banner not shown, or the disk text replaced the edits');
    $('#disk-reload').click();
    assert(messages.at(-1).action === 'diskReload' && !banner.hidden, 'Reload did not ask native, or hid the banner before native reloaded');
    $('#disk-keep-mine').click();
    assert(messages.at(-1).action === 'diskKeepMine' && !banner.hidden, 'Overwrite must wait for a successful native save');
    $('#disk-save-as').click();
    assert(messages.at(-1).action === 'diskSaveAs' && !banner.hidden && app.getMarkdown() === mine, 'Save As must preserve the conflict and edits until saved');
    app.command('diskChanged', disk);
    assert(!banner.hidden, 'A failed save hid the banner');
    app.command('diskChanged', null);
    assert(banner.hidden && app.getMarkdown() === mine, 'Resolving the change did not hide the banner');
  });
  await test('A notice sent with a reload shows and then hides itself', async () => {
    app.load({ text: disk, token: 'notice-load', notice: 'Reloaded from disk' });
    assert(!$('#toast').hidden && $('#toast').textContent === 'Reloaded from disk', 'Reload notice not shown');
    await settle(3200);
    assert($('#toast').hidden, 'Reload notice did not hide itself');
  });
  await test('JavaScript, dependency loading, and promise failures reach native error reporting', () => {
    window.dispatchEvent(new ErrorEvent('error', { message: 'A runtime failure' }));
    const script = document.createElement('script');
    document.body.append(script);
    script.dispatchEvent(new Event('error'));
    const rejection = new Event('unhandledrejection');
    Object.defineProperty(rejection, 'reason', { value: new Error('A promise failure') });
    window.dispatchEvent(rejection);
    for (const expected of ['A runtime failure', 'An editor component could not be loaded.', 'A promise failure']) {
      assert(messages.some(message => message.action === 'editorError' && message.message === expected), `Missing native error: ${expected}`);
    }
  });
  await test('Exported HTML is a standalone page with styled Mermaid diagrams', () => {
    app.load({ text: '# Diagram\n\n```mermaid\nflowchart LR\n  A[Start] --> B[Done]\n```\n', token: 'export-load' });
    app.command('exportHTML');
    const html = messages.findLast(message => message.action === 'exportHTML')?.html ?? '';
    const page = new DOMParser().parseFromString(html, 'text/html');
    const svg = page.querySelector('figure.mermaid-diagram > svg.pele');
    assert(svg && svg.textContent.includes('Start') && svg.textContent.includes('Done'), 'Export lacks the diagram: ' + html.slice(0, 300));
    assert(/--_bg:var\(--pele-bg,#fff\)/.test(svg.getAttribute('style') ?? ''), 'Exported diagram lost its fallback colors');
    assert(/\.pele\{--pele-fg:#303633/.test(page.querySelector('style')?.textContent ?? ''), 'Export stylesheet lacks the diagram palette');
    assert(!page.querySelector('script, link[rel=stylesheet]'), 'Export depends on outside files');
  });
  return results;
})();
