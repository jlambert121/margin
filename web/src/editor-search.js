/* editor search: one instance owns this feature's state. */
(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const { EditorView } = MarginEditor;
  class EditorSearch {
    constructor({ view, revealPosition }) {
      this.view = view;
      this.revealPosition = revealPosition;
      this.activeMatch = -1;
      this.useRegex = () => $('#find-regex').getAttribute('aria-pressed') === 'true';
      $('#find-input').oninput = () => { this.activeMatch = -1; this.find(); };
      $('#find-input').onkeydown = event => { if (event.key === 'Enter') { event.preventDefault(); this.find(event.shiftKey ? -1 : 1); } };
      $('#find-regex').onclick = () => { $('#find-regex').setAttribute('aria-pressed', String(!this.useRegex())); this.activeMatch = -1; this.find(); $('#find-input').focus(); };
      $('#replace-input').onkeydown = event => { if (event.key === 'Enter') { event.preventDefault(); this.replaceOne(); } };
      $('#replace-one').onclick = this.replaceOne;
      $('#replace-all').onclick = this.replaceAll;
      $('#goto-input').onkeydown = event => { if (event.key === 'Enter') { event.preventDefault(); this.goToLine(); } };
      $('#goto-close').onclick = () => { $('#goto-bar').hidden = true; this.view.focus(); };
      $('#cursor-position').onclick = this.showGoToLine;
      $('#find-prev').onclick = () => this.find(-1);
      $('#find-next').onclick = () => this.find(1);
      $('#find-close').onclick = () => { $('#find-bar').hidden = true; this.view.focus(); };
    }

    findPattern = () => {
      const query = $('#find-input').value;
      if (!query) return null;
      try { return new RegExp(this.useRegex() ? query : query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gimu'); } catch { return undefined; }
    };

    findMatches = (pattern) => {
      const matches = [];
      for (const match of this.view.state.doc.toString().matchAll(pattern)) if (match[0]) matches.push({ from: match.index, to: match.index + match[0].length, match });
      return matches;
    };

    find = (direction = 1, after = null) => {
      const pattern = this.findPattern();
      if (!pattern) { $('#find-result').textContent = pattern === null ? '' : 'Invalid pattern'; return; }
      const matches = this.findMatches(pattern);
      if (!matches.length) { $('#find-result').textContent = 'No matches'; return; }
      if (after === null) this.activeMatch = (this.activeMatch + direction + matches.length) % matches.length;
      else this.activeMatch = Math.max(0, matches.findIndex(match => match.from >= after));
      const { from, to } = matches[this.activeMatch];
      this.view.dispatch({ selection: { anchor: from, head: to }, effects: EditorView.scrollIntoView(from, { y: 'center' }) });
      $('#find-result').textContent = `${this.activeMatch + 1} of ${matches.length}`;
    };

    replacementFor = (text, { match }) => {
      const replacement = $('#replace-input').value;
      if (!this.useRegex()) return replacement;
      return replacement.replace(/\$(?:([$&`'])|(\d\d?)|<([^>]*)>)/g, (token, symbol, digits, name) => {
        if (symbol === '$') return '$';
        if (symbol === '&') return match[0];
        if (symbol === '`') return text.slice(0, match.index);
        if (symbol === "'") return text.slice(match.index + match[0].length);
        if (name !== undefined) return match.groups ? match.groups[name] ?? '' : token;
        if (digits.length === 2 && +digits > 0 && +digits < match.length) return match[+digits] ?? '';
        return +digits[0] > 0 && +digits[0] < match.length ? (match[+digits[0]] ?? '') + digits.slice(1) : token;
      });
    };

    replaceOne = () => {
      const pattern = this.findPattern();
      if (!pattern) return;
      const { from, to } = this.view.state.selection.main;
      const current = this.findMatches(pattern).find(match => match.from === from && match.to === to);
      if (!current) { this.find(1, from); return; }
      const insert = this.replacementFor(this.view.state.doc.toString(), current);
      this.view.dispatch({ changes: { from, to, insert }, selection: { anchor: from + insert.length }, userEvent: 'input.replace' });
      this.find(1, from + insert.length);
    };

    replaceAll = () => {
      const pattern = this.findPattern();
      if (!pattern) return;
      const text = this.view.state.doc.toString();
      const matches = this.findMatches(pattern);
      if (!matches.length) return;
      this.view.dispatch({ changes: matches.map(match => ({ from: match.from, to: match.to, insert: this.replacementFor(text, match) })), userEvent: 'input.replace.all' });
      this.activeMatch = -1;
      $('#find-result').textContent = `Replaced ${matches.length.toLocaleString()}`;
    };

    showFind = (replacing = false) => {
      $('#goto-bar').hidden = true;
      $('#find-bar').hidden = false;
      $('#find-bar').classList.toggle('replacing', replacing);
      const input = replacing && $('#find-input').value ? $('#replace-input') : $('#find-input');
      input.focus(); input.select();
    };

    showGoToLine = () => {
      $('#find-bar').hidden = true;
      $('#goto-bar').hidden = false;
      $('#goto-input').placeholder = `Go to line (1–${this.view.state.doc.lines.toLocaleString()}), or line:column`;
      $('#goto-result').textContent = '';
      $('#goto-input').focus(); $('#goto-input').select();
    };

    goToLine = () => {
      const match = /^\s*(\d+)\s*(?:[:,]\s*(\d+))?\s*$/.exec($('#goto-input').value);
      if (!match) { $('#goto-result').textContent = 'Enter a line number'; return; }
      const doc = this.view.state.doc;
      const line = doc.line(Math.min(Math.max(+match[1], 1), doc.lines));
      const column = Math.min(Math.max(+(match[2] ?? 1), 1), line.length + 1);
      $('#goto-bar').hidden = true;
      this.revealPosition(line.from + column - 1);
    };
  }
  window.MarginEditorSearch = options => new EditorSearch(options);
})();
