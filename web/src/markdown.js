/* Markdown to sanitized HTML for export, printing, statistics, and table previews,
   and pasted HTML to Markdown. */
(() => {
  'use strict';
  const { MarkdownIt, DOMPurify, TurndownService, turndownGfm } = MarginEditor;
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
  // YAML front matter: "---" on the first line, a "key:" line after it, and a closing
  // "---" or "..." line, or the end of the document. The editor's parser uses the same rule.
  const frontmatter = { open: /^---\s*$/, key: /^[^\s:#][^:]*:(?:\s|$)/, close: /^(?:---|\.\.\.)\s*$/ };
  // Front matter is metadata, so it is left out of rendered output and statistics.
  function withoutFrontmatter(text) {
    const lines = text.split('\n');
    if (!frontmatter.open.test(lines[0]) || !frontmatter.key.test(lines[1] ?? '')) return text;
    const close = lines.findIndex((line, index) => index > 1 && frontmatter.close.test(line));
    return close === -1 ? '' : lines.slice(close + 1).join('\n');
  }
  const renderer = html => new MarkdownIt({ html, linkify: true }).use(taskLists);
  const documentRenderer = renderer(true);
  const fragmentRenderer = renderer(false);
  const turndown = new TurndownService({ headingStyle: 'atx', codeBlockStyle: 'fenced', bulletListMarker: '-', emDelimiter: '*', hr: '---' });
  turndown.use(turndownGfm);
  turndown.remove(['script', 'style', 'noscript', 'template', 'title']);
  // One space after the marker, as the editor's own list commands write.
  turndown.addRule('listItem', {
    filter: 'li',
    replacement(content, node) {
      const parent = node.parentNode;
      const start = Number(parent.getAttribute('start') || 1);
      const prefix = parent.nodeName === 'OL' ? `${start + [...parent.children].indexOf(node)}. ` : '- ';
      const paragraph = /\n$/.test(content);
      const body = content.replace(/^\n+|\n+$/g, '') + (paragraph ? '\n' : '');
      return prefix + body.replace(/\n/g, `\n${' '.repeat(prefix.length)}`) + (node.nextSibling ? '\n' : '');
    },
  });
  // Google Docs wraps a paste in a <b> that is not bold, and marks emphasis with styles.
  const style = node => node.getAttribute?.('style') || '';
  turndown.addRule('notBold', {
    filter: node => ['B', 'STRONG'].includes(node.nodeName) && /font-weight:\s*(normal|[1-4]00)\b/.test(style(node)),
    replacement: content => content,
  });
  turndown.addRule('styledEmphasis', {
    filter: node => node.nodeName === 'SPAN' && /font-weight:\s*(bold|[6-9]00)\b|font-style:\s*italic/.test(style(node)),
    replacement(content, node) {
      const marker = (/font-weight:\s*(bold|[6-9]00)\b/.test(style(node)) ? '**' : '') + (/font-style:\s*italic/.test(style(node)) ? '*' : '');
      const [, lead, text, trail] = /^(\s*)([\s\S]*?)(\s*)$/.exec(content);
      return text ? `${lead}${marker}${text}${marker}${trail}` : content;
    },
  });
  // Pasted HTML becomes Markdown only when it has structure. Code editors put styled
  // spans on the clipboard beside the code, and converting those would escape it.
  const structure = 'h1,h2,h3,h4,h5,h6,ul,ol,a[href],strong,b,em,i,code,table,pre,blockquote,img,hr,del,s';
  function fromHTML(html, plain = '') {
    if (!html || /^\s*\S+:\/\/\S+\s*$/.test(plain)) return null;
    const body = new DOMParser().parseFromString(html, 'text/html').body;
    if (!body.querySelector(structure)) return null;
    return turndown.turndown(body).replace(/^\n+|\n+$/g, '');
  }
  window.MarginMarkdown = {
    fromHTML,
    frontmatter,
    renderDocument: text => DOMPurify.sanitize(documentRenderer.render(withoutFrontmatter(text))),
    renderFragment: text => DOMPurify.sanitize(fragmentRenderer.render(withoutFrontmatter(text))),
    renderInline: text => DOMPurify.sanitize(fragmentRenderer.renderInline(text)),
  };
})();
