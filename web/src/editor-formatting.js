/* editor formatting: one instance owns this feature's state. */
(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const { EditorSelection } = MarginEditor;
  class EditorFormatting {
    constructor({ view, closeMenus, toast }) {
      this.view = view;
      this.closeMenus = closeMenus;
      this.toast = toast;
      this.insertKind = "link";
      $('#insert-dialog').addEventListener('close', () => {
    if ($('#insert-dialog').returnValue !== 'insert') return;
    const url = $('#insert-url').value.trim(); const description = $('#insert-description').value.trim();
    if (!url || /^(javascript|vbscript|file):/i.test(url) || (this.insertKind === 'link' && /^data:/i.test(url))) { this.toast('Please use a web address or a relative file path.'); return; }
    const label = (this.insertKind === 'image' ? description : description || url).replace(/[[\]]/g, '\\$&');
    const target = /\s|[()]/.test(url) ? `<${url}>` : url;
    const text = `${this.insertKind === 'image' ? '!' : ''}[${label}](${target})`;
    const { from, to } = this.view.state.selection.main;
    this.view.dispatch({ changes: { from, to, insert: text }, selection: { anchor: from + text.length }, userEvent: 'input.format' });
    this.view.focus();
  });
      this.listPrefix = /^(\s*)(?:[-*+] \[[ xX]\] |[-*+] |\d+[.)] )?/;
      this.listKinds = {
    bulletList: { test: /^\s*[-*+] (?!\[[ xX]\] )/, prefix: () => '- ' },
    orderedList: { test: /^\s*\d+[.)] /, prefix: index => `${index + 1}. ` },
    taskList: { test: /^\s*[-*+] \[[ xX]\] /, prefix: () => '- [ ] ' },
  };
    }

    insertDialog = (kind) => {
      this.insertKind = kind;
      const { from, to } = this.view.state.selection.main;
      $('#insert-title').textContent = kind === 'image' ? 'Insert image' : 'Insert link';
      $('#insert-url').value = ''; $('#insert-description').value = this.view.state.sliceDoc(from, to);
      $('#insert-dialog').showModal(); $('#insert-url').focus();
    };

    wrapSelection = (marker) => {
      this.view.dispatch(this.view.state.changeByRange(range => {
        const before = this.view.state.sliceDoc(range.from - marker.length, range.from);
        const after = this.view.state.sliceDoc(range.to, range.to + marker.length);
        const outside = this.view.state.sliceDoc(range.from - marker.length - 1, range.from - marker.length) + this.view.state.sliceDoc(range.to + marker.length, range.to + marker.length + 1);
        if (before === marker && after === marker && !outside.includes(marker[0])) {
          return { changes: [{ from: range.from - marker.length, to: range.from }, { from: range.to, to: range.to + marker.length }],
            range: EditorSelection.range(range.from - marker.length, range.to - marker.length) };
        }
        return { changes: [{ from: range.from, insert: marker }, { from: range.to, insert: marker }],
          range: EditorSelection.range(range.from + marker.length, range.to + marker.length) };
      }), { userEvent: 'input.format' });
    };

    selectedLines = () => {
      const { doc, selection } = this.view.state;
      const lines = new Map();
      for (const range of selection.ranges) {
        for (let pos = range.from; pos <= range.to;) { const line = doc.lineAt(pos); lines.set(line.number, line); pos = line.to + 1; }
      }
      return [...lines.values()].sort((a, b) => a.number - b.number);
    };

    setHeading = (level) => {
      const changes = this.selectedLines().map(line => {
        const existing = /^#{1,6}[ \t]+|^#{1,6}$/.exec(line.text)?.[0].length ?? 0;
        return { from: line.from, to: line.from + existing, insert: level ? `${'#'.repeat(level)} ` : '' };
      });
      this.view.dispatch({ changes, userEvent: 'input.format' });
    };

    toggleList = (kind) => {
      const lines = this.selectedLines();
      const { test, prefix } = this.listKinds[kind];
      const removing = lines.every(line => test.test(line.text));
      const changes = lines.map((line, index) => {
        const [whole, indent] = this.listPrefix.exec(line.text);
        return { from: line.from + indent.length, to: line.from + whole.length, insert: removing ? '' : prefix(index) };
      });
      this.view.dispatch({ changes, userEvent: 'input.format' });
    };

    toggleQuote = () => {
      const lines = this.selectedLines();
      const removing = lines.every(line => /^>/.test(line.text));
      const changes = lines.map(line => removing ? { from: line.from, to: line.from + (/^> ?/.exec(line.text)[0].length) } : { from: line.from, insert: '> ' });
      this.view.dispatch({ changes, userEvent: 'input.format' });
    };

    insertBlock = (text, cursorOffset) => {
      const line = this.view.state.doc.lineAt(this.view.state.selection.main.head);
      const blank = !line.text.trim();
      const lead = blank ? '' : '\n\n';
      const from = blank ? line.from : line.to;
      this.view.dispatch({ changes: { from, to: line.to, insert: lead + text }, selection: { anchor: from + lead.length + cursorOffset }, userEvent: 'input.format' });
    };

    codeBlock = () => {
      const lines = this.selectedLines();
      const { from, to } = this.view.state.selection.main;
      if (from === to && !lines[0].text.trim()) { this.insertBlock('```\n\n```', 4); return; }
      const first = lines[0], last = lines[lines.length - 1];
      this.view.dispatch({ changes: [{ from: first.from, insert: '```\n' }, { from: last.to, insert: '\n```' }], userEvent: 'input.format' });
    };

    format = (kind) => {
      this.closeMenus();
      if (kind === 'link' || kind === 'image') { this.insertDialog(kind); return; }
      if (/^h[1-6]$/.test(kind)) this.setHeading(+kind[1]);
      else if (kind === 'paragraph') this.setHeading(0);
      else if (kind === 'bold') this.wrapSelection('**');
      else if (kind === 'italic') this.wrapSelection('*');
      else if (kind === 'strike') this.wrapSelection('~~');
      else if (kind === 'code') this.wrapSelection('`');
      else if (kind in this.listKinds) this.toggleList(kind);
      else if (kind === 'blockquote') this.toggleQuote();
      else if (kind === 'codeBlock') this.codeBlock();
      else if (kind === 'table') this.insertBlock('| Column | Column | Column |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |', 2);
      this.view.focus();
    };
  }
  window.MarginEditorFormatting = options => new EditorFormatting(options);
})();
