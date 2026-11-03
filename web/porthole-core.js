(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.PortholeCore = api;
})(typeof self !== 'undefined' ? self : this, function () {
  const KEYS = {KeyA:0,KeyS:1,KeyD:2,KeyF:3,KeyH:4,KeyG:5,KeyZ:6,KeyX:7,KeyC:8,KeyV:9,IntlBackslash:10,KeyB:11,KeyQ:12,KeyW:13,KeyE:14,KeyR:15,KeyY:16,KeyT:17,Digit1:18,Digit2:19,Digit3:20,Digit4:21,Digit6:22,Digit5:23,Equal:24,Digit9:25,Digit7:26,Minus:27,Digit8:28,Digit0:29,BracketRight:30,KeyO:31,KeyU:32,BracketLeft:33,KeyI:34,KeyP:35,Enter:36,KeyL:37,KeyJ:38,Quote:39,KeyK:40,Semicolon:41,Backslash:42,Comma:43,Slash:44,KeyN:45,KeyM:46,Period:47,Tab:48,Space:49,Backquote:50,Backspace:51,Escape:53,MetaRight:54,MetaLeft:55,ShiftLeft:56,CapsLock:57,AltLeft:58,ControlLeft:59,ShiftRight:60,AltRight:61,ControlRight:62,NumpadDecimal:65,NumpadMultiply:67,NumpadAdd:69,NumLock:71,NumpadDivide:75,NumpadEnter:76,NumpadSubtract:78,NumpadEqual:81,Numpad0:82,Numpad1:83,Numpad2:84,Numpad3:85,Numpad4:86,Numpad5:87,Numpad6:88,Numpad7:89,Numpad8:91,Numpad9:92,F5:96,F6:97,F7:98,F3:99,F8:100,F9:101,F11:103,F13:105,F14:107,F10:109,F12:111,F15:113,Help:114,Insert:114,Home:115,PageUp:116,Delete:117,F4:118,End:119,F2:120,PageDown:121,F1:122,ArrowLeft:123,ArrowRight:124,ArrowDown:125,ArrowUp:126};

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
    const w = vw * s, h = vh * s, x0 = r.left + (r.width - w) / 2, y0 = r.top + (r.height - h) / 2;
    let x = (clientX - x0) / w, y = (clientY - y0) / h;
    if (clamp) return { x: Math.min(Math.max(x, 0), 1), y: Math.min(Math.max(y, 0), 1) };
    return (x < 0 || y < 0 || x > 1 || y > 1) ? null : { x, y };
  }

  const btnOf = (e) => e.button === 2 ? 1 : e.button === 1 ? 2 : 0;

  const dragButton = (buttons) => (buttons & 4) ? 1 : (buttons & 2) ? 2 : 0;

  function countClick(prev, now, x, y) {
    const near = Math.abs(x - prev.x) < 5 && Math.abs(y - prev.y) < 5;
    const count = (now - prev.t < 450 && near) ? prev.count + 1 : 1;
    return { t: now, x, y, count };
  }

  function scrollDelta(e) {
    const k = e.deltaMode === 1 ? 16 : 1;
    return { dx: -e.deltaX * k, dy: -e.deltaY * k };
  }

  function keyMessages(e, down, isMac, winId, swallowedUp) {
    const shortcut = isMac ? e.metaKey : e.ctrlKey;
    if (shortcut && e.code === 'KeyV') return { prevent: false, send: [] };
    const code = KEYS[e.code];
    if (code === undefined) {
      return { prevent: true, send: (down && e.key.length === 1) ? [{ t: 'text', win: winId, s: e.key }] : [] };
    }
    if (!down && swallowedUp.delete(e.code)) return { prevent: true, send: [] };
    const msg = { t: 'key', win: winId, code, down, mods: mods(e, isMac), s: e.key.length === 1 ? e.key : undefined };
    const out = [msg];
    if (down && isMac && e.metaKey && !e.code.startsWith('Meta')) {
      out.push({ ...msg, down: false });
      swallowedUp.add(e.code);
    }
    return { prevent: true, send: out };
  }

  return { KEYS, mods, norm, btnOf, dragButton, countClick, scrollDelta, keyMessages };
});
