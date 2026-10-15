/* Loaded before the editor dependencies so startup failures reach the app. */
(() => {
  'use strict';
  const report = message => {
    window.webkit?.messageHandlers?.native?.postMessage({ action: 'editorError', message: String(message).slice(0, 2000) });
  };
  window.addEventListener('error', event => {
    if (event.target instanceof HTMLScriptElement || event.target instanceof HTMLLinkElement) {
      report('An editor component could not be loaded.');
    } else if (event.message) report(event.message);
  }, true);
  window.addEventListener('unhandledrejection', event => report(event.reason?.message || event.reason || 'An editor operation failed.'));
})();
