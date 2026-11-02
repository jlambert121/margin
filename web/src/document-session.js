/* document session: one instance owns this feature's state. */
(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const { Annotation, EditorView } = MarginEditor;
  class DocumentSession {
    constructor({ getView, refresh, setTextZoom, setTitlebar, toast }) {
      this.getView = getView;
      this.refresh = refresh;
      this.setTextZoom = setTextZoom;
      this.setTitlebar = setTitlebar;
      this.toast = toast;
      this.native = Boolean(window.webkit?.messageHandlers?.native);
      this.post = (action, payload = {}) => {
    if (this.native) window.webkit.messageHandlers.native.postMessage({ action, ...payload });
    else if (action === 'changed') sessionStorage.setItem('margin-draft', payload.text);
    else if (action === 'openExternal') window.open(payload.url, '_blank', 'noopener');
    else if (['undo', 'redo', 'outline', 'contextMenu', 'previousFile', 'nextFile'].includes(action)) return;
    else this.toast('Open the macOS app to use native file operations.');
  };
      this.welcome = '# A little room to think.\n\nWelcome to **Margin**. A quiet place for your notes, ideas, and everything in between.\n\n## Just start writing\n\nYour words take shape as you type. Use Markdown shortcuts for headings, **bold**, *italics*, and lists — the formatting appears right here on the page.\n\n> The secret of getting ahead is getting started.\n\n## Make yourself at home\n\n- Open a Markdown file with **⌘O**\n- Browse a folder with **⇧⌘O**\n- Switch to source mode with **⌘/**\n- Save your work with **⌘S**\n\n### A few things to try\n\n- [x] Find a little space to write\n- [ ] Put an idea into words\n- [ ] Make something worth keeping\n\n## For the details\n\nCode, tables, links, and images all have a place here.\n\n```swift\nlet thought = "Something worth writing down."\nprint(thought)\n```\n\n| Shortcut | A small superpower |\n| --- | --- |\n| ⌘B | A little emphasis |\n| ⌘F | Find the right words |\n\n---\n\nTake your time. The page is yours.\n';
      this.raw = this.native ? '' : sessionStorage.getItem('margin-draft') ?? this.welcome;
      this.currentPath = '';
      this.currentName = '';
      this.documentToken = null;
      this.editRevision = 0;
      this.fromApp = Annotation.define();
      this.snapshot = () => ({ text: this.raw, token: this.documentToken, revision: this.editRevision });
      this.getText = () => this.raw;
    }

    changed = (text) => {
      this.raw = text;
      this.post('changed', { text: this.raw, token: this.documentToken, revision: ++this.editRevision });
      $('#modified-dot').hidden = false;
      $('#save-status').textContent = 'Edited';
      this.refresh();
    };

    replaceText = (text, sameDocument) => {
      const view = this.getView();
      const current = view.state.doc.toString();
      if (!sameDocument) {
        view.dispatch({ changes: { from: 0, to: current.length, insert: text }, selection: { anchor: 0 }, effects: EditorView.scrollIntoView(0), annotations: this.fromApp.of(true) });
        return;
      }
      const change = this.spanChange(current, text);
      if (change) view.dispatch({ changes: change, annotations: this.fromApp.of(true) });
    };

    spanChange = (current, text) => {
      let start = 0;
      while (start < current.length && start < text.length && current[start] === text[start]) start++;
      let endCurrent = current.length, endText = text.length;
      while (endCurrent > start && endText > start && current[endCurrent - 1] === text[endText - 1]) { endCurrent--; endText--; }
      return start === endCurrent && start === endText ? null : { from: start, to: endCurrent, insert: text.slice(start, endText) };
    };

    loadDocument = (data) => {
      const name = data.name || 'Untitled.md';
      const sameDocument = name === this.currentName && (data.path || '') === this.currentPath;
      this.raw = data.text;
      this.currentPath = data.path || '';
      this.currentName = name;
      this.replaceText(this.raw, sameDocument);
      $('#document-name').textContent = name;
      $('#document-name').title = this.currentPath || 'Untitled document';
      $('#modified-dot').hidden = !data.modified;
      $('#save-status').textContent = data.modified ? 'Edited' : this.currentPath ? 'Saved locally' : 'Ready to write';
      if (typeof data.sidebarOpen === 'boolean') document.body.classList.toggle('sidebar-open', data.sidebarOpen);
      if (data.textZoom != null) this.setTextZoom(Number(data.textZoom));
      if (data.titlebar) this.setTitlebar(data.titlebar);
      this.refresh();
      this.documentToken = data.token ?? null;
      this.editRevision = 0;
      if (data.notice) this.toast(data.notice);
      if (this.native) this.post('loaded', { token: this.documentToken });
    };

    setDiskText = (text) => {
      $('#disk-banner').hidden = typeof text !== 'string';
    };

    keepMine = () => {
      this.post('diskKeepMine');
    };

    updateMetadata = (data) => {
      this.currentPath = data.path || '';
      this.currentName = data.name || 'Untitled.md';
      $('#document-name').textContent = this.currentName;
      $('#document-name').title = this.currentPath || 'Untitled document';
      $('#modified-dot').hidden = !data.modified;
      $('#save-status').textContent = data.modified ? 'Edited' : 'Saved locally';
    };
  }
  window.MarginDocumentSession = options => new DocumentSession(options);
})();
