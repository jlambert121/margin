(async () => {
  const results = [];
  const app = window.app;
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const test = async (name, fn) => { try { await fn(); results.push({ name, passed: true }); } catch (error) { results.push({ name, passed: false, error: error.message }); } };
  const tick = () => new Promise(resolve => setTimeout(resolve, 150));
  const fixture = '# A real document\n\nA paragraph with **bold**, *emphasis*, and [a link](https://example.com).\n\n## Next steps\n\n- [x] Finished\n- [ ] Pending\n\n```swift\nlet value = 42\n```\n\n| Name | Value |\n| --- | --- |\n| Answer | 42 |\n\n![Local image](images/example.png)\n';
  await test('Loads headings, marks, tasks, code, tables, and relative images', async () => {
    app.load({ text: fixture, name: 'Example.md', path: '/tmp/Example.md' }); await tick();
    const content = document.querySelector('.toastui-editor-ww-container');
    assert(content.querySelector('h1').textContent === 'A real document', 'Heading not rendered');
    assert(content.querySelector('strong').textContent === 'bold', 'Bold not rendered');
    assert(content.querySelector('em'), 'Emphasis missing');
    assert(content.querySelector('a[href="https://example.com"]'), 'Link missing');
    assert(content.querySelectorAll('.task-list-item').length === 2, 'Tasks missing');
    assert(content.querySelector('pre').textContent.includes('let value = 42'), 'Code missing');
    assert(content.querySelector('table').textContent.includes('Answer'), 'Table missing');
    assert(content.querySelector('img').getAttribute('src') === 'images/example.png', 'Relative image path changed');
    assert(app.getMarkdown() === fixture, 'Loading changed original source');
  });
  await test('Source toggle preserves exact Markdown until edited', async () => {
    app.command('source');
    const textarea = document.querySelector('#source-editor');
    assert(textarea.value === fixture, 'Source toggle normalized original text');
    app.command('source'); await tick();
    assert(app.getMarkdown() === fixture, 'Round trip changed original source');
  });
  await test('Source edits survive switching back to rich text', async () => {
    app.command('source');
    const textarea = document.querySelector('#source-editor');
    textarea.value = '# Source edit\n\nA new paragraph.\n'; textarea.dispatchEvent(new Event('input', { bubbles: true }));
    app.command('source'); await tick();
    assert(document.querySelector('.toastui-editor-ww-container h1').textContent === 'Source edit', 'Source changes not rendered');
    assert(app.getMarkdown().includes('A new paragraph.'), 'Source changes lost');
  });
  await test('Rich editing serializes back to Markdown', async () => {
    app.load({ text: '# Title\n\nHello world.\n', name: 'Edit.md' });
    app.editor.moveCursorToEnd(); app.editor.insertText(' More words.'); await tick();
    assert(app.getMarkdown().includes('More words.'), 'Rich changes did not serialize');
    assert(!document.querySelector('#modified-dot').hidden, 'Dirty indicator missing');
  });
  await test('Formatting commands create headings, body paragraphs, and tables', async () => {
    app.load({ text: 'A paragraph\n' });
    app.editor.moveCursorToEnd(); app.command('format', 'h2');
    assert(/<h2(?:\s|>)/.test(app.getHTML()), 'Heading command failed: ' + app.getHTML());
    app.command('format', 'paragraph');
    assert(!/<h2(?:\s|>)/.test(app.getHTML()), 'Body command did not remove heading: ' + app.getHTML());
    app.editor.moveCursorToEnd(); app.command('format', 'table');
    assert(/<table(?:\s|>)/.test(app.getHTML()), 'Table insertion failed');
  });
  await test('Save metadata updates the file path without replacing editor contents', async () => {
    app.load({ text: 'Keep this content\n', modified: true });
    app.command('metadata', { name: 'Saved.md', path: '/notes/Saved.md' });
    assert(document.querySelector('#document-name').textContent === 'Saved.md', 'Saved filename not updated');
    assert(document.querySelector('#document-name').title === '/notes/Saved.md', 'Saved path not updated');
    assert(document.querySelector('#modified-dot').hidden, 'Dirty indicator not cleared');
    assert(app.getMarkdown() === 'Keep this content\n', 'Save metadata replaced contents');
  });
  await test('Outline updates and source code headings are excluded', async () => {
    app.load({ text: '# First\n\n## Second\n\n```md\n# Not a heading\n```\n' });
    app.command('outline'); await tick();
    assert(document.querySelectorAll('#outline button').length === 2, 'Rich outline incorrect');
    app.command('source'); await tick();
    assert(document.querySelectorAll('#outline button').length === 2, 'Source outline included code');
    app.command('source');
  });
  await test('Folder filtering and safe filenames', async () => {
    app.command('folder', { name: 'Notes', children: [{ name: 'Work', children: [{ name: 'Plan.md', path: '/notes/Plan.md' }] }, { name: '<img onerror=alert(1)>.md', path: '/notes/safe.md' }] });
    assert(document.querySelectorAll('.file-row').length === 2, 'Folder files missing');
    assert(!document.querySelector('#file-tree img'), 'Filename interpreted as HTML');
    const filter = document.querySelector('#file-filter'); filter.value = 'plan'; filter.dispatchEvent(new Event('input'));
    assert(document.querySelectorAll('.file-row').length === 1, 'Filter incorrect');
    filter.value = ''; filter.dispatchEvent(new Event('input'));
  });
  await test('Search finds document text', async () => {
    app.load({ text: '# Find\n\nA needle in a haystack. Another needle.\n' });
    app.command('find'); const input = document.querySelector('#find-input'); input.value = 'needle'; input.dispatchEvent(new Event('input')); await tick();
    assert(document.querySelector('#find-result').textContent === '1 of 2', 'Search did not locate matches');
    document.querySelector('#find-next').click();
    assert(document.querySelector('#find-result').textContent === '2 of 2', 'Next result failed');
    document.querySelector('#find-close').click();
  });
  await test('Theme, focus, and typewriter controls work', async () => {
    app.command('theme', 'dark'); assert(document.body.dataset.theme === 'dark', 'Dark theme not applied');
    app.command('focus'); assert(document.body.classList.contains('focus-mode'), 'Focus mode not applied');
    app.command('focus'); app.command('typewriter'); assert(document.body.classList.contains('typewriter'), 'Typewriter mode not applied');
    app.command('typewriter'); app.command('theme', 'light');
  });
  await test('Document HTML cannot execute scripts', async () => {
    app.load({ text: '# Safety\n\n<script>window.__unsafe = true</script>\n\n<img src="x" onerror="window.__unsafe=true">\n' }); await tick();
    assert(!window.__unsafe, 'Untrusted HTML executed');
    assert(!app.getHTML().includes('onerror='), 'Unsafe attribute survived sanitizer');
  });
  app.load({ text: app.welcome, name: 'Welcome.md' });
  app.command('folder', { name: 'My Writing', children: [{ name: 'Welcome.md', path: '/Welcome.md' }, { name: 'Notes', children: [{ name: 'A small idea.md', path: '/idea.md' }, { name: 'Reading list.md', path: '/reading.md' }] }] });
  return results;
})();
