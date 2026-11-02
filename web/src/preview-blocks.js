/* Blocks syntax decorations use the transaction's shared context. */
(() => {
  'use strict';
  const { Decoration } = MarginEditor;
  function decorateHeading(node, context, heading) {
    const { from, to } = node;
    const { doc, touches, lineTouched, hide, hideWithSpace, lineClass, eachLine, children } = context;
    const level = heading[2];
    const marks = children(node, 'HeaderMark');
    const headingClass = `cm-md-heading cm-md-h${level}`;
    if (heading[1] === 'Setext') {
      const underline = doc.lineAt(to);
      eachLine(from, underline.from - 1, line => lineClass(headingClass, line.from));
      if (touches(from, to)) return;
      lineClass('cm-md-setext-underline', underline.from);
      for (const headerMark of marks) hide(headerMark.from, headerMark.to);
      return;
    }
    lineClass(headingClass, from);
    if (lineTouched(from)) return;
    for (const headerMark of marks) {
      if (headerMark.from === doc.lineAt(from).from) {
        hideWithSpace(headerMark.from, headerMark.to);
      } else {
        const precedingSpace = doc.sliceString(headerMark.from - 1, headerMark.from) === ' ';
        hide(precedingSpace ? headerMark.from - 1 : headerMark.from, headerMark.to);
      }
    }
  }

  function decorateHorizontalRule(node, context) {
    const { from, to } = node;
    const { lineTouched, add } = context;
    if (!lineTouched(from)) add(Decoration.replace({ widget: context.widgets.rule }), from, to);
    return false;
  }

  function decorateFencedCode(node, context) {
    const { FenceLabelWidget, DiagramWidget } = context.widgets;
    const { from, to } = node;
    const { doc, touches, add, hide, lineClass, eachLine, children } = context;
    const first = doc.lineAt(from), last = doc.lineAt(to);
    const info = children(node, 'CodeInfo')[0];
    let label = info ? doc.sliceString(info.from, info.to) : '';
    const closed = last.number > first.number && /^\s*(```|~~~)/.test(last.text);
    if (closed && !touches(from, to) && MarginMarkdown.isMermaid(label)) {
      const code = children(node, 'CodeText')[0];
      const diagram = MarginMarkdown.renderDiagram(code ? doc.sliceString(code.from, code.to) : '', { links: false });
      if (diagram.svg) { add(Decoration.replace({ widget: new DiagramWidget(diagram.svg), block: true }), first.from, last.to); return false; }
      label = `${label} · ${diagram.error}`;
    }
    eachLine(from, to, line => lineClass('cm-md-codeblock', line.from));
    lineClass('cm-md-codeblock-first', first.from);
    lineClass('cm-md-codeblock-last', last.from);
    if (!touches(from, to)) {
      add(Decoration.replace(label ? { widget: new FenceLabelWidget(label) } : {}), first.from, first.to);
      if (closed) { hide(last.from, last.to); lineClass('cm-md-fence-hidden', last.from); }
      if (!label) lineClass('cm-md-fence-hidden', first.from);
    }
    return false;
  }

  function decorateFrontmatter(node, context) {
    const { FenceLabelWidget } = context.widgets;
    const { from, to } = node;
    const { doc, touches, add, hide, lineClass, eachLine, children } = context;
    const first = doc.lineAt(from), last = doc.lineAt(to);
    eachLine(from, to, line => lineClass('cm-md-codeblock cm-md-frontmatter', line.from));
    lineClass('cm-md-codeblock-first', first.from);
    lineClass('cm-md-codeblock-last', last.from);
    if (!touches(from, to)) {
      add(Decoration.replace({ widget: new FenceLabelWidget('front matter') }), first.from, first.to);
      if (children(node, 'FrontmatterMark').length > 1) { hide(last.from, last.to); lineClass('cm-md-fence-hidden', last.from); }
    }
    return false;
  }

  function decorateCodeBlock(node, context) {
    const { from, to } = node;
    const { lineClass, eachLine } = context;
    eachLine(from, to, line => lineClass('cm-md-codeblock cm-md-indented-code', line.from));
    return false;
  }

  function decorateTable(node, context) {
    const { from, to } = node;
    const { state, doc, add, lineClass, eachLine } = context;
    const first = doc.lineAt(from), last = doc.lineAt(to);
    if (state.field(MarginTables.sourceTables).includes(first.from)) eachLine(from, to, line => lineClass('cm-md-table-source', line.from));
    else add(Decoration.replace({ widget: new MarginTables.TableWidget(doc.sliceString(first.from, last.to)), block: true }), first.from, last.to);
    return false;
  }

  window.MarginPreviewBlocks = { decorateHeading, decorateHorizontalRule, decorateFencedCode, decorateFrontmatter, decorateCodeBlock, decorateTable };
})();
