/* App controls. */
'use strict';
window.MarginAppControls = ({ view, preview, post, command, keepMine }) => {
  const $ = selector => document.querySelector(selector);
  const { EditorView } = MarginEditor;
  let toastTimer;
  let sourceMode = false;
  // In the app, WebKit matches this to the window's appearance, which follows Settings.
  const systemAppearance = window.matchMedia('(prefers-color-scheme: dark)');
  const applyTheme = () => { document.body.dataset.theme = systemAppearance.matches ? 'dark' : 'light'; };
  systemAppearance.addEventListener('change', applyTheme);
  applyTheme();

  function toast(message) {
    clearTimeout(toastTimer);
    $('#toast').textContent = message;
    $('#toast').hidden = false;
    toastTimer = setTimeout(() => $('#toast').hidden = true, 3000);
  }

  function toggleSource(force) {
    const next = typeof force === 'boolean' ? force : !sourceMode;
    if (next === sourceMode) return;
    sourceMode = next;
    view.dispatch({ effects: preview.reconfigure(sourceMode ? [] : MarginLivePreview.extension) });
    $('#editor').classList.toggle('source-mode', sourceMode);
    $('#source-button').setAttribute('aria-pressed', String(sourceMode));
    closeMenus();
    view.focus();
  }

  function setTypewriter() {
    const on = document.body.classList.toggle('typewriter');
    $('#typewriter-check').textContent = on ? '✓' : '';
    closeMenus();
  }

  function closeMenus() {
    $('#format-menu').hidden = true; $('#view-menu').hidden = true;
    $('#format-button').setAttribute('aria-expanded', 'false'); $('#more-button').setAttribute('aria-expanded', 'false');
  }

  function openMenu(id, trigger) {
    const wasHidden = $(id).hidden; closeMenus(); $(id).hidden = !wasHidden; $(trigger).setAttribute('aria-expanded', String(wasHidden));
  }

  function setTitlebar({ inset = 0 } = {}) {
    document.documentElement.style.setProperty('--titlebar-inset', `${Math.max(0, Number(inset) || 0)}px`);
  }

  function setTextZoom(zoom) {
    if (Number.isFinite(zoom) && zoom > 0) { $('#editor').style.setProperty('--text-zoom', String(zoom)); view.requestMeasure(); }
  }

  $('#toggle-sidebar').onclick = () => post('toggleSidebar');
  $('#source-button').onclick = () => command('source');
  $('#format-button').onclick = () => openMenu('#format-menu', '#format-button');
  $('#more-button').onclick = () => openMenu('#view-menu', '#more-button');
  $('#typewriter-button').onclick = () => command('typewriter');
  $('#word-count').onclick = () => toast($('#word-count').title);
  $('#disk-reload').onclick = () => post('diskReload');
  $('#disk-keep-mine').onclick = keepMine;
  $('#disk-save-as').onclick = () => post('diskSaveAs');

  return { toast, toggleSource, setTypewriter, closeMenus, setTitlebar, setTextZoom, isSource: () => sourceMode };
};
