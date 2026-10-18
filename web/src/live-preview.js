/* Live preview: the document stays Markdown text. Formatting renders through
   CodeMirror decorations over the Markdown syntax tree, and syntax markers are
   hidden except where the selection touches them, where they are ordinary
   editable text. */
(() => {
  'use strict';
  const { EditorView, Decoration, WidgetType, StateField, StateEffect, syntaxTree, ensureSyntaxTree } = MarginEditor;

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

  const safeImageSource = src => /^(https?:|data:image\/|markdown-asset:)/i.test(src) || !/^[a-z][a-z0-9+.-]*:/i.test(src);

  class ImageWidget extends WidgetType {
    constructor(src, alt) { super(); this.src = src; this.alt = alt; }
    eq(other) { return other.src === this.src && other.alt === this.alt; }
    toDOM(view) {
      const image = document.createElement('img');
      image.className = 'cm-md-image';
      image.alt = this.alt; image.title = this.alt;
      if (safeImageSource(this.src)) image.src = this.src;
      image.addEventListener('load', () => view.requestMeasure());
      return image;
    }
  }
  class BulletWidget extends WidgetType {
    constructor(glyph) { super(); this.glyph = glyph; }
    eq(other) { return other.glyph === this.glyph; }
    toDOM() { const bullet = document.createElement('span'); bullet.className = 'cm-md-bullet'; bullet.textContent = this.glyph; return bullet; }
  }
  class RuleWidget extends WidgetType {
    eq() { return true; }
    toDOM() { const rule = document.createElement('span'); rule.className = 'cm-md-hr'; return rule; }
  }
  class FenceLabelWidget extends WidgetType {
    constructor(label) { super(); this.label = label; }
    eq(other) { return other.label === this.label; }
    toDOM() { const label = document.createElement('span'); label.className = 'cm-md-fence-label'; label.textContent = this.label; return label; }
  }
  // Clicking toggles the marker's text; the widget keeps the selection where it is.
  class CheckboxWidget extends WidgetType {
    constructor(checked) { super(); this.checked = checked; }
    eq(other) { return other.checked === this.checked; }
    toDOM(view) {
      const box = document.createElement('input');
      box.type = 'checkbox'; box.className = 'cm-md-task'; box.checked = this.checked;
      box.setAttribute('aria-label', this.checked ? 'Completed task' : 'Task');
      box.addEventListener('mousedown', event => event.preventDefault());
      box.addEventListener('click', event => {
        event.preventDefault();
        const pos = view.posAtDOM(box);
        const marker = view.state.sliceDoc(pos, pos + 3);
        if (!/^\[[ xX]\]$/.test(marker)) return;
        view.dispatch({ changes: { from: pos + 1, to: pos + 2, insert: marker[1] === ' ' ? 'x' : ' ' }, userEvent: 'input.toggle' });
      });
      return box;
    }
    ignoreEvent() { return true; }
  }
  // Nested bullet lists cycle through these, as most renderers do.
  const bullets = ['•', '◦', '▪'].map(glyph => new BulletWidget(glyph));
  const rule = new RuleWidget();
  // How many lists contain a list item, counting its own.
  const listDepth = item => { let depth = 0; for (let node = item.parent; node; node = node.parent) if (node.name === 'BulletList' || node.name === 'OrderedList') depth++; return depth; };
  const inQuote = node => { for (let parent = node.parent; parent; parent = parent.parent) if (parent.name === 'Blockquote') return true; return false; };

  function decorate(state) {
    const doc = state.doc;
    const tree = ensureSyntaxTree(state, doc.length, 200) ?? syntaxTree(state);
    const ranges = state.field(focused) ? state.selection.ranges : [];
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

    tree.iterate({ enter(node) {
      const { name, from, to } = node;
      const heading = /^(ATX|Setext)Heading(\d)$/.exec(name);
      if (heading) {
        const level = heading[2];
        const marks = children(node, 'HeaderMark');
        if (heading[1] === 'ATX') {
          lineClass(`cm-md-heading cm-md-h${level}`, from);
          if (!lineTouched(from)) for (const headerMark of marks) {
            if (headerMark.from === doc.lineAt(from).from) hideWithSpace(headerMark.from, headerMark.to);
            else hide(doc.sliceString(headerMark.from - 1, headerMark.from) === ' ' ? headerMark.from - 1 : headerMark.from, headerMark.to);
          }
        } else {
          const underline = doc.lineAt(to);
          eachLine(from, underline.from - 1, line => lineClass(`cm-md-heading cm-md-h${level}`, line.from));
          if (!touches(from, to)) { lineClass('cm-md-setext-underline', underline.from); for (const headerMark of marks) hide(headerMark.from, headerMark.to); }
        }
        return;
      }
      switch (name) {
        case 'Emphasis': case 'StrongEmphasis': case 'Strikethrough': {
          mark({ Emphasis: 'cm-md-em', StrongEmphasis: 'cm-md-strong', Strikethrough: 'cm-md-strike' }[name], from, to);
          if (!touches(from, to)) for (const marker of children(node, name === 'Strikethrough' ? 'StrikethroughMark' : 'EmphasisMark')) hide(marker.from, marker.to);
          return;
        }
        case 'InlineCode': {
          mark('cm-md-code', from, to);
          if (!touches(from, to)) for (const marker of children(node, 'CodeMark')) hide(marker.from, marker.to);
          return false;
        }
        case 'Link': {
          const marks = children(node, 'LinkMark');
          if (marks.length < 2) return;
          if (touches(from, to)) mark('cm-md-link-source', from, to);
          else { hide(from, marks[0].to); hide(marks[1].from, to); mark('cm-md-link', marks[0].to, marks[1].from); }
          return;
        }
        case 'Image': {
          const url = children(node, 'URL')[0];
          const marks = children(node, 'LinkMark');
          if (!url || marks.length < 2) return false;
          const widget = new ImageWidget(doc.sliceString(url.from, url.to).replace(/^<|>$/g, ''), doc.sliceString(marks[0].to, marks[1].from));
          if (touches(from, to)) { mark('cm-md-link-source', from, to); add(Decoration.widget({ widget, side: 1 }), to); }
          else add(Decoration.replace({ widget }), from, to);
          return false;
        }
        case 'Autolink': {
          mark('cm-md-link', from, to);
          if (!touches(from, to)) for (const marker of children(node, 'LinkMark')) hide(marker.from, marker.to);
          return false;
        }
        case 'URL': {
          if (node.node.parent?.name !== 'Link') mark('cm-md-link', from, to);
          return false;
        }
        case 'Blockquote': {
          eachLine(from, to, line => lineClass('cm-md-quote', line.from));
          return;
        }
        case 'QuoteMark': {
          if (!lineTouched(from)) hideWithSpace(from, to);
          return;
        }
        case 'ListItem': {
          if (!inQuote(node.node)) listLines.set(doc.lineAt(from).from, { depth: listDepth(node.node), first: true });
          return;
        }
        case 'Paragraph': {
          const item = node.node.parent;
          if (item?.name !== 'ListItem' || inQuote(item)) return;
          const depth = listDepth(item), itemLine = doc.lineAt(item.from).number;
          eachLine(from, to, line => {
            if (line.number === itemLine) return;
            listLines.set(line.from, { depth, first: false });
            const lead = /^[ \t]+/.exec(line.text);
            if (lead && !lineTouched(line.from)) hide(line.from, line.from + lead[0].length);
          });
          return;
        }
        // The marker takes a fixed width, standing in for the space after it, so
        // wrapped lines can line up with the item's text.
        case 'ListMark': {
          const item = node.node.parent;
          if (item?.name !== 'ListItem' || lineTouched(from)) return;
          const line = doc.lineAt(from);
          if (/^[ \t]+$/.test(doc.sliceString(line.from, from))) hide(line.from, from);
          if (item.getChild('Task')) hide(from, spaceAfter(to));
          else if (item.parent?.name === 'BulletList') add(Decoration.replace({ widget: bullets[(listDepth(item) - 1) % bullets.length] }), from, spaceAfter(to));
          else { mark('cm-md-list-number', from, to); hide(to, spaceAfter(to)); }
          return;
        }
        case 'TaskMarker': {
          const checked = /x/i.test(doc.sliceString(from, to));
          if (checked) mark('cm-md-task-done', to, node.node.parent?.to ?? to);
          if (!touches(from, to)) add(Decoration.replace({ widget: new CheckboxWidget(checked) }), from, spaceAfter(to));
          return;
        }
        case 'HorizontalRule': {
          if (!lineTouched(from)) add(Decoration.replace({ widget: rule }), from, to);
          return false;
        }
        case 'FencedCode': {
          const first = doc.lineAt(from), last = doc.lineAt(to);
          eachLine(from, to, line => lineClass('cm-md-codeblock', line.from));
          lineClass('cm-md-codeblock-first', first.from);
          lineClass('cm-md-codeblock-last', last.from);
          if (!touches(from, to)) {
            const info = children(node, 'CodeInfo')[0];
            const label = info ? doc.sliceString(info.from, info.to) : '';
            add(Decoration.replace(label ? { widget: new FenceLabelWidget(label) } : {}), first.from, first.to);
            if (last.number > first.number && /^\s*(```|~~~)/.test(last.text)) { hide(last.from, last.to); lineClass('cm-md-fence-hidden', last.from); }
            if (!label) lineClass('cm-md-fence-hidden', first.from);
          }
          return false;
        }
        case 'CodeBlock': {
          eachLine(from, to, line => lineClass('cm-md-codeblock cm-md-indented-code', line.from));
          return false;
        }
        case 'Table': {
          const first = doc.lineAt(from), last = doc.lineAt(to);
          if (state.field(MarginTables.sourceTables).includes(first.from)) eachLine(from, to, line => lineClass('cm-md-table-source', line.from));
          else add(Decoration.replace({ widget: new MarginTables.TableWidget(doc.sliceString(first.from, last.to)), block: true }), first.from, last.to);
          return false;
        }
        case 'Escape': {
          if (!touches(from, to)) hide(from, from + 1);
          return false;
        }
        case 'HTMLTag': case 'HTMLBlock': case 'Comment': case 'CommentBlock': {
          mark('cm-md-html', from, to);
          return false;
        }
      }
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
  window.MarginLivePreview = { extension: [focused, trackFocus, MarginTables.sourceTables, decorations], setFocused };
})();
