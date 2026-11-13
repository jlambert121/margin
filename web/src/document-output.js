/* document output: one instance owns this feature's state. */
(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const { EditorView, syntaxTree, ensureSyntaxTree } = MarginEditor;
  class DocumentOutput {
    constructor({ view, post, getText }) {
      this.view = view;
      this.post = post;
      this.getText = getText;
      this.refreshTimer = undefined;
      this.sentOutline = "";
    }

    updateCursorPosition = (state) => {
      const head = state.selection.main.head, line = state.doc.lineAt(head);
      $('#cursor-position').textContent = `Ln ${line.number.toLocaleString()}, Col ${(head - line.from + 1).toLocaleString()}`;
    };

    refresh = () => {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = setTimeout(() => {
        const words = MarginMarkdown.plainText(this.getText()).trim().split(/\s+/u).filter(Boolean).length;
        $('#word-count').textContent = `${words.toLocaleString()} ${words === 1 ? 'word' : 'words'}`;
        $('#word-count').title = `${this.getText().length.toLocaleString()} characters · ${this.getText().split('\n').length.toLocaleString()} lines`;
        $('#reading-time').textContent = `${Math.max(1, Math.ceil(words / 225))} min read`;
        this.postOutline();
      }, 80);
    };

    headings = () => {
      const state = this.view.state;
      const tree = ensureSyntaxTree(state, state.doc.length, 100) ?? syntaxTree(state);
      const result = [];
      tree.iterate({ enter(node) {
          // Fenced code is parsed in its own language, which may itself be Markdown.
          if (['FencedCode', 'CodeBlock', 'Frontmatter'].includes(node.name)) return false;
          const match = /^(?:ATX|Setext)Heading(\d)$/.exec(node.name);
          if (!match) return;
          const firstLine = state.doc.lineAt(node.from);
          const text = (node.name.startsWith('ATX') ? firstLine.text.replace(/^\s*#{1,6}\s*/, '').replace(/\s+#+\s*$/, '') : state.sliceDoc(node.from, state.doc.lineAt(node.to).from).trim()).trim();
          if (text) result.push({ level: +match[1], text, pos: node.from });
          return false;
        } });
      return result;
    };

    revealPosition = (pos, y = 'center') => {
      this.view.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y, yMargin: 40 }) });
      this.view.focus();
    };

    postOutline = () => {
      const outline = JSON.stringify(this.headings());
      if (outline === this.sentOutline) return;
      this.sentOutline = outline;
      this.post('outline', { headings: JSON.parse(outline) });
    };

    exportHTML = () => {
      return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Markdown document</title><style>body{max-width:760px;margin:60px auto;padding:0 30px;color:#303633;font:17px/1.8 Georgia,serif}h1,h2,h3{font-family:system-ui;line-height:1.3}pre,code{background:#f5f6f3;border-radius:4px}pre{padding:20px;overflow:auto}code{font:13px/1.7 monospace}blockquote{border-left:3px solid #a0b39a;margin-left:0;padding-left:20px;color:#777}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:8px}img{max-width:100%}a{color:#537460}.task-list-item{list-style:none}.mermaid-diagram{margin:1.5em 0;text-align:center}.mermaid-diagram svg{max-width:100%;height:auto}.pele{--pele-fg:#303633;--pele-muted:#92968f;--pele-line:#303633;--pele-surface:#f5f6f3;--pele-surface-alt:#edeee9;--pele-border:#92968f;--pele-accent:#537460}</style></head><body>' + MarginMarkdown.renderDocument(this.getText()) + '</body></html>';
    };

    preparePrint = () => { $('#print-view').innerHTML = MarginMarkdown.renderDocument(this.getText()); };
  }
  window.MarginDocumentOutput = options => new DocumentOutput(options);
})();
