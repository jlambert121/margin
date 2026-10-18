/* Spreadsheet-style editing of Markdown tables in live preview. The table's
   Markdown stays the document: each grid action rewrites as little of it as it
   can, and the grid redraws from the result. */
(() => {
  'use strict';
  const { WidgetType, StateField, StateEffect, syntaxTree } = MarginEditor;

  // Cells are split on unescaped pipes; leading and trailing pipes are optional.
  function parseRow(line) {
    const pipes = [];
    for (let i = 0; i < line.length; i++) { if (line[i] === '\\') i++; else if (line[i] === '|') pipes.push(i); }
    const first = line.search(/\S/), last = line.trimEnd().length - 1;
    const bounds = [...pipes];
    if (bounds[0] !== first) bounds.unshift(first - 1);
    if (bounds[bounds.length - 1] !== last) bounds.push(last + 1);
    const cells = [];
    for (let k = 0; k + 1 < bounds.length; k++) {
      const start = bounds[k] + 1, end = bounds[k + 1], text = line.slice(start, end);
      const from = start + text.length - text.trimStart().length;
      cells.push({ start, end, from, to: from + text.trim().length, raw: text.trim() });
    }
    return cells;
  }
  function parseTable(source) {
    const lines = source.split('\n');
    const rows = lines.map(parseRow);
    const align = rows[1].map(({ raw }) => raw.startsWith(':') && raw.endsWith(':') ? 'center' : raw.endsWith(':') ? 'right' : raw.startsWith(':') ? 'left' : '');
    return { source, lines, rows, align, columns: rows[0].length, bodyRows: lines.length - 2 };
  }
  // Grid rows count the header as row 0; the delimiter line is not a row.
  const lineIndex = row => row === 0 ? 0 : row + 1;
  const lineStart = (table, base, index) => table.lines.slice(0, index).reduce((pos, line) => pos + line.length + 1, base);
  const cellRaw = (table, row, col) => table.rows[lineIndex(row)]?.[col]?.raw ?? '';
  const unescapeCell = raw => raw.replace(/\\\|/g, '|');
  const escapeCell = text => text.replace(/\r?\n/g, ' ').replace(/\\?\|/g, '\\|');
  const delimiter = align => ({ left: ':---', center: ':---:', right: '---:' }[align] ?? '---');
  const formatRow = cells => `| ${cells.join(' | ')} |`;
  const rowCells = (table, index) => {
    const cells = table.rows[index].map(cell => cell.raw).slice(0, table.columns);
    while (cells.length < table.columns) cells.push(index === 1 ? '---' : '');
    return cells;
  };
  const replaceLine = (table, base, index, text) => {
    const from = lineStart(table, base, index);
    return { from, to: from + table.lines[index].length, insert: text };
  };
  // Column changes reach every row, so they rewrite the whole table.
  const rewriteColumns = (table, base, change) => ({
    from: base, to: base + table.source.length,
    insert: table.lines.map((_, index) => formatRow(change(rowCells(table, index), index === 1))).join('\n'),
  });
  const swap = (cells, a, b) => { [cells[a], cells[b]] = [cells[b], cells[a]]; return cells; };

  const edits = {
    setCell(table, base, row, col, text) {
      const index = lineIndex(row), cell = table.rows[index][col], value = escapeCell(text);
      const start = lineStart(table, base, index);
      if (!cell) { const cells = rowCells(table, index); cells[col] = value; return { changes: replaceLine(table, base, index, formatRow(cells)) }; }
      if (!cell.raw) return { changes: { from: start + cell.start, to: start + cell.end, insert: value ? ` ${value} ` : ' ' } };
      return { changes: { from: start + cell.from, to: start + cell.to, insert: value } };
    },
    insertRow(table, base, row, below) {
      const empty = formatRow(Array(table.columns).fill(''));
      if (!below) return { changes: { from: lineStart(table, base, lineIndex(row)), insert: `${empty}\n` }, focus: [row, 0] };
      const after = row === 0 ? 1 : lineIndex(row);
      return { changes: { from: lineStart(table, base, after) + table.lines[after].length, insert: `\n${empty}` }, focus: [row + 1, 0] };
    },
    deleteRow(table, base, row) {
      const index = lineIndex(row), start = lineStart(table, base, index);
      return { changes: { from: start - 1, to: start + table.lines[index].length } };
    },
    moveRow(table, base, row, offset) {
      const a = lineIndex(row), b = lineIndex(row + offset), low = Math.min(a, b), high = Math.max(a, b);
      const from = lineStart(table, base, low);
      return { changes: { from, to: lineStart(table, base, high) + table.lines[high].length, insert: `${table.lines[high]}\n${table.lines[low]}` }, focus: [row + offset, null] };
    },
    insertColumn(table, base, col, right) {
      const at = col + (right ? 1 : 0);
      return { changes: rewriteColumns(table, base, (cells, isDelimiter) => { cells.splice(at, 0, isDelimiter ? '---' : ''); return cells; }) };
    },
    deleteColumn(table, base, col) {
      return { changes: rewriteColumns(table, base, cells => { cells.splice(col, 1); return cells; }) };
    },
    moveColumn(table, base, col, offset) {
      return { changes: rewriteColumns(table, base, cells => swap(cells, col, col + offset)), focus: [null, col + offset] };
    },
    align(table, base, col, align) {
      const cells = rowCells(table, 1); cells[col] = delimiter(align);
      return { changes: replaceLine(table, base, 1, formatRow(cells)) };
    },
  };

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
      for (const cell of dom.querySelectorAll('[data-row]')) if (cell !== editing) fillCell(cell, table);
      return;
    }
    const focus = dom.focusAfterRender ?? (editing ? [+editing.dataset.row, +editing.dataset.col] : null);
    dom.focusAfterRender = null;
    dom.tableShape = shape;
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
    dom.replaceChildren(element);
    if (focus) {
      const row = Math.min(focus[0] ?? 0, table.bodyRows), col = Math.min(focus[1] ?? 0, table.columns - 1);
      const cell = cellAt(dom, row, col);
      if (cell) startEditing(dom, cell);
    }
  }
  function move(view, dom, cell, rowOffset, colOffset, addRowAtEnd) {
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
        if (event.key === 'Tab') move(view, dom, cell, 0, event.shiftKey ? -1 : 1, !event.shiftKey);
        else if (event.key === 'Enter' || event.key === 'ArrowDown') move(view, dom, cell, 1, 0, false);
        else if (event.key === 'ArrowUp') move(view, dom, cell, -1, 0, false);
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
