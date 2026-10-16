/* Markdown to sanitized HTML for export, printing, statistics, and table previews. */
(() => {
  'use strict';
  const { MarkdownIt, DOMPurify } = MarginEditor;
  // GFM task items: markdown-it parses "[ ] text" in a list item as plain text.
  function taskLists(md) {
    md.core.ruler.after('inline', 'task-lists', state => {
      const tokens = state.tokens;
      for (let i = 2; i < tokens.length; i++) {
        const inline = tokens[i];
        if (inline.type !== 'inline' || tokens[i - 1].type !== 'paragraph_open' || tokens[i - 2].type !== 'list_item_open') continue;
        const match = /^\[([ xX])\][ \t]/.exec(inline.content);
        const first = inline.children[0];
        if (!match || first?.type !== 'text' || !first.content.startsWith(match[0])) continue;
        first.content = first.content.slice(match[0].length);
        const box = new state.Token('html_inline', '', 0);
        box.content = `<input type="checkbox" disabled${match[1] === ' ' ? '' : ' checked'}> `;
        inline.children.unshift(box);
        tokens[i - 2].attrJoin('class', 'task-list-item');
      }
    });
  }
  const renderer = html => new MarkdownIt({ html, linkify: true }).use(taskLists);
  const documentRenderer = renderer(true);
  const fragmentRenderer = renderer(false);
  window.MarginMarkdown = {
    renderDocument: text => DOMPurify.sanitize(documentRenderer.render(text)),
    renderFragment: text => DOMPurify.sanitize(fragmentRenderer.render(text)),
    renderInline: text => DOMPurify.sanitize(fragmentRenderer.renderInline(text)),
  };
})();
