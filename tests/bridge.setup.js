/* Injected at document start for the bridge suite: the page runs in native mode
   against a recording message handler, with failing browser storage and a
   color scheme the tests control. */
window.__messages = [];
const nativeHandler = window.webkit.messageHandlers.native;
const deliver = nativeHandler.postMessage.bind(nativeHandler);
nativeHandler.postMessage = message => { window.__messages.push(message); deliver(message); };
for (const name of ['localStorage', 'sessionStorage']) {
  Object.defineProperty(window, name, { get() { throw new Error('Storage unavailable'); } });
}
const colorScheme = { matches: false, listeners: [], addEventListener(type, listener) { if (type === 'change') this.listeners.push(listener); }, removeEventListener() {} };
const matchMedia = window.matchMedia.bind(window);
window.matchMedia = query => query === '(prefers-color-scheme: dark)' ? colorScheme : matchMedia(query);
window.__setColorScheme = dark => { colorScheme.matches = dark; colorScheme.listeners.forEach(listener => listener({ matches: dark })); };
