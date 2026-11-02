/* Pure Markdown table parsing and source edits. */
(() => {
  'use strict';
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

  window.MarginTableModel = { parseTable, cellRaw, unescapeCell, edits };
})();
