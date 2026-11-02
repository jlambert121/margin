/* Spreadsheet-style editing of Markdown tables in live preview. The table's
   Markdown stays the document: each grid action rewrites as little of it as it
   can, and the grid redraws from the result. */
(() => {
  'use strict';
  const { WidgetType, StateField, StateEffect, syntaxTree } = MarginEditor;

  const { parseTable, edits } = MarginTableModel;
  const { cellAt, startEditing, stopEditing, render } = MarginTableView;

  // Tables chosen for "Edit as Markdown", by start position, until the selection leaves them.
  const showSource = StateEffect.define({ map: (pos, mapping) => mapping.mapPos(pos) });
  const tableAt = (state, pos) => {
    for (let node = syntaxTree(state).resolve(pos, 1); node; node = node.parent) if (node.name === 'Table') return node;
    return null;
  };
  const sourceTables = StateField.define({
    create: () => [],
    update(value, tr) {
      let next = tr.docChanged ? value.map(pos => tr.changes.mapPos(pos)) : value;
      for (const effect of tr.effects) if (effect.is(showSource)) next = [...next, effect.value];
      if (!next.length || (!tr.selection && !tr.docChanged && next === value)) return next;
      return next.filter(pos => {
        const table = tableAt(tr.state, pos);
        return table && tr.state.selection.ranges.some(range => range.from <= table.to && range.to >= table.from);
      });
    },
  });

  function apply(view, dom, edit, ...args) {
    const base = view.posAtDOM(dom), source = dom.tableSource;
    if (view.state.sliceDoc(base, base + source.length) !== source) return;
    const result = edits[edit](parseTable(source), base, ...args);
    if (result.focus) dom.focusAfterRender = result.focus;
    view.dispatch({ changes: result.changes, userEvent: edit === 'setCell' ? 'input.type' : 'input.table' });
  }
  function move(view, dom, cell, movement) {
    const { rowOffset, colOffset, addRowAtEnd = false } = movement;
    const table = parseTable(dom.tableSource);
    let row = +cell.dataset.row, col = +cell.dataset.col + colOffset;
    if (col >= table.columns) { col = 0; row++; }
    if (col < 0) { col = table.columns - 1; row--; }
    row += rowOffset;
    if (row < 0) return;
    if (row > table.bodyRows) {
      if (addRowAtEnd) apply(view, dom, 'insertRow', table.bodyRows, true);
      return;
    }
    startEditing(dom, cellAt(dom, row, col));
  }
  function leave(view, dom, cell) {
    stopEditing(dom, cell);
    const end = view.posAtDOM(dom) + dom.tableSource.length;
    view.dispatch({ selection: { anchor: Math.min(end + 1, view.state.doc.length) } });
    view.focus();
  }

  let menu;
  function openMenu(view, dom, cell, x, y) {
    const table = parseTable(dom.tableSource), row = +cell.dataset.row, col = +cell.dataset.col;
    const items = [
      ['Insert Row Above', row > 0, () => apply(view, dom, 'insertRow', row, false)],
      ['Insert Row Below', true, () => apply(view, dom, 'insertRow', row, true)],
      ['Delete Row', row > 0, () => apply(view, dom, 'deleteRow', row)],
      null,
      ['Insert Column Left', true, () => apply(view, dom, 'insertColumn', col, false)],
      ['Insert Column Right', true, () => apply(view, dom, 'insertColumn', col, true)],
      ['Delete Column', table.columns > 1, () => apply(view, dom, 'deleteColumn', col)],
      null,
      ['Align Left', true, () => apply(view, dom, 'align', col, 'left')],
      ['Align Center', true, () => apply(view, dom, 'align', col, 'center')],
      ['Align Right', true, () => apply(view, dom, 'align', col, 'right')],
      null,
      ['Move Row Up', row > 1, () => apply(view, dom, 'moveRow', row, -1)],
      ['Move Row Down', row > 0 && row < table.bodyRows, () => apply(view, dom, 'moveRow', row, 1)],
      ['Move Column Left', col > 0, () => apply(view, dom, 'moveColumn', col, -1)],
      ['Move Column Right', col < table.columns - 1, () => apply(view, dom, 'moveColumn', col, 1)],
      null,
      ['Edit as Markdown', true, () => {
        const pos = view.posAtDOM(dom);
        view.dispatch({ effects: showSource.of(pos), selection: { anchor: pos } });
        view.focus();
      }],
    ];
    if (!menu) {
      menu = document.createElement('div');
      menu.className = 'popover table-menu'; menu.setAttribute('role', 'menu');
      document.body.append(menu);
      document.addEventListener('mousedown', event => { if (!menu.contains(event.target)) menu.hidden = true; }, true);
      document.addEventListener('keydown', event => { if (event.key === 'Escape') menu.hidden = true; });
    }
    menu.replaceChildren(...items.map(item => {
      if (!item) return document.createElement('hr');
      const [label, enabled, run] = item;
      const button = document.createElement('button');
      button.textContent = label; button.disabled = !enabled; button.setAttribute('role', 'menuitem');
      button.onclick = () => { menu.hidden = true; run(); };
      return button;
    }));
    menu.hidden = false;
    menu.style.left = `${Math.min(x, window.innerWidth - menu.offsetWidth - 8)}px`;
    menu.style.top = `${Math.min(y, window.innerHeight - menu.offsetHeight - 8)}px`;
  }

  class TableWidget extends WidgetType {
    constructor(source) { super(); this.source = source; }
    eq(other) { return other.source === this.source; }
    toDOM(view) {
      const dom = document.createElement('div');
      dom.className = 'cm-md-table';
      dom.addEventListener('mousedown', event => {
        const cell = event.target.closest('[data-row]');
        if (!cell || event.button !== 0 || cell.classList.contains('cm-md-cell-editing')) return;
        event.preventDefault();
        startEditing(dom, cell);
      });
      dom.addEventListener('contextmenu', event => {
        const cell = event.target.closest('[data-row]');
        if (!cell) return;
        event.preventDefault();
        openMenu(view, dom, cell, event.clientX, event.clientY);
      });
      dom.addEventListener('input', event => {
        const cell = event.target.closest('.cm-md-cell-editing');
        if (cell) apply(view, dom, 'setCell', +cell.dataset.row, +cell.dataset.col, cell.textContent);
      });
      dom.addEventListener('keydown', event => {
        const cell = event.target.closest('.cm-md-cell-editing');
        if (!cell || event.metaKey || event.ctrlKey || event.altKey) return;
        if (event.key === 'Tab') move(view, dom, cell, { rowOffset: 0, colOffset: event.shiftKey ? -1 : 1, addRowAtEnd: !event.shiftKey });
        else if (event.key === 'Enter' || event.key === 'ArrowDown') move(view, dom, cell, { rowOffset: 1, colOffset: 0 });
        else if (event.key === 'ArrowUp') move(view, dom, cell, { rowOffset: -1, colOffset: 0 });
        else if (event.key === 'Escape') leave(view, dom, cell);
        else return;
        event.preventDefault();
      });
      dom.addEventListener('focusout', event => {
        const cell = event.target.closest?.('.cm-md-cell-editing');
        if (cell && !dom.contains(event.relatedTarget)) stopEditing(dom, cell);
      });
      render(dom, this.source);
      return dom;
    }
    updateDOM(dom) { render(dom, this.source); return true; }
    ignoreEvent() { return true; }
  }

  window.MarginTables = { TableWidget, sourceTables };
})();
