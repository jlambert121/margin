/* editor search: the app's find bar drives CodeMirror's search query and commands. */
(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const { EditorView, SearchQuery, setSearchQuery, findNext, findPrevious, replaceNext, replaceAll: replaceAllMatches } = MarginEditor;
  class EditorSearch {
    constructor({ view, revealPosition }) {
      this.view = view;
      this.revealPosition = revealPosition;
      this.useRegex = () => $('#find-regex').getAttribute('aria-pressed') === 'true';
      $('#find-input').oninput = this.findFirst;
      $('#find-input').onkeydown = event => { if (event.key === 'Enter') { event.preventDefault(); this.find(event.shiftKey ? -1 : 1); } };
      $('#find-regex').onclick = () => { $('#find-regex').setAttribute('aria-pressed', String(!this.useRegex())); this.findFirst(); $('#find-input').focus(); };
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

    // Literal, so a typed \n or \t stays as typed rather than becoming a newline or tab.
    query = () => {
      const query = new SearchQuery({ search: $('#find-input').value, replace: $('#replace-input').value, regexp: this.useRegex(), literal: true });
      this.view.dispatch({ effects: setSearchQuery.of(query) });
      return query;
    };

    matches = query => [...query.getCursor(this.view.state)];

    report = (query) => {
      if (!query.valid) { $('#find-result').textContent = query.search ? 'Invalid pattern' : ''; return; }
      const { from, to } = this.view.state.selection.main;
      const matches = this.matches(query);
      const index = matches.findIndex(match => match.from === from && match.to === to);
      $('#find-result').textContent = !matches.length ? 'No matches' : index < 0 ? `${matches.length.toLocaleString()} matches` : `${index + 1} of ${matches.length}`;
    };

    // A changed query starts again from the top of the document.
    findFirst = () => {
      const query = this.query();
      const first = query.valid ? query.getCursor(this.view.state).next() : { done: true };
      if (!first.done) {
        const { from, to } = first.value;
        this.view.dispatch({ selection: { anchor: from, head: to }, effects: EditorView.scrollIntoView(from, { y: 'center' }) });
      }
      this.report(query);
    };

    find = (direction = 1) => {
      const query = this.query();
      if (query.valid) (direction < 0 ? findPrevious : findNext)(this.view);
      this.report(query);
    };

    replaceOne = () => {
      const query = this.query();
      if (!query.valid) return;
      replaceNext(this.view);
      this.report(query);
    };

    replaceAll = () => {
      const query = this.query();
      if (!query.valid) return;
      const count = this.matches(query).length;
      if (replaceAllMatches(this.view)) $('#find-result').textContent = `Replaced ${count.toLocaleString()}`;
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
