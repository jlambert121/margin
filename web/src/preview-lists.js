/* Lists syntax decorations use the transaction's shared context. */
(() => {
  'use strict';
  const { Decoration } = MarginEditor;
  // How many lists contain a list item, counting its own.
  const listDepth = item => { let depth = 0; for (let node = item.parent; node; node = node.parent) if (node.name === 'BulletList' || node.name === 'OrderedList') depth++; return depth; };
  const inQuote = node => { for (let parent = node.parent; parent; parent = parent.parent) if (parent.name === 'Blockquote') return true; return false; };

  function decorateBlockquote(node, context) {
    const { from, to } = node;
    const { lineClass, eachLine } = context;
    eachLine(from, to, line => lineClass('cm-md-quote', line.from));
  }

  function decorateQuoteMark(node, context) {
    const { from, to } = node;
    const { lineTouched, hideWithSpace } = context;
    if (!lineTouched(from)) hideWithSpace(from, to);
  }

  function decorateListItem(node, context) {
    const { from } = node;
    const { doc, listLines } = context;
    if (!inQuote(node.node)) listLines.set(doc.lineAt(from).from, { depth: listDepth(node.node), first: true });
  }

  function decorateParagraph(node, context) {
    const { from, to } = node;
    const { doc, lineTouched, hide, eachLine, listLines } = context;
    const item = node.node.parent;
    if (item?.name !== 'ListItem' || inQuote(item)) return;
    const depth = listDepth(item), itemLine = doc.lineAt(item.from).number;
    eachLine(from, to, line => {
      if (line.number === itemLine) return;
      listLines.set(line.from, { depth, first: false });
      const lead = /^[ \t]+/.exec(line.text);
      if (lead && !lineTouched(line.from)) hide(line.from, line.from + lead[0].length);
    });
  }

  function decorateListMark(node, context) {
    const { bullets } = context.widgets;
    const { from, to } = node;
    const { doc, lineTouched, add, hide, mark, spaceAfter } = context;
    const item = node.node.parent;
    if (item?.name !== 'ListItem' || lineTouched(from)) return;
    const line = doc.lineAt(from);
    if (/^[ \t]+$/.test(doc.sliceString(line.from, from))) hide(line.from, from);
    if (item.getChild('Task')) hide(from, spaceAfter(to));
    else if (item.parent?.name === 'BulletList') add(Decoration.replace({ widget: bullets[(listDepth(item) - 1) % bullets.length] }), from, spaceAfter(to));
    else { mark('cm-md-list-number', from, to); hide(to, spaceAfter(to)); }
  }

  function decorateTaskMarker(node, context) {
    const { from, to } = node;
    const { doc, touches, add, mark, spaceAfter } = context;
    const checked = /x/i.test(doc.sliceString(from, to));
    if (checked) mark('cm-md-task-done', to, node.node.parent?.to ?? to);
    if (!touches(from, to)) add(Decoration.replace({ widget: new context.widgets.CheckboxWidget(checked) }), from, spaceAfter(to));
  }

  window.MarginPreviewLists = { decorateBlockquote, decorateQuoteMark, decorateListItem, decorateParagraph, decorateListMark, decorateTaskMarker };
})();
