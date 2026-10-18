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
  const $$ = selector => [...document.querySelectorAll(selector)];
  const settle = (ms = 50) => new Promise(resolve => setTimeout(resolve, ms));
  const mousedown = target => target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
  const mine = '# Title\n\nFirst mine\n\nMiddle\n\nLast mine\n';
  const disk = '# Title\n\nFirst disk\n\nMiddle\n\nLast disk\n';
  await test('A disk change with unsaved edits offers Reload, Keep mine, and Compare', () => {
    app.load({ text: mine, token: 'disk-load' });
    const banner = $('#disk-banner');
    assert(banner.hidden, 'Banner shown without a disk change');
    app.command('diskChanged', disk);
    assert(!banner.hidden && app.getMarkdown() === mine, 'Banner not shown, or the disk text replaced the edits');
    $('#disk-reload').click();
    assert(messages.at(-1).action === 'diskReload' && !banner.hidden, 'Reload did not ask native, or hid the banner before native reloaded');
    $('#disk-keep-mine').click();
    assert(messages.at(-1).action === 'diskKeepMine' && banner.hidden, 'Keep mine did not ask native to save');
    app.command('diskChanged', disk);
    assert(!banner.hidden, 'A failed save did not bring the banner back');
    app.command('diskChanged', null);
    assert(banner.hidden && app.getMarkdown() === mine, 'Resolving the change did not hide the banner');
  });
  await test('Compare shows disk changes inline, and resolving the last one saves', async () => {
    app.load({ text: mine, token: 'compare-load' });
    app.command('diskChanged', disk);
    $('#disk-compare').click(); await settle();
    assert(app.isComparing() && app.isSource(), 'Compare did not start in source mode');
    assert($('#disk-banner').hidden && !$('#compare-bar').hidden, 'Compare bar not shown in place of the banner');
    const chunks = $$('.cm-deletedChunk');
    assert(chunks.length === 2 && chunks[0].textContent.includes('First disk') && chunks[1].textContent.includes('Last disk'), 'Disk versions not shown inline');
    const label = name => chunks[0].querySelector(`button[name=${name}]`)?.textContent;
    assert(label('accept') === 'Keep mine' && label('reject') === 'Use disk version', `Change buttons labeled ${label('accept')} and ${label('reject')}`);
    assert($('#compare-status').textContent.startsWith('2 changes differ'), 'Change count wrong: ' + $('#compare-status').textContent);
    const count = messages.length;
    mousedown(chunks[0].querySelector('button[name=reject]')); await settle();
    const taken = '# Title\n\nFirst disk\n\nMiddle\n\nLast mine\n';
    assert(app.getMarkdown() === taken, 'Use disk version did not take that change: ' + JSON.stringify(app.getMarkdown()));
    assert(messages.slice(count).some(message => message.action === 'changed' && message.text === taken), 'Taking a disk change was not reported as an edit');
    assert(app.isComparing() && $('#compare-status').textContent.startsWith('1 change differs'), 'Comparison ended early');
    app.command('source');
    assert(app.isSource() && app.isComparing(), 'Source mode turned off during a comparison');
    mousedown($('.cm-deletedChunk button[name=accept]')); await settle();
    assert(!app.isComparing() && !app.isSource() && $('#compare-bar').hidden && $('#disk-banner').hidden, 'Resolving the last change did not finish the comparison');
    // The outline for the sidebar can follow the save.
    const last = messages.filter(message => message.action !== 'outline').at(-1);
    assert(last.action === 'diskKeepMine' && app.getMarkdown() === taken, 'Finishing did not save the merged text: ' + last.action);
    app.command('diskChanged', null);
  });
  await test('Use disk version for all and Keep mine for all finish and save, and Cancel changes nothing', async () => {
    app.load({ text: mine, token: 'all-load' });
    app.command('diskChanged', disk);
    app.command('source');
    $('#disk-compare').click(); await settle();
    $('#compare-cancel').click(); await settle();
    assert(!app.isComparing() && app.isSource() && !$('#disk-banner').hidden && app.getMarkdown() === mine, 'Cancel changed the text, mode, or banner');
    app.command('source');
    $('#disk-compare').click(); await settle();
    let count = messages.length;
    $('#compare-use-disk').click(); await settle();
    const actions = messages.slice(count).map(message => message.action);
    assert(app.getMarkdown() === disk && actions.join() === 'changed,diskKeepMine', 'Use disk version for all: ' + actions.join());
    assert(!app.isComparing() && !app.isSource(), 'Use disk version for all did not finish');
    app.load({ text: mine, token: 'all-load-2' });
    app.command('diskChanged', disk);
    $('#disk-compare').click(); await settle();
    count = messages.length;
    $('#compare-keep-mine').click(); await settle();
    assert(app.getMarkdown() === mine && messages.slice(count).map(message => message.action).join() === 'diskKeepMine', 'Keep mine for all did not save the edits unchanged');
    assert(!app.isComparing(), 'Keep mine for all did not finish');
    app.command('diskChanged', null);
  });
  await test('A newer disk version updates an open comparison in place', async () => {
    app.load({ text: mine, token: 'newer-load' });
    app.command('diskChanged', disk);
    $('#disk-compare').click(); await settle();
    mousedown($('.cm-deletedChunk button[name=reject]')); await settle();
    const newer = '# Title\n\nFirst disk\n\nMiddle\n\nLast newer\n';
    app.command('diskChanged', newer); await settle();
    const chunks = $$('.cm-deletedChunk');
    assert(app.isComparing() && chunks.length === 1 && chunks[0].textContent.includes('Last newer'), 'Comparison not updated to the newer version');
    assert(app.getMarkdown() === '# Title\n\nFirst disk\n\nMiddle\n\nLast mine\n', 'A newer disk version changed the edits');
    assert($('#toast').textContent.includes('changed on disk again'), 'No notice of the newer version');
    app.command('diskChanged', null); await settle();
    assert(!app.isComparing() && !app.isSource() && $('#disk-banner').hidden, 'Resolving natively did not end the comparison');
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
  return results;
})();
