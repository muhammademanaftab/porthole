(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.PortholeCore = api;
})(typeof self !== 'undefined' ? self : this, function () {
  const KEYS = {KeyA:0,KeyS:1,KeyD:2,KeyF:3,KeyH:4,KeyG:5,KeyZ:6,KeyX:7,KeyC:8,KeyV:9,IntlBackslash:10,KeyB:11,KeyQ:12,KeyW:13,KeyE:14,KeyR:15,KeyY:16,KeyT:17,Digit1:18,Digit2:19,Digit3:20,Digit4:21,Digit6:22,Digit5:23,Equal:24,Digit9:25,Digit7:26,Minus:27,Digit8:28,Digit0:29,BracketRight:30,KeyO:31,KeyU:32,BracketLeft:33,KeyI:34,KeyP:35,Enter:36,KeyL:37,KeyJ:38,Quote:39,KeyK:40,Semicolon:41,Backslash:42,Comma:43,Slash:44,KeyN:45,KeyM:46,Period:47,Tab:48,Space:49,Backquote:50,Backspace:51,Escape:53,MetaRight:54,MetaLeft:55,ShiftLeft:56,CapsLock:57,AltLeft:58,ControlLeft:59,ShiftRight:60,AltRight:61,ControlRight:62,NumpadDecimal:65,NumpadMultiply:67,NumpadAdd:69,NumLock:71,NumpadDivide:75,NumpadEnter:76,NumpadSubtract:78,NumpadEqual:81,Numpad0:82,Numpad1:83,Numpad2:84,Numpad3:85,Numpad4:86,Numpad5:87,Numpad6:88,Numpad7:89,Numpad8:91,Numpad9:92,F5:96,F6:97,F7:98,F3:99,F8:100,F9:101,F11:103,F13:105,F14:107,F10:109,F12:111,F15:113,Help:114,Insert:114,Home:115,PageUp:116,Delete:117,F4:118,End:119,F2:120,PageDown:121,F1:122,ArrowLeft:123,ArrowRight:124,ArrowDown:125,ArrowUp:126,F16:106,F17:64,F18:79,F19:80,F20:90,IntlYen:93,IntlRo:94,NumpadComma:95,Lang1:104,Lang2:102,AudioVolumeUp:72,AudioVolumeDown:73,AudioVolumeMute:74,ContextMenu:110,Fn:63};

  const MODIFIER_CODES = new Set(['MetaLeft', 'MetaRight', 'ShiftLeft', 'ShiftRight', 'AltLeft', 'AltRight',
    'ControlLeft', 'ControlRight', 'CapsLock', 'Fn']);
  const MOVE_INTERVAL = 16;
  const PIXELS_PER_LINE = 16;
  const RETRY = { list: { every: 1000, times: 10 }, open: { every: 2000, times: 5 } };

  function mods(e, isMac) {
    let m = 0;
    if (e.shiftKey) m |= 1;
    if (e.altKey) m |= 4;
    if (isMac) { if (e.ctrlKey) m |= 2; if (e.metaKey) m |= 8; }
    else { if (e.ctrlKey) m |= 8; if (e.metaKey) m |= 2; }
    return m;
  }

  function norm(clientX, clientY, r, videoWidth, videoHeight, clamp) {
    const vw = videoWidth || r.width, vh = videoHeight || r.height;
    const s = Math.min(r.width / vw, r.height / vh);
    const w = vw * s, h = vh * s;
    if (!(w > 0 && h > 0)) return clamp ? { x: 0.5, y: 0.5 } : null;
    const x0 = r.left + (r.width - w) / 2, y0 = r.top + (r.height - h) / 2;
    let x = (clientX - x0) / w, y = (clientY - y0) / h;
    if (clamp) return { x: Math.min(Math.max(x, 0), 1), y: Math.min(Math.max(y, 0), 1) };
    return (x < 0 || y < 0 || x > 1 || y > 1) ? null : { x, y };
  }

  const btnOf = (e) => e.button === 0 ? 0 : e.button === 2 ? 1 : e.button === 1 ? 2 : null;

  const dragButton = (buttons) => (buttons & 4) ? 1 : (buttons & 2) ? 2 : 0;

  function countClick(prev, now, x, y) {
    const near = Math.abs(x - prev.x) < 5 && Math.abs(y - prev.y) < 5;
    const count = (now - prev.t < 450 && near) ? prev.count + 1 : 1;
    return { t: now, x, y, count };
  }

  const shouldSendMove = (now, last) => now - last >= MOVE_INTERVAL;

  function scrollDelta(e) {
    const k = e.deltaMode === 1 ? PIXELS_PER_LINE : 1;
    return { dx: -e.deltaX * k, dy: -e.deltaY * k };
  }

  function createPointer(winId, isMac) {
    let buttons = 0, lastMove = 0, click = { t: 0, x: 0, y: 0, count: 0 };
    const at = (e, g, clamp) => norm(e.clientX, e.clientY, g.rect, g.vw, g.vh, clamp);
    return {
      get buttons() { return buttons; },
      down(e, g, now) {
        const btn = btnOf(e);
        if (btn === null) return null;
        const p = at(e, g, false);
        if (!p) return null;
        buttons |= 1 << e.button;
        click = countClick(click, now, e.clientX, e.clientY);
        return { msg: { t: 'mouse', win: winId, kind: 'down', btn, x: p.x, y: p.y, clicks: click.count, mods: mods(e, isMac) }, reliable: true };
      },
      up(e, g) {
        const btn = btnOf(e);
        if (btn === null || !(buttons & (1 << e.button))) return null;
        const p = at(e, g, true);
        buttons &= ~(1 << e.button);
        return { msg: { t: 'mouse', win: winId, kind: 'up', btn, x: p.x, y: p.y, clicks: click.count, mods: mods(e, isMac) }, reliable: true };
      },
      move(e, g, now) {
        if (!shouldSendMove(now, lastMove)) return null;
        lastMove = now;
        const p = at(e, g, !!buttons);
        if (!p) return null;
        if (buttons) return { msg: { t: 'mouse', win: winId, kind: 'drag', btn: dragButton(buttons), x: p.x, y: p.y, mods: mods(e, isMac) }, reliable: true };
        return { msg: { t: 'mouse', win: winId, kind: 'move', btn: 0, x: p.x, y: p.y, mods: mods(e, isMac) }, reliable: false };
      },
    };
  }

  const isChar = (k) => [...k].length === 1;

  function keyMessages(e, down, isMac, winId, swallowedUp) {
    const shortcut = isMac ? e.metaKey : e.ctrlKey;
    if (shortcut && e.code === 'KeyV') return { prevent: false, send: [] };
    const code = KEYS[e.code];
    if (code === undefined) {
      return { prevent: true, send: (down && isChar(e.key)) ? [{ t: 'text', win: winId, s: e.key }] : [] };
    }
    if (!down && swallowedUp.delete(e.code)) return { prevent: true, send: [] };
    const msg = { t: 'key', win: winId, code, down, mods: mods(e, isMac), s: isChar(e.key) ? e.key : undefined };
    const out = [msg];
    if (down && isMac && e.metaKey && !MODIFIER_CODES.has(e.code)) {
      out.push({ ...msg, down: false });
      swallowedUp.add(e.code);
    }
    return { prevent: true, send: out };
  }

  async function retry(fn, done, every, times, sleep = (ms) => new Promise(r => setTimeout(r, ms))) {
    for (let i = 0; i < times && !done(); i++) { fn(); await sleep(every); }
  }

  const pickerStatus = (n) => n === 0 ? 'No windows to share on the host.'
    : `${n} window${n === 1 ? '' : 's'} on the host. Each opens in its own tab.`;

  const windowLink = (pw, id) => `?pw=${encodeURIComponent(pw)}&win=${id}`;

  const pickerLink = (pw) => `?pw=${encodeURIComponent(pw)}`;

  const sizeLabel = (w, h) => `${Math.round(w)}\u00d7${Math.round(h)}`;

  function randomUUID(cryptoObj) {
    const b = cryptoObj.getRandomValues(new Uint8Array(16));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  }

  function ensureRandomUUID(cryptoObj) {
    if (cryptoObj && typeof cryptoObj.randomUUID !== 'function') cryptoObj.randomUUID = () => randomUUID(cryptoObj);
    return cryptoObj;
  }

  const CLIP_TOPIC = 'porthole-clip';
  const CLIP_MAX_BYTES = 1000000;
  const COMMAND = 8;

  function clipFits(text) {
    return typeof text === 'string' && text.length > 0 && new TextEncoder().encode(text).length <= CLIP_MAX_BYTES;
  }

  function pasteKeys(winId) {
    return [
      { t: 'key', win: winId, code: KEYS.MetaLeft, down: true, mods: COMMAND },
      { t: 'key', win: winId, code: KEYS.KeyV, down: true, mods: COMMAND },
      { t: 'key', win: winId, code: KEYS.KeyV, down: false, mods: COMMAND },
      { t: 'key', win: winId, code: KEYS.MetaLeft, down: false, mods: 0 },
    ];
  }

  const AUDIO_TRACK = 'aud-mix';

  const isAudioTrack = (name) => name === AUDIO_TRACK;

  const soundLabel = (canPlay, muted) => !canPlay ? 'Click for sound' : muted ? 'Sound off' : 'Sound on';

  const THUMB_TOPIC = 'porthole-thumb';
  const ICON_TOPIC = 'porthole-icon';
  const LOCKED_LIST = "This Mac's screen is locked, and macOS hides all windows while it is locked. Unlock it (for example with Screen Sharing), then refresh.";

  const fold = (s) => String(s).normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();

  function filterWindows(list, query) {
    const tokens = String(query || '').split(/\s+/).filter(Boolean).map(fold);
    if (!tokens.length) return list.slice();
    return list.filter(w => { const hay = fold(`${w.app} ${w.title}`); return tokens.every(t => hay.includes(t)); });
  }

  function pickerNotice(loaded, total, shown, query, error) {
    if (total === 0 && error) return error === LOCKED_LIST
      ? { kind: 'locked', title: 'Screen Is Locked', message: LOCKED_LIST }
      : { kind: 'error', title: "Can't Show Windows", message: error };
    if (!loaded) return { kind: 'loading', title: 'Connecting…', message: 'Asking the host for its windows.' };
    if (total === 0) return { kind: 'empty', title: 'No Windows to Share', message: 'Open a window on the host, then refresh.' };
    if (shown === 0) return { kind: 'nomatch', title: 'No Matches', message: `No window matches \u201C${String(query).trim()}\u201D.` };
    return null;
  }

  function countLabel(total, shown) {
    const all = `${total} window${total === 1 ? '' : 's'}`;
    return shown === total ? all : `${shown} of ${all}`;
  }

  const portalTitle = (w) => w.title ? `${w.app} \u2014 ${w.title}` : w.app;

  function streamWindow(attributes) {
    const s = attributes && attributes.win;
    if (typeof s !== 'string' || !/^\d+$/.test(s)) return null;
    const n = Number(s);
    return n <= 0xFFFFFFFF && String(n) === s ? n : null;
  }

  function iconRequests(list, limit = 24) {
    const seen = new Set(), out = [];
    for (const w of list) {
      if (out.length >= limit) break;
      if (seen.has(w.app)) continue;
      seen.add(w.app); out.push(w.id);
    }
    return out;
  }

  return { THUMB_TOPIC, ICON_TOPIC, LOCKED_LIST, filterWindows, pickerNotice, countLabel, portalTitle, streamWindow, iconRequests, randomUUID, ensureRandomUUID, AUDIO_TRACK, isAudioTrack, soundLabel, CLIP_TOPIC, CLIP_MAX_BYTES, clipFits, pasteKeys, KEYS, MODIFIER_CODES, MOVE_INTERVAL, PIXELS_PER_LINE, RETRY, mods, norm, btnOf, dragButton, countClick,
    shouldSendMove, scrollDelta, createPointer, keyMessages, retry, pickerStatus, windowLink, pickerLink, sizeLabel };
});
