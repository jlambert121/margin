/* App shortcuts. */
(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  class AppShortcuts {
    constructor({ view, native, post, format, command, closeMenus }) {
      this.view = view; this.native = native; this.post = post;
      this.format = format; this.command = command; this.closeMenus = closeMenus;
      document.addEventListener('keydown', this.keydown, true);
    }
    documentShortcut = (event, key) => {
      const { view, native, post, format } = this;
      if (!view.contentDOM.contains(event.target)) return false;
      if (native && (key === 'z' || (key === 'y' && !event.shiftKey))) post(key === 'y' || event.shiftKey ? 'redo' : 'undo');
      else if (key === 'b' && !event.shiftKey) format('bold');
      else if (key === 'i' && !event.shiftKey) format('italic');
      else if (key === 'k' && !event.shiftKey) format('link');
      else return false;
      return true;
    };
    globalShortcut = (event, key) => {
      const { post, format, command } = this;
      let handled = true;
      if (key === '/') command('source');
      else if (key === 'f' && !event.shiftKey) command('find');
      else if (key === 'l' && !event.shiftKey) command('goToLine');
      else if (key === 'l' && event.shiftKey) post('toggleSidebar');
      else if (event.shiftKey && (event.code === 'BracketLeft' || event.code === 'BracketRight')) post(event.code === 'BracketLeft' ? 'previousFile' : 'nextFile');
      else if (/^[1-6]$/.test(key)) format(`h${key}`);
      else if (key === 's') post(event.shiftKey ? 'saveAs' : 'save');
      else if (key === 'o') post(event.shiftKey ? 'openFolder' : 'open');
      else if (key === 'n' && !event.shiftKey) post('new');
      else handled = false;
      return handled;
    };
    keydown = event => {
    const { closeMenus } = this;
    if (event.key === 'Escape') { closeMenus(); $('#find-bar').hidden = true; $('#goto-bar').hidden = true; }
    if (!(event.metaKey || event.ctrlKey) || event.altKey) return;
    const key = event.key.toLowerCase();
    const handled = this.documentShortcut(event, key) || this.globalShortcut(event, key);
    if (handled) { event.preventDefault(); event.stopPropagation(); }
    };
  }
  window.MarginAppShortcuts = options => new AppShortcuts(options);
})();
