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
  await test("Open files list this window's tabs and ask native to switch or close them", () => {
    assert(document.querySelector('#open-files-section').hidden, 'Open files shown before native sent any');
    app.command('openFiles', [
      { id: 'one', name: 'Current.md', path: '/notes/Current.md', modified: false, current: true },
      { id: 'two', name: 'Other.md', path: '/notes/Other.md', modified: true, current: false },
    ]);
    const rows = [...document.querySelectorAll('#open-files .open-file')];
    assert(!document.querySelector('#open-files-section').hidden && rows.length === 2, 'Open files not listed');
    assert(rows[0].classList.contains('active') && !rows[1].classList.contains('active'), 'Current tab not highlighted');
    assert(!rows[0].querySelector('.open-file-modified') && rows[1].querySelector('.open-file-modified'), 'Unsaved marker wrong');
    rows[1].querySelector('.open-file-name').click();
    assert(messages.at(-1).action === 'selectOpenFile' && messages.at(-1).id === 'two', 'Selecting a file did not reach native');
    rows[1].querySelector('.open-file-close').click();
    assert(messages.at(-1).action === 'closeOpenFile' && messages.at(-1).id === 'two', 'Closing a file did not reach native');
    app.command('openFiles', []);
    assert(document.querySelector('#open-files-section').hidden, 'Empty open files list still shown');
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
