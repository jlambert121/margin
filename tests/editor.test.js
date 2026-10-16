(async () => {
  const results = [];
  const app = window.app;
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const test = async (name, fn) => { try { await fn(); results.push({ name, passed: true }); } catch (error) { results.push({ name, passed: false, error: error.message }); } };
  const tick = () => new Promise(resolve => setTimeout(resolve, 150));
  const pageErrors = [];
  window.addEventListener('error', event => pageErrors.push(event.message));
  window.addEventListener('unhandledrejection', event => pageErrors.push(String(event.reason?.message ?? event.reason)));
  const fixture = '# A real document\n\nA paragraph with **bold**, *emphasis*, and [a link](https://example.com).\n\n## Next steps\n\n- [x] Finished\n- [ ] Pending\n\n```swift\nlet value = 42\n```\n\n| Name | Value |\n| --- | --- |\n| Answer | 42 |\n\n![Local image](images/example.png)\n';
  const view = app.view;
  const $$ = selector => [...document.querySelectorAll(selector)];
  // Simulates a focused editor with the cursor at pos; test pages have no key window.
  const cursorAt = pos => view.dispatch({ selection: { anchor: pos }, effects: MarginLivePreview.setFocused.of(true) });
  const blur = () => view.dispatch({ effects: MarginLivePreview.setFocused.of(false) });
  const lineText = cls => document.querySelector(`.cm-line.${cls}`)?.textContent;
  await test('Loads Markdown exactly and renders it in place', async () => {
    app.load({ text: fixture, name: 'Example.md', path: '/tmp/Example.md' }); await tick();
    assert(view.state.doc.toString() === fixture && app.getMarkdown() === fixture, 'Loading changed the source');
    assert(lineText('cm-md-h1') === 'A real document', 'Heading marker shown while not editing: ' + lineText('cm-md-h1'));
    assert($$('.cm-md-strong').some(el => el.textContent === 'bold'), 'Bold not rendered');
    assert($$('.cm-md-em').length && $$('.cm-md-link').some(el => el.textContent === 'a link'), 'Emphasis or link not rendered');
    assert($$('.cm-md-task').length === 2 && $$('.cm-md-task')[0].checked, 'Task checkboxes missing');
    assert($$('.cm-md-codeblock').length >= 1, 'Code block not styled');
    assert($$('.cm-md-table').length === 1, 'Table not rendered');
    assert(document.querySelector('img.cm-md-image')?.getAttribute('src') === 'images/example.png', 'Image preview missing');
  });
  await test('Markers appear as editable text where the cursor is', async () => {
    cursorAt(3); await tick();
    assert(lineText('cm-md-h1') === '# A real document', 'Heading marker not shown at the cursor');
    cursorAt(fixture.indexOf('**bold**') + 3); await tick();
    assert($$('.cm-line').some(el => el.textContent.includes('**bold**')), 'Bold markers not shown at the cursor');
    blur(); await tick();
    assert(lineText('cm-md-h1') === 'A real document', 'Markers stayed visible after leaving the editor');
  });
  await test('Typing Markdown syntax renders it once the cursor moves on', async () => {
    app.load({ text: 'Intro\n', name: 'Typing.md' });
    cursorAt(6);
    view.dispatch({ changes: { from: 6, insert: '## Header' }, selection: { anchor: 15 }, userEvent: 'input.type' }); await tick();
    assert(lineText('cm-md-h2') === '## Header', 'New heading not shown as source while editing it');
    cursorAt(0); await tick();
    assert(lineText('cm-md-h2') === 'Header', 'New heading did not render after leaving it');
    assert(app.getMarkdown() === 'Intro\n## Header', 'Typing changed the Markdown');
  });
  await test('Task checkboxes edit the task text', async () => {
    app.load({ text: '- [ ] One\n- [x] Two\n', name: 'Tasks.md' }); blur(); await tick();
    $$('.cm-md-task')[0].click(); await tick();
    assert(app.getMarkdown() === '- [x] One\n- [x] Two\n', 'Checking a task did not edit its marker: ' + JSON.stringify(app.getMarkdown()));
    $$('.cm-md-task')[1].click(); await tick();
    assert(app.getMarkdown() === '- [x] One\n- [ ] Two\n', 'Unchecking a task did not edit its marker');
  });
  await test('Tables render until the cursor enters them', async () => {
    const text = 'Before\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter\n';
    app.load({ text, name: 'Table.md' }); cursorAt(0); await tick();
    assert($$('.cm-md-table').length === 1 && !$$('.cm-md-table-source').length, 'Table not rendered outside it');
    cursorAt(text.indexOf('| 1')); await tick();
    assert(!$$('.cm-md-table').length && $$('.cm-md-table-source').length === 3, 'Table source not shown inside it');
  });
  await test('Source mode shows plain Markdown in the same editor', async () => {
    app.load({ text: '# Title\n\n**Bold**\n', name: 'Source.md' }); blur(); await tick();
    app.command('source'); await tick();
    assert(app.isSource() && !$$('.cm-md-heading').length && $$('.cm-line')[0].textContent === '# Title', 'Source mode still decorated');
    view.dispatch({ changes: { from: view.state.doc.length, insert: 'More\n' } }); await tick();
    app.command('source'); await tick();
    assert(!app.isSource() && lineText('cm-md-h1') === 'Title' && app.getMarkdown() === '# Title\n\n**Bold**\nMore\n', 'Switching back lost edits or rendering');
  });
  await test('Editing reports changes to the app and marks the document edited', async () => {
    app.load({ text: '# Title\n\nHello world.\n', name: 'Edit.md' });
    view.dispatch({ changes: { from: view.state.doc.length, insert: 'More words.\n' } }); await tick();
    assert(app.getMarkdown().endsWith('More words.\n') && app.snapshot().text === app.getMarkdown(), 'Edit not reflected in the document');
    assert(!document.querySelector('#modified-dot').hidden, 'Dirty indicator missing');
  });
  await test('Formatting commands edit the Markdown text', async () => {
    app.load({ text: 'A paragraph\n', name: 'Format.md' });
    cursorAt(2);
    app.command('format', 'h2'); assert(app.getMarkdown() === '## A paragraph\n', 'Heading: ' + app.getMarkdown());
    app.command('format', 'h3'); assert(app.getMarkdown() === '### A paragraph\n', 'Heading change: ' + app.getMarkdown());
    app.command('format', 'paragraph'); assert(app.getMarkdown() === 'A paragraph\n', 'Body: ' + app.getMarkdown());
    view.dispatch({ selection: { anchor: 2, head: 11 } });
    app.command('format', 'bold'); assert(app.getMarkdown() === 'A **paragraph**\n', 'Bold: ' + app.getMarkdown());
    app.command('format', 'bold'); assert(app.getMarkdown() === 'A paragraph\n', 'Unbold: ' + app.getMarkdown());
    app.command('format', 'bulletList'); assert(app.getMarkdown() === '- A paragraph\n', 'List: ' + app.getMarkdown());
    app.command('format', 'taskList'); assert(app.getMarkdown() === '- [ ] A paragraph\n', 'Task: ' + app.getMarkdown());
    app.command('format', 'blockquote'); assert(app.getMarkdown() === '> - [ ] A paragraph\n', 'Quote: ' + app.getMarkdown());
    app.load({ text: 'Text\n', name: 'Format.md' }); cursorAt(4);
    app.command('format', 'table'); assert(/\| --- \| --- \| --- \|/.test(app.getMarkdown()) && app.getMarkdown().startsWith('Text\n\n| Column'), 'Table: ' + app.getMarkdown());
  });
  await test('Save metadata updates the file path without replacing editor contents', async () => {
    app.load({ text: 'Keep this content\n', modified: true });
    app.command('metadata', { name: 'Saved.md', path: '/notes/Saved.md' });
    assert(document.querySelector('#document-name').textContent === 'Saved.md', 'Saved filename not updated');
    assert(document.querySelector('#document-name').title === '/notes/Saved.md', 'Saved path not updated');
    assert(document.querySelector('#modified-dot').hidden, 'Dirty indicator not cleared');
    assert(app.getMarkdown() === 'Keep this content\n', 'Save metadata replaced contents');
  });
  await test('Outline updates and code block headings are excluded', async () => {
    app.load({ text: '# First\n\n## Second\n\n```md\n# Not a heading\n```\n' });
    app.command('outline'); await tick();
    assert($$('#outline button').map(b => b.textContent).join('|') === 'First|Second', 'Outline incorrect');
    app.command('source'); await tick();
    assert($$('#outline button').length === 2, 'Source outline included code');
    app.command('source');
  });
  await test('Folder filtering and safe filenames', async () => {
    app.command('folder', { name: 'Notes', children: [{ name: 'Work', children: [{ name: 'Plan.md', path: '/notes/Plan.md' }] }, { name: '<img onerror=alert(1)>.md', path: '/notes/safe.md' }] });
    assert($$('.file-row').length === 2, 'Folder files missing');
    assert(!document.querySelector('#file-tree img'), 'Filename interpreted as HTML');
    const filter = document.querySelector('#file-filter'); filter.value = 'plan'; filter.dispatchEvent(new Event('input'));
    assert($$('.file-row').length === 1, 'Filter incorrect');
    filter.value = ''; filter.dispatchEvent(new Event('input'));
  });
  await test('Search finds and selects document text', async () => {
    app.load({ text: '# Find\n\nA needle in a haystack. Another needle.\n' });
    app.command('find'); const input = document.querySelector('#find-input'); input.value = 'needle'; input.dispatchEvent(new Event('input')); await tick();
    assert(document.querySelector('#find-result').textContent === '1 of 2', 'Search did not locate matches');
    const first = view.state.selection.main;
    assert(view.state.sliceDoc(first.from, first.to) === 'needle', 'Match not selected');
    document.querySelector('#find-next').click();
    assert(document.querySelector('#find-result').textContent === '2 of 2' && view.state.selection.main.from > first.from, 'Next result failed');
    document.querySelector('#find-close').click();
  });
  await test('Typewriter control works', async () => {
    app.command('typewriter'); assert(document.body.classList.contains('typewriter'), 'Typewriter mode not applied');
    app.command('typewriter');
  });
  await test('Document HTML cannot execute scripts', async () => {
    app.load({ text: '# Safety\n\n<script>window.__unsafe = true</script>\n\n<img src="x" onerror="window.__unsafe=true">\n\n![x](javascript:alert(1))\n' }); await tick();
    assert(!window.__unsafe, 'Untrusted HTML executed');
    assert(!app.getHTML().includes('onerror=') && !app.getHTML().includes('<script'), 'Unsafe markup survived sanitizer');
    assert(!document.querySelector('#editor img[onerror]') && !$$('#editor img').some(img => (img.getAttribute('src') || '').startsWith('javascript:')), 'Editor rendered unsafe markup');
  });
  await test('Export and print render tasks and tables', async () => {
    app.load({ text: '- [x] Done\n\n| A |\n| - |\n| 1 |\n' });
    const html = app.getHTML();
    assert(html.includes('type="checkbox"') && html.includes('<td>1</td>'), 'Rendered HTML lacks tasks or tables: ' + html);
    app.preparePrint();
    assert(document.querySelector('#print-view input[type=checkbox]') && document.querySelector('#print-view td'), 'Print view not rendered');
  });
  app.load({ text: app.welcome, name: 'Welcome.md' });
  app.command('folder', { name: 'My Writing', children: [{ name: 'Welcome.md', path: '/Welcome.md' }, { name: 'Notes', children: [{ name: 'A small idea.md', path: '/idea.md' }, { name: 'Reading list.md', path: '/reading.md' }] }] });
  await tick();
  await test('The page raised no uncaught errors', async () => { assert(!pageErrors.length, pageErrors.join('; ')); });
  return results;
})();
