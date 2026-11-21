/* editor input: one instance owns this feature's state. */
(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const { EditorView, EditorSelection, syntaxTree } = MarginEditor;
  class EditorInput {
    constructor({ getView, post, headings, revealPosition }) {
      this.getView = getView;
      this.post = post;
      this.headings = headings;
      this.revealPosition = revealPosition;
      this.wrapSelectionMarkers = EditorView.inputHandler.of((view, from, to, text) => {
        if (!['*', '_', '~'].includes(text) || view.state.selection.ranges.every(range => range.empty)) return false;
        view.dispatch(view.state.changeByRange(range => range.empty
        ? { changes: { from: range.from, insert: text }, range: EditorSelection.cursor(range.from + 1) }
        : { changes: [{ from: range.from, insert: text }, { from: range.to, insert: text }], range: EditorSelection.range(range.anchor + 1, range.head + 1) }), { userEvent: 'input.type' });
        return true;
      });
      this.imageFiles = list => [...(list ?? [])].filter(file => file.type.startsWith('image/'));
      this.handlers = EditorView.domEventHandlers({ paste: this.paste, drop: this.drop, contextmenu: this.contextmenu, mousedown: this.mousedown });
    }

    paste = (event, view) => {
      const files = this.imageFiles(event.clipboardData?.files);
      if (files.length) { event.preventDefault(); this.insertImages(files, view.state.selection.main.from); return true; }
      // Code keeps the plain text.
      const at = syntaxTree(view.state).resolve(view.state.selection.main.from, -1);
      for (let node = at; node; node = node.parent) if (['FencedCode', 'CodeBlock', 'InlineCode', 'Frontmatter'].includes(node.name)) return false;
      const markdown = MarginMarkdown.fromHTML(event.clipboardData?.getData('text/html'), event.clipboardData?.getData('text/plain'));
      if (markdown === null) return false;
      event.preventDefault();
      this.insertText(markdown);
      return true;
    };

    drop = (event, view) => {
      const files = this.imageFiles(event.dataTransfer?.files);
      if (!files.length) return false;
      event.preventDefault();
      this.insertImages(files, view.posAtCoords({ x: event.clientX, y: event.clientY }) ?? view.state.selection.main.from);
      return true;
    };

    contextmenu = (event, view) => {
      const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
      const code = pos === null ? null : MarginCodeCopy.textAt(view.state, pos);
      if (pos !== null) {
        const line = view.state.doc.lineAt(pos);
        const around = line.text.slice(Math.max(0, pos - line.from - 1), pos - line.from + 1);
        const inSelection = view.state.selection.ranges.some(range => range.from <= pos && range.to >= pos && /\S/.test(view.state.sliceDoc(range.from, range.to)));
        if (!inSelection && !/\S/.test(around)) view.dispatch({ selection: { anchor: pos } });
      }
      // The app adds the document's commands to the menu that follows.
      this.post('contextMenu', code === null ? {} : { code });
      return false;
    };

    mousedown = (event, view) => {
      if (!(event.metaKey || event.ctrlKey)) return false;
      const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
      const href = pos == null ? null : this.linkTarget(pos);
      if (!href) return false;
      event.preventDefault();
      if (href.startsWith('#')) {
        const heading = this.headings().find(h => h.text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-') === href.slice(1));
        if (heading) this.revealPosition(heading.pos, 'start');
      } else this.post('openExternal', { url: href });
      return true;
    };

    readImages = (files) => {
      return Promise.all(files.map(file => new Promise(resolve => {
        const reader = new FileReader();
        reader.onload = () => resolve(`![${(file.name || 'Image').replace(/[[\]]/g, '')}](${reader.result})`);
        reader.onerror = () => resolve('');
        reader.readAsDataURL(file);
      })));
    };

    insertImages = (files, pos) => {
      const view = this.getView();
      this.readImages(files).then(images => {
        const text = images.filter(Boolean).join('\n');
        if (text) view.dispatch({ changes: { from: pos, insert: text }, selection: { anchor: pos + text.length }, userEvent: 'input.paste' });
      });
    };

    linkTarget = (pos) => {
      const view = this.getView();
      for (let node = syntaxTree(view.state).resolve(pos, 1); node; node = node.parent) {
        if (node.name === 'Link') { const url = node.getChild('URL'); return url ? view.state.sliceDoc(url.from, url.to).replace(/^<|>$/g, '') : null; }
        if (node.name === 'URL') return view.state.sliceDoc(node.from, node.to);
        if (node.name === 'Autolink') return view.state.sliceDoc(node.from + 1, node.to - 1);
      }
      return null;
    };

    insertText = (text) => {
      const view = this.getView();
      view.dispatch(view.state.replaceSelection(text), { userEvent: 'input.paste', scrollIntoView: true });
    };

    pastePlain = (text) => {
      const view = this.getView();
      const field = document.activeElement;
      if (field?.matches?.('input, textarea, [contenteditable]') && !view.contentDOM.contains(field)) document.execCommand('insertText', false, text);
      else { this.insertText(text); view.focus(); }
    };
  }
  window.MarginEditorInput = options => new EditorInput(options);
})();
