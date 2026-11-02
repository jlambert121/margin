/* Native bridge and presentation layer. All editor dependencies are bundled locally. */
(() => {
  'use strict';
  const $ = (selector) => document.querySelector(selector);

  const { EditorState, Compartment, EditorView, keymap, placeholder, drawSelection, defaultKeymap, indentWithTab, syntaxHighlighting, closeBrackets, closeBracketsKeymap } = MarginEditor;
  const session = MarginDocumentSession({ getView: () => view, refresh: () => output.refresh(), setTextZoom: zoom => controls.setTextZoom(zoom), setTitlebar: value => controls.setTitlebar(value), toast: message => controls.toast(message) });
  const { native, post, welcome, fromApp, changed, loadDocument, updateMetadata, setDiskText, keepMine, snapshot } = session;
  const { markdownSupport, markdownBrackets, codeHighlighter } = MarginEditorSyntax({});
  const input = MarginEditorInput({ getView: () => view, post, headings: () => output.headings(), revealPosition: (...args) => output.revealPosition(...args) });
  const { pastePlain, wrapSelectionMarkers } = input;
  const preview = new Compartment();
  const view = new EditorView({
    parent: $('#editor'),
    state: EditorState.create({ doc: session.getText(), extensions: [
      markdownSupport,
      markdownBrackets,
      closeBrackets(),
      wrapSelectionMarkers,
      syntaxHighlighting(codeHighlighter),
      EditorView.lineWrapping,
      drawSelection(),
      EditorView.contentAttributes.of({ spellcheck: 'true', 'aria-label': 'Markdown document' }),
      placeholder('Begin anywhere…'),
      preview.of(MarginLivePreview.extension),
      keymap.of([...closeBracketsKeymap, indentWithTab, ...defaultKeymap]),
      EditorView.updateListener.of(update => {
        if (update.docChanged && !update.transactions.some(tr => tr.annotation(fromApp))) changed(update.state.doc.toString());
        if (update.selectionSet || update.docChanged) output.updateCursorPosition(update.state);
        if (update.selectionSet && document.body.classList.contains('typewriter') && update.view.hasFocus) {
          setTimeout(() => view.dispatch({ effects: EditorView.scrollIntoView(view.state.selection.main.head, { y: 'center' }) }));
        }
      }),
      input.handlers,
    ] }),
  });

  const output = MarginDocumentOutput({ view, post, getText: session.getText });
  const { headings, revealPosition, exportHTML, preparePrint, refresh } = output;
  const controls = MarginAppControls({ view, preview, post, command, keepMine });
  const { toast, toggleSource, setTypewriter, closeMenus, setTitlebar, setTextZoom } = controls;
  const { format } = MarginEditorFormatting({ view, closeMenus, toast });
  const { showFind, showGoToLine } = MarginEditorSearch({ view, revealPosition });
  MarginAppShortcuts({ view, native, post, format, command, closeMenus });
  function command(name, value) {
    if (name === 'source') toggleSource();
    else if (name === 'sidebar') document.body.classList.toggle('sidebar-open', Boolean(value?.open));
    else if (name === 'reveal') revealPosition(Number(value), 'start');
    else if (name === 'find') showFind();
    else if (name === 'replace') showFind(true);
    else if (name === 'goToLine') showGoToLine();
    else if (name === 'textZoom') setTextZoom(Number(value));
    else if (name === 'titlebar') setTitlebar(value ?? {});
    else if (name === 'typewriter') setTypewriter();
    else if (name === 'exportHTML') post('exportHTML', { html: exportHTML() });
    else if (name === 'print') post('print');
    else if (name === 'metadata') updateMetadata(value);
    else if (name === 'format') format(value);
    else if (name === 'diskChanged') setDiskText(value);
    else if (name === 'toast') toast(value);
    else if (name === 'pastePlain' && typeof value === 'string') pastePlain(value);
  }
  document.addEventListener('click', event => {
    const actionButton = event.target.closest('[data-action]');
    if (actionButton) command(actionButton.dataset.action);
    const formatButton = event.target.closest('[data-format]'); if (formatButton) format(formatButton.dataset.format);
    if (!event.target.closest('.popover,#format-button,#more-button')) closeMenus();
  });
  window.app = { load: loadDocument, command, getMarkdown: session.getText, snapshot, getHTML: () => MarginMarkdown.renderDocument(session.getText()), headings, view, isSource: controls.isSource, preparePrint, welcome };
  // Resolves local images through the restricted native asset handler, while keeping
  // the Markdown URLs themselves relative and portable.
  if (native) {
    const base = document.createElement('base'); base.href = 'markdown-asset://local/'; document.head.append(base);
  }
  refresh();
  if (native) post('ready');
})();
