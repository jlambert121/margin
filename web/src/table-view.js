/* Table cell presentation and editing focus. */
(() => {
  'use strict';
  const { parseTable, cellRaw, unescapeCell } = MarginTableModel;
  const cellAt = (dom, row, col) => dom.querySelector(`[data-row="${row}"][data-col="${col}"]`);
  function fillCell(cell, table) {
    const raw = cellRaw(table, +cell.dataset.row, +cell.dataset.col);
    cell.innerHTML = raw ? MarginMarkdown.renderInline(raw) : '';
    cell.style.textAlign = table.align[+cell.dataset.col] || '';
  }
  function startEditing(dom, cell) {
    const current = dom.querySelector('.cm-md-cell-editing');
    if (current === cell) return;
    if (current) stopEditing(dom, current);
    cell.classList.add('cm-md-cell-editing');
    cell.contentEditable = 'plaintext-only';
    cell.textContent = unescapeCell(cellRaw(parseTable(dom.tableSource), +cell.dataset.row, +cell.dataset.col));
    cell.focus();
    const selection = window.getSelection();
    selection.selectAllChildren(cell); selection.collapseToEnd();
  }
  function stopEditing(dom, cell) {
    cell.classList.remove('cm-md-cell-editing');
    cell.removeAttribute('contenteditable');
    fillCell(cell, parseTable(dom.tableSource));
  }
  // The cell being typed in keeps its element so focus and caret survive the redraw.
  function render(dom, source) {
    const table = parseTable(source);
    dom.tableSource = source;
    const shape = `${table.lines.length}x${table.columns}`;
    const editing = dom.querySelector('.cm-md-cell-editing');
    if (editing && dom.tableShape === shape && !dom.focusAfterRender) {
      refreshOtherCells(dom, table, editing);
      return;
    }
    const focus = dom.focusAfterRender ?? (editing ? [+editing.dataset.row, +editing.dataset.col] : null);
    dom.focusAfterRender = null;
    dom.tableShape = shape;
    dom.replaceChildren(buildTableElement(table));
    restoreFocus(dom, table, focus);
  }
  function refreshOtherCells(dom, table, editing) {
    for (const cell of dom.querySelectorAll('[data-row]')) if (cell !== editing) fillCell(cell, table);
  }
  function buildTableElement(table) {
    const element = document.createElement('table');
    const head = element.createTHead().insertRow(), body = element.createTBody();
    for (let row = 0; row <= table.bodyRows; row++) {
      const tr = row === 0 ? head : body.insertRow();
      for (let col = 0; col < table.columns; col++) {
        const cell = document.createElement(row === 0 ? 'th' : 'td');
        cell.dataset.row = row; cell.dataset.col = col;
        fillCell(cell, table); tr.append(cell);
      }
    }
    return element;
  }
  function restoreFocus(dom, table, focus) {
    if (focus) {
      const row = Math.min(focus[0] ?? 0, table.bodyRows), col = Math.min(focus[1] ?? 0, table.columns - 1);
      const cell = cellAt(dom, row, col);
      if (cell) startEditing(dom, cell);
    }
  }
  window.MarginTableView = { cellAt, startEditing, stopEditing, render };
})();
