/* Widget types share the preview's lifetime. */
(() => {
  'use strict';
  const { WidgetType } = MarginEditor;
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
  // A rendered Mermaid diagram. Clicking it places the cursor in the fence, which shows its source.
  class DiagramWidget extends WidgetType {
    constructor(svg) { super(); this.svg = svg; }
    eq(other) { return other.svg === this.svg; }
    toDOM() { const diagram = document.createElement('div'); diagram.className = 'cm-md-diagram'; diagram.innerHTML = this.svg; return diagram; }
    ignoreEvent() { return false; }
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
  window.MarginPreviewWidgets = () => ({ ImageWidget, bullets: ['•', '◦', '▪'].map(glyph => new BulletWidget(glyph)), rule: new RuleWidget(), FenceLabelWidget, DiagramWidget, CheckboxWidget });
})();
