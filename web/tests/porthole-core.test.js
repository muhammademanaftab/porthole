const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const core = require('../porthole-core.js');
const { KEYS, mods, norm, btnOf, dragButton, countClick, shouldSendMove, scrollDelta, createPointer, keyMessages, retry,
  RETRY, MOVE_INTERVAL, pickerStatus, windowLink, sizeLabel } = core;

const kVK = {
  ANSI_A: 0x00, ANSI_S: 0x01, ANSI_D: 0x02, ANSI_F: 0x03, ANSI_H: 0x04, ANSI_G: 0x05, ANSI_Z: 0x06, ANSI_X: 0x07,
  ANSI_C: 0x08, ANSI_V: 0x09, ISO_Section: 0x0A, ANSI_B: 0x0B, ANSI_Q: 0x0C, ANSI_W: 0x0D, ANSI_E: 0x0E, ANSI_R: 0x0F,
  ANSI_Y: 0x10, ANSI_T: 0x11, ANSI_1: 0x12, ANSI_2: 0x13, ANSI_3: 0x14, ANSI_4: 0x15, ANSI_6: 0x16, ANSI_5: 0x17,
  ANSI_Equal: 0x18, ANSI_9: 0x19, ANSI_7: 0x1A, ANSI_Minus: 0x1B, ANSI_8: 0x1C, ANSI_0: 0x1D, ANSI_RightBracket: 0x1E,
  ANSI_O: 0x1F, ANSI_U: 0x20, ANSI_LeftBracket: 0x21, ANSI_I: 0x22, ANSI_P: 0x23, Return: 0x24, ANSI_L: 0x25, ANSI_J: 0x26,
  ANSI_Quote: 0x27, ANSI_K: 0x28, ANSI_Semicolon: 0x29, ANSI_Backslash: 0x2A, ANSI_Comma: 0x2B, ANSI_Slash: 0x2C,
  ANSI_N: 0x2D, ANSI_M: 0x2E, ANSI_Period: 0x2F, Tab: 0x30, Space: 0x31, ANSI_Grave: 0x32, Delete: 0x33, Escape: 0x35,
  RightCommand: 0x36, Command: 0x37, Shift: 0x38, CapsLock: 0x39, Option: 0x3A, Control: 0x3B, RightShift: 0x3C,
  RightOption: 0x3D, RightControl: 0x3E, ANSI_KeypadDecimal: 0x41, ANSI_KeypadMultiply: 0x43, ANSI_KeypadPlus: 0x45,
  ANSI_KeypadClear: 0x47, ANSI_KeypadDivide: 0x4B, ANSI_KeypadEnter: 0x4C, ANSI_KeypadMinus: 0x4E, ANSI_KeypadEquals: 0x51,
  ANSI_Keypad0: 0x52, ANSI_Keypad1: 0x53, ANSI_Keypad2: 0x54, ANSI_Keypad3: 0x55, ANSI_Keypad4: 0x56, ANSI_Keypad5: 0x57,
  ANSI_Keypad6: 0x58, ANSI_Keypad7: 0x59, ANSI_Keypad8: 0x5B, ANSI_Keypad9: 0x5C, F5: 0x60, F6: 0x61, F7: 0x62, F3: 0x63,
  F8: 0x64, F9: 0x65, F11: 0x67, F13: 0x69, F14: 0x6B, F10: 0x6D, F12: 0x6F, F15: 0x71, Help: 0x72, Home: 0x73,
  PageUp: 0x74, ForwardDelete: 0x75, F4: 0x76, End: 0x77, F2: 0x78, PageDown: 0x79, F1: 0x7A, LeftArrow: 0x7B,
  RightArrow: 0x7C, DownArrow: 0x7D, UpArrow: 0x7E, Function: 0x3F, F17: 0x40, VolumeUp: 0x48, VolumeDown: 0x49, Mute: 0x4A,
  F18: 0x4F, F19: 0x50, F20: 0x5A, JIS_Yen: 0x5D, JIS_Underscore: 0x5E, JIS_KeypadComma: 0x5F, JIS_Eisu: 0x66,
  JIS_Kana: 0x68, F16: 0x6A, ContextualMenu: 0x6E,
};

const browserToCarbon = {
  Backquote: 'ANSI_Grave', Minus: 'ANSI_Minus', Equal: 'ANSI_Equal', BracketLeft: 'ANSI_LeftBracket',
  BracketRight: 'ANSI_RightBracket', Backslash: 'ANSI_Backslash', Semicolon: 'ANSI_Semicolon', Quote: 'ANSI_Quote',
  Comma: 'ANSI_Comma', Period: 'ANSI_Period', Slash: 'ANSI_Slash', IntlBackslash: 'ISO_Section',
  Enter: 'Return', Tab: 'Tab', Space: 'Space', Backspace: 'Delete', Escape: 'Escape', Delete: 'ForwardDelete',
  MetaLeft: 'Command', MetaRight: 'RightCommand', ShiftLeft: 'Shift', ShiftRight: 'RightShift', AltLeft: 'Option',
  AltRight: 'RightOption', ControlLeft: 'Control', ControlRight: 'RightControl', CapsLock: 'CapsLock',
  NumpadDecimal: 'ANSI_KeypadDecimal', NumpadMultiply: 'ANSI_KeypadMultiply', NumpadAdd: 'ANSI_KeypadPlus',
  NumLock: 'ANSI_KeypadClear', NumpadDivide: 'ANSI_KeypadDivide', NumpadEnter: 'ANSI_KeypadEnter',
  NumpadSubtract: 'ANSI_KeypadMinus', NumpadEqual: 'ANSI_KeypadEquals',
  Help: 'Help', Insert: 'Help', Home: 'Home', End: 'End', PageUp: 'PageUp', PageDown: 'PageDown',
  ArrowLeft: 'LeftArrow', ArrowRight: 'RightArrow', ArrowDown: 'DownArrow', ArrowUp: 'UpArrow',
  IntlYen: 'JIS_Yen', IntlRo: 'JIS_Underscore', NumpadComma: 'JIS_KeypadComma', Lang1: 'JIS_Kana', Lang2: 'JIS_Eisu',
  AudioVolumeUp: 'VolumeUp', AudioVolumeDown: 'VolumeDown', AudioVolumeMute: 'Mute', ContextMenu: 'ContextualMenu', Fn: 'Function',
};
for (const c of 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') browserToCarbon[`Key${c}`] = `ANSI_${c}`;
for (let d = 0; d <= 9; d++) { browserToCarbon[`Digit${d}`] = `ANSI_${d}`; browserToCarbon[`Numpad${d}`] = `ANSI_Keypad${d}`; }
for (let f = 1; f <= 20; f++) browserToCarbon[`F${f}`] = `F${f}`;

const ev = (o = {}) => ({ shiftKey: false, altKey: false, ctrlKey: false, metaKey: false, ...o });
const rect = { left: 100, top: 50, width: 800, height: 600 };

test('KEYS matches the Carbon kVK virtual key codes for every mapped browser code', () => {
  const expected = Object.fromEntries(Object.entries(browserToCarbon).map(([code, name]) => [code, kVK[name]]));
  assert.deepEqual(KEYS, expected);
});

test('KEYS leaves browser codes with no Mac virtual key unmapped', () => {
  for (const code of ['PrintScreen', 'ScrollLock', 'Pause', 'BrowserBack', 'MediaPlayPause', 'F21', '']) {
    assert.equal(KEYS[code], undefined, code);
  }
});

test('mods on a Mac: shift 1, ctrl 2, alt 4, meta 8', () => {
  assert.equal(mods(ev(), true), 0);
  assert.equal(mods(ev({ shiftKey: true }), true), 1);
  assert.equal(mods(ev({ ctrlKey: true }), true), 2);
  assert.equal(mods(ev({ altKey: true }), true), 4);
  assert.equal(mods(ev({ metaKey: true }), true), 8);
  assert.equal(mods(ev({ shiftKey: true, ctrlKey: true, altKey: true, metaKey: true }), true), 15);
});

test('mods on Windows/Linux: Ctrl becomes Command and the Windows key becomes Control', () => {
  assert.equal(mods(ev({ ctrlKey: true }), false), 8);
  assert.equal(mods(ev({ metaKey: true }), false), 2);
  assert.equal(mods(ev({ shiftKey: true, ctrlKey: true }), false), 9);
  assert.equal(mods(ev({ altKey: true }), false), 4);
});

test('norm maps the picture centre of a letterboxed video to (0.5, 0.5)', () => {
  assert.deepEqual(norm(500, 350, rect, 1600, 900, false), { x: 0.5, y: 0.5 });
});

test('norm ignores clicks on the letterbox bars', () => {
  assert.equal(norm(500, 124, rect, 1600, 900, false), null);
  assert.equal(norm(500, 576, rect, 1600, 900, false), null);
});

test('norm includes the exact picture edges 0 and 1', () => {
  assert.deepEqual(norm(100, 125, rect, 1600, 900, false), { x: 0, y: 0 });
  assert.deepEqual(norm(900, 575, rect, 1600, 900, false), { x: 1, y: 1 });
});

test('norm clamps to the picture when asked (drags and button-ups)', () => {
  assert.deepEqual(norm(300, 60, rect, 1600, 900, true), { x: 0.25, y: 0 });
  assert.deepEqual(norm(5000, 5000, rect, 1600, 900, true), { x: 1, y: 1 });
  assert.deepEqual(norm(-5000, -5000, rect, 1600, 900, true), { x: 0, y: 0 });
});

test('norm pillarboxes a tall video', () => {
  const r = { left: 0, top: 0, width: 1000, height: 500 };
  assert.deepEqual(norm(375, 0, r, 500, 1000, false), { x: 0, y: 0 });
  assert.deepEqual(norm(562.5, 125, r, 500, 1000, false), { x: 0.75, y: 0.25 });
  assert.equal(norm(374, 0, r, 500, 1000, false), null);
});

test('norm uses the element box before the video size is known', () => {
  assert.deepEqual(norm(300, 200, rect, 0, 0, false), { x: 0.25, y: 0.25 });
});

test('norm on a zero-size element ignores clicks and centres clamped points', () => {
  const flat = { left: 10, top: 10, width: 0, height: 0 };
  assert.equal(norm(10, 10, flat, 0, 0, false), null);
  assert.deepEqual(norm(10, 10, flat, 0, 0, true), { x: 0.5, y: 0.5 });
  assert.equal(norm(10, 10, flat, 1600, 900, false), null);
  assert.deepEqual(norm(10, 10, { left: 0, top: 0, width: 800, height: 0 }, 1600, 900, true), { x: 0.5, y: 0.5 });
});

test('btnOf maps DOM buttons to the protocol: left 0, right 1, middle 2', () => {
  assert.equal(btnOf({ button: 0 }), 0);
  assert.equal(btnOf({ button: 2 }), 1);
  assert.equal(btnOf({ button: 1 }), 2);
});

test('btnOf ignores Back and Forward buttons instead of clicking', () => {
  assert.equal(btnOf({ button: 3 }), null);
  assert.equal(btnOf({ button: 4 }), null);
  assert.equal(btnOf({ button: -1 }), null);
});

test('dragButton reads the 1<<event.button mask: bit 4 (right) wins, then bit 2 (middle), else left', () => {
  assert.equal(dragButton(1), 0);
  assert.equal(dragButton(4), 1);
  assert.equal(dragButton(2), 2);
  assert.equal(dragButton(4 | 2 | 1), 1);
  assert.equal(dragButton(2 | 1), 2);
  assert.equal(dragButton(0), 0);
});

test('countClick counts quick nearby presses as double and triple clicks', () => {
  let c = countClick({ t: 0, x: 0, y: 0, count: 0 }, 1000, 200, 200);
  assert.deepEqual(c, { t: 1000, x: 200, y: 200, count: 1 });
  c = countClick(c, 1300, 204, 196);
  assert.equal(c.count, 2);
  c = countClick(c, 1749, 204, 196);
  assert.equal(c.count, 3);
});

test('countClick restarts at 450 ms or more apart', () => {
  const first = { t: 1000, x: 200, y: 200, count: 1 };
  assert.equal(countClick(first, 1450, 200, 200).count, 1);
  assert.equal(countClick(first, 1449.9, 200, 200).count, 2);
});

test('countClick restarts when the pointer moved 5 px or more on either axis', () => {
  const first = { t: 1000, x: 200, y: 200, count: 1 };
  assert.equal(countClick(first, 1100, 205, 200).count, 1);
  assert.equal(countClick(first, 1100, 200, 195).count, 1);
  assert.equal(countClick(first, 1100, 204.9, 195.1).count, 2);
});

test('move throttle: 16 ms apart is sent, less is dropped', () => {
  assert.equal(MOVE_INTERVAL, 16);
  assert.equal(shouldSendMove(1016, 1000), true);
  assert.equal(shouldSendMove(1015.9, 1000), false);
});

test('scrollDelta inverts pixel-mode wheel deltas', () => {
  assert.deepEqual(scrollDelta({ deltaX: 3, deltaY: -10, deltaMode: 0 }), { dx: -3, dy: 10 });
});

test('scrollDelta turns line-mode deltas into 16 px per line, same as the Mac viewer', () => {
  assert.deepEqual(scrollDelta({ deltaX: -1, deltaY: 3, deltaMode: 1 }), { dx: 16, dy: -48 });
});

test('scrollDelta passes page-mode deltas through unscaled', () => {
  assert.deepEqual(scrollDelta({ deltaX: 2, deltaY: 1, deltaMode: 2 }), { dx: -2, dy: -1 });
});

const geom = { rect: { left: 0, top: 0, width: 800, height: 600 }, vw: 1600, vh: 900 };
const pev = (button, clientX, clientY, o = {}) => ev({ button, clientX, clientY, ...o });

test('pointer: press in the picture sends a reliable down with click count and mods', () => {
  const p = createPointer(7, true);
  const out = p.down(pev(0, 400, 300, { metaKey: true }), geom, 1000);
  assert.deepEqual(out, { msg: { t: 'mouse', win: 7, kind: 'down', btn: 0, x: 0.5, y: 0.5, clicks: 1, mods: 8 }, reliable: true });
  assert.equal(p.buttons, 1);
});

test('pointer: press on the letterbox bar or with Back/Forward is ignored and holds nothing', () => {
  const p = createPointer(7, true);
  assert.equal(p.down(pev(0, 400, 50), geom, 1000), null);
  assert.equal(p.down(pev(3, 400, 300), geom, 1000), null);
  assert.equal(p.up(pev(3, 400, 300), geom), null);
  assert.equal(p.buttons, 0);
});

test('pointer: release is skipped unless that button is held, and clamps outside the picture', () => {
  const p = createPointer(7, true);
  assert.equal(p.up(pev(2, 400, 300), geom), null);
  p.down(pev(2, 400, 300), geom, 1000);
  const out = p.up(pev(2, 900, 10), geom);
  assert.deepEqual(out, { msg: { t: 'mouse', win: 7, kind: 'up', btn: 1, x: 1, y: 0, clicks: 1, mods: 0 }, reliable: true });
  assert.equal(p.buttons, 0);
  assert.equal(p.up(pev(2, 400, 300), geom), null);
});

test('pointer: hover moves are lossy, button 0, without clicks', () => {
  const p = createPointer(7, true);
  const out = p.move(pev(0, 200, 187.5), geom, 1000);
  assert.deepEqual(out, { msg: { t: 'mouse', win: 7, kind: 'move', btn: 0, x: 0.25, y: 0.25, mods: 0 }, reliable: false });
  assert.equal('clicks' in out.msg, false);
});

test('pointer: moves with a button held are reliable drags, clamped, using the held button', () => {
  const p = createPointer(7, true);
  p.down(pev(2, 400, 300), geom, 1000);
  const out = p.move(pev(-1, 400, 5), geom, 2000);
  assert.deepEqual(out, { msg: { t: 'mouse', win: 7, kind: 'drag', btn: 1, x: 0.5, y: 0, mods: 0 }, reliable: true });
});

test('pointer: moves closer than 16 ms are dropped, and hover off the picture sends nothing', () => {
  const p = createPointer(7, true);
  assert.notEqual(p.move(pev(0, 400, 300), geom, 1000), null);
  assert.equal(p.move(pev(0, 410, 300), geom, 1010), null);
  assert.equal(p.move(pev(0, 400, 10), geom, 1100), null);
});

test('pointer: a quick second press counts as a double click and the release reports it', () => {
  const p = createPointer(7, false);
  p.down(pev(0, 400, 300), geom, 1000); p.up(pev(0, 400, 300), geom);
  assert.equal(p.down(pev(0, 401, 301), geom, 1200).msg.clicks, 2);
  assert.equal(p.up(pev(0, 401, 301), geom).msg.clicks, 2);
});

const key = (code, k, o = {}) => ev({ code, key: k, ...o });

test('keyMessages: plain letter sends one key message with its character', () => {
  const r = keyMessages(key('KeyA', 'a'), true, true, 7, new Set());
  assert.equal(r.prevent, true);
  assert.deepEqual(r.send, [{ t: 'key', win: 7, code: 0, down: true, mods: 0, s: 'a' }]);
});

test('keyMessages: named keys omit s on the wire', () => {
  const r = keyMessages(key('ArrowLeft', 'ArrowLeft'), false, true, 7, new Set());
  assert.equal(JSON.stringify(r.send[0]), '{"t":"key","win":7,"code":123,"down":false,"mods":0}');
});

test('keyMessages: Option-composed unicode keeps the key code, character and option bit', () => {
  const r = keyMessages(key('KeyE', 'é', { altKey: true }), true, true, 7, new Set());
  assert.deepEqual(r.send, [{ t: 'key', win: 7, code: 14, down: true, mods: 4, s: 'é' }]);
});

test('keyMessages: Cmd shortcuts on a Mac send down and up at once and swallow the late keyup', () => {
  const swallowed = new Set();
  const down = keyMessages(key('KeyC', 'c', { metaKey: true }), true, true, 7, swallowed);
  assert.deepEqual(down.send, [
    { t: 'key', win: 7, code: 8, down: true, mods: 8, s: 'c' },
    { t: 'key', win: 7, code: 8, down: false, mods: 8, s: 'c' },
  ]);
  assert.ok(swallowed.has('KeyC'));
  const up = keyMessages(key('KeyC', 'c'), false, true, 7, swallowed);
  assert.deepEqual(up, { prevent: true, send: [] });
  assert.equal(swallowed.size, 0);
  const again = keyMessages(key('KeyC', 'c'), false, true, 7, swallowed);
  assert.equal(again.send.length, 1);
});

test('keyMessages: auto-repeated Cmd+Z sends a down/up pair per repeat and swallows the one real keyup', () => {
  const swallowed = new Set();
  const sent = [];
  for (const down of [true, true, false]) sent.push(...keyMessages(key('KeyZ', 'z', { metaKey: down }), down, true, 7, swallowed).send);
  assert.deepEqual(sent.map(m => [m.code, m.down]), [[6, true], [6, false], [6, true], [6, false]]);
  assert.equal(swallowed.size, 0);
});

test('keyMessages: modifier keys pressed while Cmd is held are not doubled', () => {
  for (const code of ['MetaLeft', 'MetaRight', 'ShiftLeft', 'ShiftRight', 'AltLeft', 'AltRight', 'ControlLeft', 'ControlRight', 'CapsLock']) {
    const swallowed = new Set();
    const r = keyMessages(key(code, 'Shift', { metaKey: true }), true, true, 7, swallowed);
    assert.equal(r.send.length, 1, code);
    assert.equal(r.send[0].down, true, code);
    assert.equal(swallowed.size, 0, code);
  }
});

test('keyMessages: Ctrl+C on Windows is one key message with the Command bit', () => {
  const swallowed = new Set();
  const r = keyMessages(key('KeyC', 'c', { ctrlKey: true }), true, false, 7, swallowed);
  assert.deepEqual(r.send, [{ t: 'key', win: 7, code: 8, down: true, mods: 8, s: 'c' }]);
  assert.equal(swallowed.size, 0);
});

test('keyMessages: the Windows key plus a letter is not doubled off a Mac', () => {
  const swallowed = new Set();
  const r = keyMessages(key('KeyE', 'e', { metaKey: true }), true, false, 7, swallowed);
  assert.deepEqual(r.send, [{ t: 'key', win: 7, code: 14, down: true, mods: 2, s: 'e' }]);
  assert.equal(swallowed.size, 0);
});

test('keyMessages: paste shortcut is left to the browser paste event', () => {
  assert.deepEqual(keyMessages(key('KeyV', 'v', { metaKey: true }), true, true, 7, new Set()), { prevent: false, send: [] });
  assert.deepEqual(keyMessages(key('KeyV', 'v', { ctrlKey: true }), true, false, 7, new Set()), { prevent: false, send: [] });
  assert.equal(keyMessages(key('KeyV', 'v', { ctrlKey: true }), true, true, 7, new Set()).send[0].code, 9);
  assert.equal(keyMessages(key('KeyV', 'v', { metaKey: true }), true, false, 7, new Set()).send[0].code, 9);
});

test('keyMessages: unmapped keys with a printable character are sent as text on keydown only', () => {
  assert.deepEqual(keyMessages(key('', '¥'), true, true, 7, new Set()), { prevent: true, send: [{ t: 'text', win: 7, s: '¥' }] });
  assert.deepEqual(keyMessages(key('', '¥'), false, true, 7, new Set()), { prevent: true, send: [] });
  assert.deepEqual(keyMessages(key('MediaPlayPause', 'MediaPlayPause'), true, true, 7, new Set()), { prevent: true, send: [] });
});

test('keyMessages: an emoji from an unmapped key (two UTF-16 units) is still sent as text', () => {
  assert.deepEqual(keyMessages(key('', '😀'), true, true, 7, new Set()).send, [{ t: 'text', win: 7, s: '😀' }]);
});

test('retry calls until done or out of attempts, sleeping the given interval', async () => {
  const sleeps = [];
  let calls = 0;
  await retry(() => calls++, () => false, 1500, 10, async (ms) => { sleeps.push(ms); });
  assert.equal(calls, 10);
  assert.deepEqual(sleeps, Array(10).fill(1500));
  calls = 0;
  await retry(() => calls++, () => calls >= 3, 2000, 5, async () => {});
  assert.equal(calls, 3);
});

test('retry policies match the Mac viewer: list 10 x 1 s, open 5 x 2 s', () => {
  assert.deepEqual(RETRY, { list: { every: 1000, times: 10 }, open: { every: 2000, times: 5 } });
});

test('pickerStatus says window or windows', () => {
  assert.equal(pickerStatus(0), 'No windows to share on the host.');
  assert.equal(pickerStatus(1), '1 window on the host. Each opens in its own tab.');
  assert.equal(pickerStatus(3), '3 windows on the host. Each opens in its own tab.');
});

test('windowLink percent-encodes the password', () => {
  assert.equal(windowLink('a b&c=d#e/ő', 42), '?pw=a%20b%26c%3Dd%23e%2F%C5%91&win=42');
});

test('sizeLabel rounds the point size', () => {
  assert.equal(sizeLabel(1279.6, 720.4), '1280×720');
});

test('the module also installs window.PortholeCore when loaded by a plain <script> tag', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'porthole-core.js'), 'utf8');
  const ctx = vm.createContext({});
  ctx.self = ctx;
  vm.runInContext(src, ctx);
  assert.equal(ctx.PortholeCore.KEYS.KeyA, 0);
});

test('index.html loads porthole-core.js first, uses exactly the shared helpers and keeps no private copies', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const tag = html.indexOf('<script src="porthole-core.js"></script>');
  assert.ok(tag > 0);
  assert.ok(tag < html.indexOf('<script>'));
  const used = [...new Set([...html.matchAll(/\bPC\.(\w+)/g)].map(m => m[1]))].sort();
  assert.deepEqual(used, ['CLIP_TOPIC', 'ICON_TOPIC', 'RETRY', 'THUMB_TOPIC', 'clipFits', 'countLabel', 'createPointer', 'ensureRandomUUID', 'filterWindows', 'hostReachable', 'iconRequests', 'isAudioTrack', 'keyMessages', 'mods', 'nextReconnectAttempt', 'norm', 'pasteKeys', 'pickerLink', 'pickerNotice', 'portalTitle', 'reconnectDelay', 'retry', 'scrollDelta', 'sizeLabel', 'soundLabel', 'streamWindow', 'windowLink']);
  for (const name of used) assert.notEqual(core[name], undefined, name);
  for (const copy of ['function mods', 'KEYS =', 'deltaMode', 'Math.min(r.width', 'function retry', '&win=${', 'Math.round(w.w)', 'normalize(', '.every(t']) {
    assert.equal(html.includes(copy), false, copy);
  }
});

test('clipboard topic matches the Swift side', () => {
  const swift = fs.readFileSync(path.join(__dirname, '../../Sources/PortholeCore/Clipboard.swift'), 'utf8');
  assert.match(swift, new RegExp(`clipboardTopic = "${core.CLIP_TOPIC}"`));
  assert.match(swift, new RegExp(`maxBytes = ${core.CLIP_MAX_BYTES.toLocaleString('en-US').replace(/,/g, '_')}`));
});

test('clipFits accepts normal text and rejects empty, non-strings and oversize', () => {
  assert.equal(core.clipFits('hello'), true);
  assert.equal(core.clipFits(''), false);
  assert.equal(core.clipFits(undefined), false);
  assert.equal(core.clipFits('a'.repeat(core.CLIP_MAX_BYTES)), true);
  assert.equal(core.clipFits('a'.repeat(core.CLIP_MAX_BYTES + 1)), false);
  assert.equal(core.clipFits('é'.repeat(core.CLIP_MAX_BYTES / 2 + 1)), false);
});

test('pasteKeys presses Command, taps V, then releases Command on the host', () => {
  assert.deepEqual(core.pasteKeys(7), [
    { t: 'key', win: 7, code: kVK.Command, down: true, mods: 8 },
    { t: 'key', win: 7, code: kVK.ANSI_V, down: true, mods: 8 },
    { t: 'key', win: 7, code: kVK.ANSI_V, down: false, mods: 8 },
    { t: 'key', win: 7, code: kVK.Command, down: false, mods: 0 },
  ]);
});

test('audio track name matches the Swift side', () => {
  const swift = fs.readFileSync(path.join(__dirname, '../../Sources/PortholeCore/Message.swift'), 'utf8');
  assert.match(swift, new RegExp(`audioTrackName = "${core.AUDIO_TRACK}"`));
});

test('isAudioTrack accepts only the host audio mix', () => {
  assert.equal(core.isAudioTrack('aud-mix'), true);
  for (const name of ['win-7', 'aud-', 'Aud-mix', 'aud-mix ', '', undefined, null]) assert.equal(core.isAudioTrack(name), false, String(name));
});

test('soundLabel asks for a click until the browser allows playback, then shows the mute state', () => {
  assert.equal(core.soundLabel(false, false), 'Click for sound');
  assert.equal(core.soundLabel(false, true), 'Click for sound');
  assert.equal(core.soundLabel(true, false), 'Sound on');
  assert.equal(core.soundLabel(true, true), 'Sound off');
});

test('index.html declares an empty icon so the browser does not ask for /favicon.ico', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const head = html.slice(0, html.indexOf('</head>'));
  assert.match(head, /<link rel="icon" href="data:,">/);
});

test('randomUUID makes RFC 4122 version 4 ids from getRandomValues', () => {
  const fake = { getRandomValues: (a) => { a.fill(0xff); return a; } };
  assert.equal(core.randomUUID(fake), 'ffffffff-ffff-4fff-bfff-ffffffffffff');
  const zero = { getRandomValues: (a) => a };
  assert.equal(core.randomUUID(zero), '00000000-0000-4000-8000-000000000000');
  const ids = new Set(Array.from({ length: 200 }, () => core.randomUUID(require('node:crypto').webcrypto)));
  assert.equal(ids.size, 200);
  for (const id of ids) assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test('ensureRandomUUID fills in randomUUID only where the browser lacks it (plain http pages)', () => {
  const insecure = { getRandomValues: (a) => a };
  core.ensureRandomUUID(insecure);
  assert.equal(typeof insecure.randomUUID, 'function');
  assert.match(insecure.randomUUID(), /^00000000-0000-4000-8000-000000000000$/);
  const native = () => 'native';
  const secure = { getRandomValues: (a) => a, randomUUID: native };
  core.ensureRandomUUID(secure);
  assert.equal(secure.randomUUID, native);
  assert.equal(core.ensureRandomUUID(undefined), undefined);
});

test('reconnectDelay retries a lost connection with backoff and gives up after the last delay', () => {
  assert.equal(core.reconnectDelay(0, 1), 1000);
  assert.equal(core.reconnectDelay(14, 2), 2000);
  assert.equal(core.reconnectDelay(undefined, 3), 4000);
  assert.equal(core.reconnectDelay(3, core.RECONNECT_DELAYS.length), 30000);
  assert.equal(core.reconnectDelay(0, core.RECONNECT_DELAYS.length + 1), null);
  assert.equal(core.reconnectDelay(0, 0), null);
});

test('reconnectDelay never reconnects after the viewer left, was removed, replaced, or the room ended', () => {
  for (const reason of [1, 2, 4, 5, 10]) assert.equal(core.reconnectDelay(reason, 1), null, `reason ${reason}`);
});

test('nextReconnectAttempt counts up until a connection stays up for 30 s', () => {
  assert.equal(core.STABLE_CONNECTION, 30000);
  assert.equal(core.nextReconnectAttempt(null, 0), 1);
  assert.equal(core.nextReconnectAttempt('3', 5000), 4);
  assert.equal(core.nextReconnectAttempt(3, 29999), 4);
  assert.equal(core.nextReconnectAttempt('7', 30000), 1);
  assert.equal(core.nextReconnectAttempt('garbage', 0), 1);
});

test('a connection that keeps dropping right after it comes back runs out of attempts', () => {
  let n = null, waits = 0;
  for (;;) {
    n = core.nextReconnectAttempt(n, 2000);
    if (core.reconnectDelay(0, n) === null) break;
    waits++;
  }
  assert.equal(waits, core.RECONNECT_DELAYS.length);
});

test('hostReachable probes /hello and treats errors and non-200 as unreachable', async () => {
  const asked = [];
  assert.equal(await core.hostReachable(async (u, o) => { asked.push([u, o.cache]); return { ok: true }; }), true);
  assert.deepEqual(asked, [['/hello', 'no-store']]);
  assert.equal(await core.hostReachable(async () => ({ ok: false })), false);
  assert.equal(await core.hostReachable(async () => { throw new TypeError('Failed to fetch'); }), false);
  assert.equal(await core.hostReachable(async () => undefined), false);
});

test('index.html probes the host before reloading and keeps retrying when connect fails mid-reconnect', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  assert.match(html, /if \(await PC\.hostReachable\(fetch\)\) location\.reload\(\); else scheduleReconnect\(0, 0\);/);
  assert.match(html, /PC\.nextReconnectAttempt\(sessionStorage\.getItem\('reconnects'\), upForMs\)/);
  assert.match(html, /if \(sessionStorage\.getItem\('reconnects'\)\) scheduleReconnect\(0, 0\); else showPassword/);
  const reloads = html.split('\n').filter(l => l.includes('location.reload()'));
  assert.equal(reloads.length, 2);
  assert.ok(reloads.some(l => l.includes("$('oretry').addEventListener('click'")));
  assert.ok(html.indexOf('connectedAt = Date.now()') > html.indexOf('await room.connect(url, token'));
});

const sample = [
  { id: 1, app: 'TextEdit', title: 'Shopping List', w: 640, h: 480 },
  { id: 2, app: 'Safari', title: 'Caf\u00e9 menu', w: 1280, h: 800 },
  { id: 3, app: 'Finder', title: '', w: 900, h: 600 },
];

test('filterWindows matches app and title words, ignoring case and accents, like the Mac picker', () => {
  const ids = (q) => core.filterWindows(sample, q).map(w => w.id);
  assert.deepEqual(ids(''), [1, 2, 3]);
  assert.deepEqual(ids('   '), [1, 2, 3]);
  assert.deepEqual(ids('safari'), [2]);
  assert.deepEqual(ids('LIST'), [1]);
  assert.deepEqual(ids('cafe'), [2]);
  assert.deepEqual(ids('text shopping'), [1]);
  assert.deepEqual(ids('menu safari'), [2]);
  assert.deepEqual(ids('text zebra'), []);
  assert.deepEqual(ids('ind'), [3]);
  assert.notEqual(core.filterWindows(sample, ''), sample);
});

test('pickerNotice mirrors the Mac picker states', () => {
  assert.equal(core.pickerNotice(false, 0, 0, '', null).kind, 'loading');
  assert.equal(core.pickerNotice(true, 0, 0, '', null).kind, 'empty');
  assert.equal(core.pickerNotice(true, 0, 0, '', core.LOCKED_LIST).kind, 'locked');
  assert.equal(core.pickerNotice(false, 0, 0, '', core.LOCKED_LIST).kind, 'locked');
  assert.deepEqual(core.pickerNotice(false, 0, 0, '', 'Disconnected'), { kind: 'error', title: "Can't Show Windows", message: 'Disconnected' });
  assert.equal(core.pickerNotice(true, 0, 0, '', '').kind, 'empty');
  assert.equal(core.pickerNotice(true, 3, 3, '', 'Disconnected'), null);
  assert.equal(core.pickerNotice(true, 3, 0, ' zebra ', null).message, 'No window matches \u201Czebra\u201D.');
  assert.equal(core.pickerNotice(true, 3, 1, 'x', null), null);
});

test('the locked-screen text and topics match the Swift side', () => {
  const picker = fs.readFileSync(path.join(__dirname, '../../Sources/PortholeCore/Picker.swift'), 'utf8');
  assert.ok(picker.includes(`public static let list = "${core.LOCKED_LIST}"`));
  assert.match(picker, new RegExp(`thumbTopic = "${core.THUMB_TOPIC}"`));
  const tile = fs.readFileSync(path.join(__dirname, '../../Sources/PortholeCore/Tile.swift'), 'utf8');
  assert.match(tile, new RegExp(`iconTopic = "${core.ICON_TOPIC}"`));
  const message = fs.readFileSync(path.join(__dirname, '../../Sources/PortholeCore/Message.swift'), 'utf8');
  assert.match(message, /case icon, thumb/);
});

test('countLabel and portalTitle', () => {
  assert.equal(core.countLabel(1, 1), '1 window');
  assert.equal(core.countLabel(4, 4), '4 windows');
  assert.equal(core.countLabel(4, 2), '2 of 4 windows');
  assert.equal(core.portalTitle(sample[0]), 'TextEdit \u2014 Shopping List');
  assert.equal(core.portalTitle(sample[2]), 'Finder');
});

test('streamWindow reads the win attribute the host puts on icon and thumbnail streams', () => {
  assert.equal(core.streamWindow({ win: '42' }), 42);
  assert.equal(core.streamWindow({ win: '4294967295' }), 4294967295);
  for (const bad of [{}, null, undefined, { win: '' }, { win: '-1' }, { win: '07' }, { win: '1.5' }, { win: '4294967296' }, { win: 7 }]) {
    assert.equal(core.streamWindow(bad), null, JSON.stringify(bad));
  }
});

test('iconRequests asks once per app, in list order, up to a limit', () => {
  const list = [...sample, { id: 4, app: 'TextEdit', title: 'Other', w: 1, h: 1 }];
  assert.deepEqual(core.iconRequests(list), [1, 2, 3]);
  assert.deepEqual(core.iconRequests(list, 2), [1, 2]);
  assert.deepEqual(core.iconRequests([]), []);
});

test('pickerLink goes back to the window list with the same password', () => {
  assert.equal(core.pickerLink('a b&c'), '?pw=a%20b%26c');
  assert.equal(core.windowLink('a b&c', 7), core.pickerLink('a b&c') + '&win=7');
});
