import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const { Window } = await import(process.env.HAPPY_DOM_MODULE ? pathToFileURL(process.env.HAPPY_DOM_MODULE).href : 'happy-dom');
const root = path.resolve(import.meta.dirname, '..');
const window = new Window({ url: 'http://localhost/' });
const errors = [];
window.addEventListener('error', event => errors.push(event.message));
window.document.write(fs.readFileSync(path.join(root, 'web/index.html'), 'utf8').replace(/<script[^>]*src="[^"]+"[^>]*><\/script>/g, ''));
window.eval(fs.readFileSync(path.join(root, 'web/src/diagnostics.js'), 'utf8'));
window.eval(fs.readFileSync(path.join(root, 'web/vendor/toastui-editor-all.min.js'), 'utf8'));
window.eval(fs.readFileSync(path.join(root, 'web/vendor/purify.min.js'), 'utf8'));
window.eval(fs.readFileSync(path.join(root, 'web/src/app.js'), 'utf8'));
try {
  const results = await window.eval(fs.readFileSync(path.join(root, 'tests/editor.test.js'), 'utf8'));
  for (const result of results) console.log(`${result.passed ? 'PASS' : 'FAIL'} ${result.name}${result.error ? `: ${result.error}` : ''}`);
  if (errors.length) { console.error(errors); process.exitCode = 1; }
  if (!results.length || results.some(result => !result.passed)) process.exitCode = 1;
} finally { await window.happyDOM.close(); }

const nativeWindow = new Window({ url: 'http://localhost/' });
const messages = [];
nativeWindow.webkit = { messageHandlers: { native: { postMessage: message => messages.push(message) } } };
Object.defineProperty(nativeWindow, 'localStorage', { value: {
  getItem() { throw new Error('Storage unavailable'); },
  setItem() { throw new Error('Storage unavailable'); },
} });
try {
  nativeWindow.document.write(fs.readFileSync(path.join(root, 'web/index.html'), 'utf8').replace(/<script[^>]*src="[^"]+"[^>]*><\/script>/g, ''));
  for (const file of ['web/src/diagnostics.js', 'web/vendor/toastui-editor-all.min.js', 'web/vendor/purify.min.js', 'web/src/app.js']) {
    nativeWindow.eval(fs.readFileSync(path.join(root, file), 'utf8'));
  }
  const test = (name, block) => {
    try { block(); console.log(`PASS ${name}`); }
    catch (error) { console.error(`FAIL ${name}: ${error.message}`); process.exitCode = 1; }
  };
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  test('Unavailable browser storage does not prevent native editor readiness', () => {
    assert(messages.some(message => message.action === 'ready'), 'No ready message after storage failure');
  });
  test('Native loads are acknowledged and edits carry their load token and revision', () => {
    nativeWindow.app.load({ text: '# Preserve this\r\n', token: 'first-load' });
    assert(messages.some(message => message.action === 'loaded' && message.token === 'first-load'), 'Load not acknowledged');
    nativeWindow.app.command('source');
    const source = nativeWindow.document.querySelector('#source-editor');
    source.value = '# My unsaved work\n';
    source.dispatchEvent(new nativeWindow.Event('input', { bubbles: true }));
    const edit = messages.findLast(message => message.action === 'changed');
    assert(edit.text === source.value && edit.token === 'first-load' && edit.revision === 1, 'Edit cannot be associated with the correct load');
    const snapshot = nativeWindow.app.snapshot();
    assert(snapshot.text === source.value && snapshot.token === edit.token && snapshot.revision === edit.revision, 'Save snapshot missed current edits');
  });
  test('Save completion keeps the dirty indicator when newer edits remain unsaved', () => {
    nativeWindow.app.command('metadata', { name: 'Saved.md', path: '/notes/Saved.md', modified: true });
    assert(!nativeWindow.document.querySelector('#modified-dot').hidden, 'Save incorrectly cleared newer unsaved edits');
  });
  test('Failed rich text serialization blocks stale save snapshots and unsafe source switching', () => {
    nativeWindow.app.command('source');
    const editor = nativeWindow.app.editor;
    const getMarkdown = editor.getMarkdown;
    try {
      editor.getMarkdown = () => { throw new Error('Cannot serialize this edit'); };
      editor.moveCursorToEnd(); editor.insertText(' A newer edit.');
      assert(messages.some(message => message.action === 'editorSerializationError'), 'Serialization failure was silent');
      let blocked = false;
      try { nativeWindow.app.snapshot(); } catch { blocked = true; }
      assert(blocked, 'Save returned stale text after serialization failed');
      nativeWindow.app.command('source');
      assert(!nativeWindow.app.isSource(), 'Source switching discarded unread rich text');
    } finally { editor.getMarkdown = getMarkdown; }
    assert(nativeWindow.app.snapshot().text.includes('A newer edit.'), 'Retry did not read the previously unconverted edit');
  });
  test('Open files list this window\'s tabs and ask native to switch or close them', () => {
    const doc = nativeWindow.document;
    assert(doc.querySelector('#open-files-section').hidden, 'Open files shown before native sent any');
    nativeWindow.app.command('openFiles', [
      { id: 'one', name: 'Current.md', path: '/notes/Current.md', modified: false, current: true },
      { id: 'two', name: 'Other.md', path: '/notes/Other.md', modified: true, current: false },
    ]);
    const rows = [...doc.querySelectorAll('#open-files .open-file')];
    assert(!doc.querySelector('#open-files-section').hidden && rows.length === 2, 'Open files not listed');
    assert(rows[0].classList.contains('active') && !rows[1].classList.contains('active'), 'Current tab not highlighted');
    assert(!rows[0].querySelector('.open-file-modified') && rows[1].querySelector('.open-file-modified'), 'Unsaved marker wrong');
    rows[1].querySelector('.open-file-name').click();
    assert(messages.at(-1).action === 'selectOpenFile' && messages.at(-1).id === 'two', 'Selecting a file did not reach native');
    rows[1].querySelector('.open-file-close').click();
    assert(messages.at(-1).action === 'closeOpenFile' && messages.at(-1).id === 'two', 'Closing a file did not reach native');
    nativeWindow.app.command('openFiles', []);
    assert(doc.querySelector('#open-files-section').hidden, 'Empty open files list still shown');
  });
  test('JavaScript, dependency loading, and promise failures reach native error reporting', () => {
    nativeWindow.dispatchEvent(new nativeWindow.ErrorEvent('error', { message: 'A runtime failure' }));
    const script = nativeWindow.document.createElement('script');
    nativeWindow.document.body.append(script);
    script.dispatchEvent(new nativeWindow.Event('error'));
    const rejection = new nativeWindow.Event('unhandledrejection');
    Object.defineProperty(rejection, 'reason', { value: new Error('A promise failure') });
    nativeWindow.dispatchEvent(rejection);
    for (const expected of ['A runtime failure', 'An editor component could not be loaded.', 'A promise failure']) {
      assert(messages.some(message => message.action === 'editorError' && message.message === expected), `Missing native error: ${expected}`);
    }
  });
} finally { await nativeWindow.happyDOM.close(); }
