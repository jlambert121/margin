/* Live preview: the document stays Markdown text. Formatting renders through
   CodeMirror decorations over the Markdown syntax tree, and syntax markers are
   hidden except where the selection touches them, where they are ordinary
   editable text. */
(() => {
  'use strict';
  const { EditorView, Decoration, StateField, StateEffect, syntaxTree, ensureSyntaxTree } = MarginEditor;

  // Nothing counts as being edited while the editor is unfocused, so a document
  // renders fully until the writer clicks into it.
  const setFocused = StateEffect.define();
  const focused = StateField.define({
    create: () => false,
    update(value, tr) {
      for (const effect of tr.effects) if (effect.is(setFocused)) value = effect.value;
      return value;
    },
  });
  const trackFocus = EditorView.focusChangeEffect.of((_, focusing) => setFocused.of(focusing));

  // While the mouse button is down, syntax stays shown or hidden as it was when the press
  // began. Revealing the clicked line's markers mid-click moves its text, and CodeMirror
  // reads the pointer again on any movement, so a click would select instead of placing
  // the cursor. The layout catches up once the button is released.
  const setPressed = StateEffect.define();
  const pressed = StateField.define({
    create: () => null,
    update(value, tr) {
      for (const effect of tr.effects) {
        if (effect.is(setPressed)) value = effect.value;
        else if (effect.is(setFocused) && !effect.value) value = null;
      }
      return value;
    },
  });
  const holdLayoutWhilePressed = EditorView.domEventHandlers({
    mousedown(event, view) {
      if (event.button !== 0) return false;
      view.dispatch({ effects: setPressed.of({ focused: view.state.field(focused), ranges: view.state.selection.ranges }) });
      // After CodeMirror's own mouseup handling, which can still read the pointer.
      const release = () => setTimeout(() => { if (view.state.field(pressed)) view.dispatch({ effects: setPressed.of(null) }); });
      view.contentDOM.ownerDocument.addEventListener('mouseup', release, { once: true });
      return false;
    },
  });

  const widgets = MarginPreviewWidgets();
  const { decorateEmphasis, decorateInlineCode, decorateLink, decorateImage, decorateAutolink, decorateURL, decorateEscape, decorateHTMLTag } = MarginPreviewInline;
  const { decorateBlockquote, decorateQuoteMark, decorateListItem, decorateParagraph, decorateListMark, decorateTaskMarker } = MarginPreviewLists;
  const { decorateHeading, decorateHorizontalRule, decorateFencedCode, decorateFrontmatter, decorateCodeBlock, decorateTable } = MarginPreviewBlocks;

  // A false return skips child nodes whose syntax is already handled by the parent.
  const nodeDecorators = {
    Emphasis: decorateEmphasis,
    StrongEmphasis: decorateEmphasis,
    Strikethrough: decorateEmphasis,
    InlineCode: decorateInlineCode,
    Link: decorateLink,
    Image: decorateImage,
    Autolink: decorateAutolink,
    URL: decorateURL,
    Blockquote: decorateBlockquote,
    QuoteMark: decorateQuoteMark,
    ListItem: decorateListItem,
    Paragraph: decorateParagraph,
    ListMark: decorateListMark,
    TaskMarker: decorateTaskMarker,
    HorizontalRule: decorateHorizontalRule,
    FencedCode: decorateFencedCode,
    Frontmatter: decorateFrontmatter,
    CodeBlock: decorateCodeBlock,
    Table: decorateTable,
    Escape: decorateEscape,
    HTMLTag: decorateHTMLTag,
    HTMLBlock: decorateHTMLTag,
    Comment: decorateHTMLTag,
    CommentBlock: decorateHTMLTag,
  };

  function decorate(state) {
    const doc = state.doc;
    const tree = ensureSyntaxTree(state, doc.length, 200) ?? syntaxTree(state);
    const held = state.field(pressed);
    const ranges = (held ? held.focused : state.field(focused)) ? (held ? held.ranges : state.selection.ranges) : [];
    const touches = (from, to) => ranges.some(range => range.from <= to && range.to >= from);
    const lineTouched = pos => { const line = doc.lineAt(pos); return touches(line.from, line.to); };
    const decorations = [];
    const add = (decoration, from, to = from) => decorations.push(decoration.range(from, to));
    const hide = (from, to) => { if (to > from) add(Decoration.replace({}), from, to); };
    const hideWithSpace = (from, to) => hide(from, doc.sliceString(to, to + 1) === ' ' ? to + 1 : to);
    const mark = (cls, from, to) => { if (to > from) add(Decoration.mark({ class: cls }), from, to); };
    const lineClass = (cls, pos) => add(Decoration.line({ class: cls }), doc.lineAt(pos).from);
    const eachLine = (from, to, fn) => { for (let pos = from; pos <= to;) { const line = doc.lineAt(pos); fn(line); pos = line.to + 1; } };
    const children = (node, name) => node.node.getChildren(name);
    const spaceAfter = to => doc.sliceString(to, to + 1) === ' ' ? to + 1 : to;
    // List lines indent by nesting depth instead of their source spaces, which are
    // hidden like other syntax. Keyed by line start; quoted lists keep the quote's layout.
    const listLines = new Map();

    const context = { state, doc, touches, lineTouched, add, hide, hideWithSpace, mark, lineClass, eachLine, children, spaceAfter, listLines, widgets };
    tree.iterate({ enter(node) {
      const heading = /^(ATX|Setext)Heading(\d)$/.exec(node.name);
      if (heading) return decorateHeading(node, context, heading);
      return nodeDecorators[node.name]?.(node, context);
    } });
    for (const [pos, { depth, first }] of listLines) {
      add(Decoration.line({ class: first ? 'cm-md-list-line' : 'cm-md-list-line cm-md-list-continuation', attributes: { style: `--list-depth:${depth - 1}` } }), pos);
    }
    return Decoration.set(decorations, true);
  }

  // Block widgets such as tables have to come from a state field, not a view plugin.
  const decorations = StateField.define({
    create: decorate,
    update(value, tr) {
      return tr.docChanged || tr.selection || tr.effects.length || syntaxTree(tr.state) !== syntaxTree(tr.startState) ? decorate(tr.state) : value;
    },
    provide: field => EditorView.decorations.from(field),
  });

  // setFocused is exported so tests without a focusable window can simulate focus.
  window.MarginLivePreview = { extension: [focused, trackFocus, pressed, holdLayoutWhilePressed, MarginTables.sourceTables, decorations], setFocused };
})();
