(() => {
  'use strict';
  const { syntaxTree } = MarginEditor;
  function textAt(state, pos) {
    for (let node = syntaxTree(state).resolveInner(pos, 1); node; node = node.parent) {
      if (node.name === 'FencedCode') return node.getChildren('CodeText').map(code => state.sliceDoc(code.from, code.to)).join('');
    }
    return null;
  }
  function copy(text) {
    const native = window.webkit?.messageHandlers?.native;
    if (native) native.postMessage({ action: 'copyText', text });
    else navigator.clipboard?.writeText(text);
  }
  window.MarginCodeCopy = { textAt, copy };
})();
