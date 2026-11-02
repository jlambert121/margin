/* Inline syntax decorations use the transaction's shared context. */
(() => {
  'use strict';
  const { Decoration } = MarginEditor;
  function decorateEmphasis(node, context) {
    const { name, from, to } = node;
    const { touches, hide, mark, children } = context;
    mark({ Emphasis: 'cm-md-em', StrongEmphasis: 'cm-md-strong', Strikethrough: 'cm-md-strike' }[name], from, to);
    if (!touches(from, to)) for (const marker of children(node, name === 'Strikethrough' ? 'StrikethroughMark' : 'EmphasisMark')) hide(marker.from, marker.to);
  }

  function decorateInlineCode(node, context) {
    const { from, to } = node;
    const { touches, hide, mark, children } = context;
    mark('cm-md-code', from, to);
    if (!touches(from, to)) for (const marker of children(node, 'CodeMark')) hide(marker.from, marker.to);
    return false;
  }

  function decorateLink(node, context) {
    const { from, to } = node;
    const { touches, hide, mark, children } = context;
    const marks = children(node, 'LinkMark');
    if (marks.length < 2) return;
    if (touches(from, to)) mark('cm-md-link-source', from, to);
    else { hide(from, marks[0].to); hide(marks[1].from, to); mark('cm-md-link', marks[0].to, marks[1].from); }
  }

  function decorateImage(node, context) {
    const { from, to } = node;
    const { doc, touches, add, mark, children } = context;
    const url = children(node, 'URL')[0];
    const marks = children(node, 'LinkMark');
    if (!url || marks.length < 2) return false;
    const widget = new context.widgets.ImageWidget(doc.sliceString(url.from, url.to).replace(/^<|>$/g, ''), doc.sliceString(marks[0].to, marks[1].from));
    if (touches(from, to)) { mark('cm-md-link-source', from, to); add(Decoration.widget({ widget, side: 1 }), to); }
    else add(Decoration.replace({ widget }), from, to);
    return false;
  }

  function decorateAutolink(node, context) {
    const { from, to } = node;
    const { touches, hide, mark, children } = context;
    mark('cm-md-link', from, to);
    if (!touches(from, to)) for (const marker of children(node, 'LinkMark')) hide(marker.from, marker.to);
    return false;
  }

  function decorateURL(node, context) {
    const { from, to } = node;
    const { mark } = context;
    if (node.node.parent?.name !== 'Link') mark('cm-md-link', from, to);
    return false;
  }

  function decorateEscape(node, context) {
    const { from, to } = node;
    const { touches, hide } = context;
    if (!touches(from, to)) hide(from, from + 1);
    return false;
  }

  function decorateHTMLTag(node, context) {
    const { from, to } = node;
    const { mark } = context;
    mark('cm-md-html', from, to);
    return false;
  }

  window.MarginPreviewInline = { decorateEmphasis, decorateInlineCode, decorateLink, decorateImage, decorateAutolink, decorateURL, decorateEscape, decorateHTMLTag };
})();
