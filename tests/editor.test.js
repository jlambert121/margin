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
  await test('Nested lists indent by depth, vary their bullets, and wrap under their text', async () => {
    const long = 'A long item that keeps going so that it wraps onto another line in the editor, '.repeat(4);
    app.load({ text: `- One\n  - Two\n    - Three\n- ${long}\n\n1. First\n   continued line\n`, name: 'Lists.md' }); blur(); await tick();
    const lines = $$('.cm-md-list-line');
    assert(lines.map(line => line.textContent).slice(0, 3).join('|') === '•One|◦Two|▪Three', 'Bullets or hidden indentation wrong: ' + lines.map(line => line.textContent).join('|'));
    const left = line => parseFloat(getComputedStyle(line).paddingLeft);
    const em = parseFloat(getComputedStyle(lines[0]).fontSize);
    assert(Math.abs(left(lines[1]) - left(lines[0]) - 1.5 * em) < 1 && Math.abs(left(lines[2]) - left(lines[1]) - 1.5 * em) < 1, `Depth indent wrong: ${lines.slice(0, 3).map(left)}`);
    const continued = $$('.cm-md-list-continuation');
    assert(continued.length === 1 && continued[0].textContent === 'continued line', 'Continuation line not indented under its item');
    const textStart = view.state.doc.toString().indexOf('A long');
    const first = view.coordsAtPos(textStart);
    let wrapped = textStart;
    while (wrapped < textStart + long.length && view.coordsAtPos(wrapped).top <= first.top + 1) wrapped++;
    assert(wrapped < textStart + long.length, 'Long item did not wrap');
    assert(Math.abs(view.coordsAtPos(wrapped).left - first.left) < 2, `Wrapped line starts at ${view.coordsAtPos(wrapped).left}, its text at ${first.left}`);
    cursorAt(view.state.doc.line(2).from + 5); await tick();
    assert(lineText('cm-md-list-line') !== undefined && $$('.cm-md-list-line')[1].textContent === '  - Two', 'Editing a nested item did not show its source');
    blur();
  });
  await test('YAML front matter is a metadata block, not a heading, and stays out of the outline and output', async () => {
    app.load({ name: 'Front.md', text: '---\r\ntitle: My note\ntags: [a, b]\n---\n\n# Real heading\n\nOne two.\n' }); blur(); await tick();
    assert(app.headings().map(h => h.text).join('|') === 'Real heading', 'Front matter reached the outline: ' + app.headings().map(h => h.text).join('|'));
    const lines = $$('.cm-md-frontmatter');
    assert(lines.length === 4 && !document.querySelector('.cm-md-h2') && !document.querySelector('.cm-md-hr'), 'Front matter not shown as one block');
    assert(lines[0].textContent === 'front matter' && lines[1].textContent === 'title: My note', 'Front matter label or content wrong: ' + lines.map(l => l.textContent).join('|'));
    assert(lines[1].querySelector('[class*="cm-code-"]'), 'YAML not highlighted');
    cursorAt(1); await tick();
    assert($$('.cm-md-frontmatter')[0].textContent === '---' && $$('.cm-md-frontmatter')[3].textContent === '---', 'Front matter source not shown while editing it');
    blur(); await tick();
    assert(!app.getHTML().includes('My note') && app.getHTML().includes('Real heading'), 'Front matter rendered in the output');
    assert(document.querySelector('#word-count').textContent === '4 words', 'Front matter counted as words: ' + document.querySelector('#word-count').textContent);
    app.load({ name: 'Rule.md', text: '---\nNot front matter, a rule.\n' }); blur(); await tick();
    assert(!document.querySelector('.cm-md-frontmatter') && document.querySelector('.cm-md-hr'), 'A leading rule became front matter');
  });
  await test('Pasted HTML becomes Markdown only when it has structure', async () => {
    const paste = (html, plain) => {
      const data = new DataTransfer();
      if (html) data.setData('text/html', html);
      data.setData('text/plain', plain);
      view.contentDOM.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
    };
    const pasted = (html, plain, before = '') => {
      app.load({ name: 'Paste.md', text: before });
      view.dispatch({ selection: { anchor: view.state.doc.length } });
      paste(html, plain);
      return view.state.doc.toString().slice(before.length);
    };
    const page = '<meta charset="utf-8"><h2>Title</h2><p>Some <strong>bold</strong> and <a href="https://example.com/a">a link</a>.</p><ul><li>One<ul><li>Nested</li></ul></li><li>Two</li></ul><ol><li>First</li></ol><table><tr><td>A</td><td>B</td></tr><tr><td>1</td><td>2</td></tr></table>';
    const markdown = pasted(page, 'Title Some bold and a link. One Nested Two First A B 1 2');
    assert(markdown.startsWith('## Title\n\nSome **bold** and [a link](https://example.com/a).\n\n- One\n  - Nested\n- Two\n\n1. First'), 'Web page not converted: ' + JSON.stringify(markdown));
    assert(/\|\s*A\s*\|\s*B\s*\|/.test(markdown) && !markdown.includes('<table'), 'Table not converted: ' + JSON.stringify(markdown));
    const code = 'const total = price * count; // _not_ emphasis';
    assert(pasted('<meta charset="utf-8"><div style="color: #d4d4d4;"><div><span style="color: #569cd6;">const</span> total = price * count; // _not_ emphasis</div></div>', code) === code, 'Code editor HTML was converted');
    assert(pasted(null, 'plain *text* stays') === 'plain *text* stays', 'Plain text paste changed');
    assert(pasted('<a href="https://example.com">https://example.com</a>', 'https://example.com') === 'https://example.com', 'A pasted URL was converted');
    const docs = '<b style="font-weight:normal;" id="docs-internal-guid-1"><span style="font-weight:700;">Bold</span><span> and </span><span style="font-style:italic;">italic</span></b>';
    assert(pasted(docs, 'Bold and italic') === '**Bold** and *italic*', 'Google Docs emphasis wrong: ' + JSON.stringify(pasted(docs, 'Bold and italic')));
    assert(pasted('<p><strong>bold</strong></p>', 'bold', '```\n') === 'bold', 'Paste inside a code block was converted');
    app.load({ name: 'Plain.md', text: '' });
    app.command('pastePlain', '<b>not html</b> **as is**');
    assert(view.state.doc.toString() === '<b>not html</b> **as is**', 'Paste and Match Style changed the text');
  });
  await test('A click with a little pointer movement places the cursor even where markers appear', async () => {
    const press = async (target, moveTo = null) => {
      const point = pos => { const { left, top, bottom } = view.coordsAtPos(pos); return { clientX: left + 1, clientY: (top + bottom) / 2 }; };
      const init = { bubbles: true, cancelable: true, button: 0, buttons: 1, detail: 1, ...point(target) };
      document.elementFromPoint(init.clientX, init.clientY).dispatchEvent(new MouseEvent('mousedown', init));
      await tick();
      const end = moveTo === null ? { clientX: init.clientX + 1, clientY: init.clientY } : point(moveTo);
      document.dispatchEvent(new MouseEvent('mousemove', { ...init, ...end }));
      await tick();
      document.dispatchEvent(new MouseEvent('mouseup', { ...init, ...end, buttons: 0 }));
      await tick();
    };
    const cases = [
      ['heading', 'Intro text here\n\n## A heading line here\n\nMore text\n', 0, 3, 6],
      ['bold', 'Intro text here\n\nSome **bold words** in it\n', 0, 3, 12],
      ['nested list', 'Intro\n\n- one\n  - nested item text\n', 0, 4, 8],
      ['below the code block holding the cursor', '```js\nlet a = 1\n```\n\nPlain line\nPlain line\nPlain line\nTarget words here\n', 7, 8, 7],
    ];
    for (const [label, text, cursor, line, offset] of cases) {
      app.load({ text, name: 'Click.md' }); await tick();
      cursorAt(cursor); await tick();
      const target = view.state.doc.line(line).from + offset;
      await press(target);
      const { from, to } = view.state.selection.main;
      assert(from === target && to === target, `Clicking a ${label} selected ${JSON.stringify(view.state.sliceDoc(from, to))}`);
    }
    // A click that focuses the editor reveals the old cursor line's markers too.
    app.load({ text: '```js\nlet a = 1\n```\n\nPlain line\nTarget words here\n', name: 'Click.md' }); await tick();
    view.dispatch({ selection: { anchor: 7 } }); blur(); await tick();
    const target = view.state.doc.line(6).from + 7;
    await press(target);
    assert(view.state.selection.main.empty && view.state.selection.main.head === target, 'A click that focused the editor selected text');
    // Dragging still selects, and the clicked line's markers show once the button is up.
    app.load({ text: 'Intro\n\n## Heading words here\n', name: 'Drag.md' }); await tick();
    cursorAt(0); await tick();
    const start = view.state.doc.line(3).from + 3;
    await press(start, start + 7);
    assert(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to) === 'Heading', 'Drag did not select: ' + JSON.stringify(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)));
    await tick();
    assert(lineText('cm-md-h2') === '## Heading words here', 'Markers did not appear after the click: ' + lineText('cm-md-h2'));
    blur();
  });
  await test('Task checkboxes edit the task text', async () => {
    app.load({ text: '- [ ] One\n- [x] Two\n', name: 'Tasks.md' }); blur(); await tick();
    $$('.cm-md-task')[0].click(); await tick();
    assert(app.getMarkdown() === '- [x] One\n- [x] Two\n', 'Checking a task did not edit its marker: ' + JSON.stringify(app.getMarkdown()));
    $$('.cm-md-task')[1].click(); await tick();
    assert(app.getMarkdown() === '- [x] One\n- [ ] Two\n', 'Unchecking a task did not edit its marker');
  });
  const tableText = 'Before\n\n| Name | Value |\n| :--- | :---: |\n| **Bold** | a \\| b |\n| Plain | 2 |\n\nAfter\n';
  const grid = () => document.querySelector('.cm-md-table table');
  const cell = (row, col) => document.querySelector(`.cm-md-table [data-row="${row}"][data-col="${col}"]`);
  const editing = () => document.querySelector('.cm-md-cell-editing');
  const press = (target, key, init = {}) => target.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...init }));
  const typeInCell = text => { const target = editing(); target.textContent = text; target.dispatchEvent(new InputEvent('input', { bubbles: true })); };
  const menuItem = async (row, col, label) => {
    cell(row, col).dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 50, clientY: 50 }));
    const button = [...document.querySelectorAll('.table-menu button')].find(b => b.textContent === label);
    assert(button && !button.disabled, `Menu item unavailable: ${label}`);
    button.click(); await tick();
  };
  await test('Tables render as a grid with inline formatting and alignment', async () => {
    app.load({ text: tableText, name: 'Table.md' }); cursorAt(0); await tick();
    assert(grid() && grid().querySelectorAll('th').length === 2 && grid().querySelectorAll('tbody tr').length === 2, 'Grid shape wrong');
    assert(cell(1, 0).querySelector('strong')?.textContent === 'Bold', 'Inline Markdown not rendered in a cell');
    assert(cell(1, 1).textContent === 'a | b', 'Escaped pipe shown wrong: ' + cell(1, 1).textContent);
    assert(cell(0, 1).style.textAlign === 'center' && cell(0, 0).style.textAlign === 'left', 'Column alignment not applied');
    cursorAt(tableText.indexOf('| Plain')); await tick();
    assert(grid(), 'Cursor next to the table switched it to Markdown');
  });
  await test('Editing a cell changes only that cell and keeps the cell focused', async () => {
    app.load({ text: tableText, name: 'Table.md' }); await tick();
    cell(1, 0).dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }));
    const target = editing();
    assert(target === cell(1, 0) && target.textContent === '**Bold**', 'Editing cell does not show its Markdown');
    typeInCell('**Bolder** | text'); await tick();
    const expected = tableText.replace('**Bold**', '**Bolder** \\| text');
    assert(app.getMarkdown() === expected, 'Cell edit rewrote more than the cell: ' + JSON.stringify(app.getMarkdown()));
    assert(editing() === target && target.isConnected, 'The edited cell was replaced while typing');
    press(target, 'Escape'); await tick();
    assert(!editing() && cell(1, 0).querySelector('strong')?.textContent === 'Bolder', 'Leaving the cell did not render it');
  });
  await test('Tab and Enter move between cells, and Tab in the last cell adds a row', async () => {
    app.load({ text: tableText, name: 'Table.md' }); await tick();
    cell(0, 0).dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }));
    press(editing(), 'Tab');
    assert(editing() === cell(0, 1), 'Tab did not move right');
    press(editing(), 'Enter');
    assert(editing() === cell(1, 1), 'Enter did not move down');
    press(editing(), 'Tab', { shiftKey: true });
    assert(editing() === cell(1, 0), 'Shift-Tab did not move left');
    cell(2, 1).dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }));
    press(editing(), 'Tab'); await tick();
    assert(app.getMarkdown() === tableText.replace('| Plain | 2 |', '| Plain | 2 |\n|  |  |'), 'Tab at the end did not add a row: ' + JSON.stringify(app.getMarkdown()));
    assert(editing() === cell(3, 0), 'New row not focused');
    typeInCell('New'); await tick();
    assert(app.getMarkdown().includes('| New |  |'), 'Typing in the new row failed: ' + JSON.stringify(app.getMarkdown()));
  });
  await test('The table menu edits rows, columns, and alignment', async () => {
    app.load({ text: tableText, name: 'Table.md' }); cursorAt(0); await tick();
    await menuItem(1, 1, 'Insert Column Right');
    assert(app.getMarkdown().includes('| Name | Value |  |\n| :--- | :---: | --- |\n| **Bold** | a \\| b |  |'), 'Insert column: ' + app.getMarkdown());
    await menuItem(0, 2, 'Align Right');
    assert(app.getMarkdown().includes('| :--- | :---: | ---: |'), 'Align: ' + app.getMarkdown());
    await menuItem(1, 2, 'Delete Column');
    assert(app.getMarkdown().includes('| Name | Value |\n| :--- | :---: |'), 'Delete column: ' + app.getMarkdown());
    await menuItem(1, 0, 'Move Row Down');
    assert(app.getMarkdown().includes('| Plain | 2 |\n| **Bold** | a \\| b |'), 'Move row: ' + app.getMarkdown());
    await menuItem(1, 0, 'Move Column Right');
    assert(app.getMarkdown().includes('| Value | Name |'), 'Move column: ' + app.getMarkdown());
    await menuItem(2, 0, 'Delete Row');
    assert(!app.getMarkdown().includes('Bold'), 'Delete row: ' + app.getMarkdown());
    await menuItem(1, 0, 'Insert Row Above');
    assert(grid().querySelectorAll('tbody tr').length === 2 && editing() === cell(1, 0), 'Insert row above: ' + app.getMarkdown());
    press(editing(), 'Escape'); await tick();
  });
  await test('Edit as Markdown shows the table source until the cursor leaves it', async () => {
    app.load({ text: tableText, name: 'Table.md' }); cursorAt(0); await tick();
    await menuItem(1, 0, 'Edit as Markdown');
    assert(!grid() && $$('.cm-md-table-source').length === 4, 'Table source not shown');
    cursorAt(tableText.indexOf('| Plain') + 3); await tick();
    assert(!grid(), 'Moving inside the table hid its source');
    cursorAt(0); await tick();
    assert(grid(), 'Leaving the table did not restore the grid');
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
  await test('Outline headings exclude code blocks in both modes', async () => {
    app.load({ text: '# First\n\n## Second\n\n```md\n# Not a heading\n```\n' }); await tick();
    assert(app.headings().map(h => h.text).join('|') === 'First|Second', 'Outline incorrect');
    app.command('source'); await tick();
    assert(app.headings().length === 2, 'Source outline included code');
    app.command('source');
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
  await test('Status bar shows the cursor line and column', async () => {
    app.load({ name: 'Cursor.md', text: '# Title\n\nSecond line\n' });
    const position = document.querySelector('#cursor-position');
    assert(position.textContent === 'Ln 1, Col 1', `Unexpected initial position: ${position.textContent}`);
    view.dispatch({ selection: { anchor: view.state.doc.line(3).from + 6 } });
    assert(position.textContent === 'Ln 3, Col 7', `Position did not follow the cursor: ${position.textContent}`);
  });
  // Types text through the editor's input handlers, as a keystroke would.
  const type = text => {
    const { from, to } = view.state.selection.main;
    const insert = () => view.state.update({ changes: { from, to, insert: text }, selection: { anchor: from + text.length }, userEvent: 'input.type' });
    if (!view.state.facet(EditorView.inputHandler).some(handler => handler(view, from, to, text, insert))) view.dispatch(insert());
  };
  const { EditorView } = MarginEditor;
  const findInput = value => { const input = document.querySelector('#find-input'); input.value = value; input.dispatchEvent(new Event('input')); };
  await test('Find and replace replaces one match at a time and all at once', async () => {
    app.load({ name: 'Replace.md', text: 'a.b axb a.b a.b\n' });
    app.command('replace'); await tick();
    assert(!document.querySelector('#replace-input').hidden && getComputedStyle(document.querySelector('#replace-one')).display !== 'none', 'Replace controls hidden');
    findInput('a.b');
    assert(document.querySelector('#find-result').textContent === '1 of 3', 'Literal search treated . as a pattern: ' + document.querySelector('#find-result').textContent);
    document.querySelector('#replace-input').value = 'X';
    document.querySelector('#replace-one').click();
    assert(view.state.doc.toString() === 'X axb a.b a.b\n', 'Replace changed the wrong text: ' + view.state.doc.toString());
    assert(document.querySelector('#find-result').textContent === '1 of 2' && view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to) === 'a.b', 'Replace did not move to the next match');
    document.querySelector('#replace-all').click();
    assert(view.state.doc.toString() === 'X axb X X\n', 'Replace all failed: ' + view.state.doc.toString());
    app.command('find');
    assert(getComputedStyle(document.querySelector('#replace-one')).display === 'none', 'Find did not hide replace');
    document.querySelector('#find-close').click();
  });
  await test('Regular expression search expands groups and reports invalid patterns', async () => {
    app.load({ name: 'Regex.md', text: 'ann@example\nbob@test\n' });
    app.command('replace');
    document.querySelector('#find-regex').click();
    assert(document.querySelector('#find-regex').getAttribute('aria-pressed') === 'true', 'Regex toggle did not turn on');
    findInput('(');
    assert(document.querySelector('#find-result').textContent === 'Invalid pattern', 'Invalid pattern not reported');
    findInput('^(\\w+)@(\\w+)$');
    assert(document.querySelector('#find-result').textContent === '1 of 2', 'Line anchors did not match each line');
    document.querySelector('#replace-input').value = '$2 at $1';
    document.querySelector('#replace-one').click();
    assert(view.state.doc.toString() === 'example at ann\nbob@test\n', 'Groups not expanded: ' + view.state.doc.toString());
    document.querySelector('#replace-all').click();
    assert(view.state.doc.toString() === 'example at ann\ntest at bob\n', 'Replace all did not expand groups: ' + JSON.stringify(view.state.doc.toString()));
    document.querySelector('#find-regex').click();
    document.querySelector('#find-close').click();
  });
  await test('Go to line moves the cursor to a line and column', async () => {
    app.load({ name: 'Lines.md', text: 'one\ntwo\nthree\n' });
    app.command('goToLine');
    const input = document.querySelector('#goto-input'), enter = () => input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    assert(!document.querySelector('#goto-bar').hidden && document.activeElement === input, 'Go to line did not open');
    input.value = 'nope'; enter();
    assert(document.querySelector('#goto-result').textContent === 'Enter a line number', 'Bad input not reported');
    input.value = '3:4'; enter();
    assert(document.querySelector('#goto-bar').hidden && view.state.selection.main.head === 8 + 3, 'Did not go to line 3, column 4');
    assert(document.querySelector('#cursor-position').textContent === 'Ln 3, Col 4', 'Status bar not updated');
    app.command('goToLine'); input.value = '99:99'; enter();
    assert(view.state.selection.main.head === view.state.doc.length, 'Out of range line was not clamped to the end');
  });
  await test('Brackets and quotes close, and emphasis markers wrap a selection', async () => {
    app.load({ name: 'Brackets.md', text: '' });
    type('('); assert(view.state.doc.toString() === '()' && view.state.selection.main.head === 1, 'Parenthesis not closed');
    type(')'); assert(view.state.doc.toString() === '()' && view.state.selection.main.head === 2, 'Closing parenthesis not stepped over');
    type(' '); type('"'); assert(view.state.doc.toString() === '() ""', 'Double quote not closed: ' + JSON.stringify(view.state.doc.toString()));
    app.load({ name: 'Fence.md', text: '' });
    type('`'); type('`'); type('`');
    assert(view.state.doc.toString() === '```' && view.state.selection.main.head === 3, 'Typing a code fence left extra backticks: ' + JSON.stringify(view.state.doc.toString()));
    app.load({ name: 'Apostrophe.md', text: '' });
    type("'"); assert(view.state.doc.toString() === "'", 'Single quote was paired');
    app.load({ name: 'Wrap.md', text: 'some word here' });
    view.dispatch({ selection: { anchor: 5, head: 9 } });
    type('*'); type('*');
    assert(view.state.doc.toString() === 'some **word** here', 'Selection not wrapped: ' + view.state.doc.toString());
    assert(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to) === 'word', 'Wrapped text no longer selected');
    view.dispatch({ selection: { anchor: 0 } });
    type('*'); assert(view.state.doc.toString() === '*some **word** here', 'A marker without a selection was paired');
  });
  await test('Fenced code is highlighted in its language and Markdown text is not', async () => {
    app.load({ name: 'Code.md', text: '# Title "quoted"\n\n```javascript\nconst x = "s"; // note\n```\n\n```md\n# Inner\n```\n' });
    app.command('source');
    let keyword;
    for (let tries = 0; tries < 20 && !keyword; tries++) { await tick(); keyword = $$('.cm-code-keyword').find(node => node.textContent === 'const'); }
    assert(keyword, 'JavaScript keyword not highlighted');
    assert($$('.cm-code-string').some(node => node.textContent === '"s"') && $$('.cm-code-comment').some(node => node.textContent === '// note'), 'String or comment not highlighted');
    assert(!document.querySelector('.cm-line .cm-code-string')?.closest('.cm-line')?.textContent.startsWith('# Title'), 'Markdown text was highlighted as code');
    assert(app.headings().map(h => h.text).join('|') === 'Title "quoted"', 'Markdown inside a code block reached the outline');
    app.command('source');
  });
  await test('Text zoom scales the document text only', async () => {
    const size = () => parseFloat(getComputedStyle(view.scrollDOM).fontSize);
    const base = size(), chrome = getComputedStyle(document.querySelector('#statusbar')).fontSize;
    app.command('textZoom', 1.5);
    assert(Math.abs(size() - base * 1.5) < 0.01, `Text did not scale: ${base} → ${size()}`);
    assert(getComputedStyle(document.querySelector('#statusbar')).fontSize === chrome, 'Status bar scaled with the text');
    app.load({ name: 'Zoomed.md', text: 'x', textZoom: 1 });
    assert(Math.abs(size() - base) < 0.01, 'Loading did not apply the zoom it was sent');
  });
  await test('The title bar inset pushes the layout down and a tab bar hides the toolbar name', async () => {
    const main = document.querySelector('main'), name = document.querySelector('#document-name');
    assert(getComputedStyle(main).paddingTop === '0px' && getComputedStyle(name).display !== 'none', 'Unexpected default title bar layout');
    app.command('titlebar', { inset: 68, tabBar: true });
    assert(getComputedStyle(main).paddingTop === '68px', 'Inset not applied');
    assert(getComputedStyle(name).display === 'none', 'Toolbar name shown beside a tab bar');
    app.command('titlebar', { inset: 32, tabBar: false });
    assert(getComputedStyle(name).display !== 'none' && getComputedStyle(main).paddingTop === '32px', 'Single tab did not show the name');
    app.command('titlebar', { inset: 0, tabBar: false });
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
