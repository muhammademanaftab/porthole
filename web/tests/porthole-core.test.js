const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const core = require('../porthole-core.js');
const { KEYS, mods, norm, btnOf, dragButton, countClick, scrollDelta, keyMessages } = core;

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
  RightArrow: 0x7C, DownArrow: 0x7D, UpArrow: 0x7E,
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
};
for (const c of 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') browserToCarbon[`Key${c}`] = `ANSI_${c}`;
for (let d = 0; d <= 9; d++) { browserToCarbon[`Digit${d}`] = `ANSI_${d}`; browserToCarbon[`Numpad${d}`] = `ANSI_Keypad${d}`; }
for (let f = 1; f <= 15; f++) browserToCarbon[`F${f}`] = `F${f}`;

const ev = (o = {}) => ({ shiftKey: false, altKey: false, ctrlKey: false, metaKey: false, ...o });
const rect = { left: 100, top: 50, width: 800, height: 600 };

test('KEYS matches the Carbon kVK virtual key codes for every mapped browser code', () => {
  const expected = Object.fromEntries(Object.entries(browserToCarbon).map(([code, name]) => [code, kVK[name]]));
  assert.deepEqual(KEYS, expected);
});

test('KEYS leaves keys without a Mac virtual key unmapped so they fall back to text', () => {
  for (const code of ['F16', 'IntlRo', 'IntlYen', 'AudioVolumeUp', 'Fn', 'ContextMenu', 'PrintScreen']) {
    assert.equal(KEYS[code], undefined, code);
  }
});

test('KEYS modifier keys all land in the host flagsChanged range 54...63', () => {
  for (const code of ['MetaLeft', 'MetaRight', 'ShiftLeft', 'ShiftRight', 'AltLeft', 'AltRight', 'ControlLeft', 'ControlRight', 'CapsLock']) {
    assert.ok(KEYS[code] >= 54 && KEYS[code] <= 63, code);
  }
  assert.equal(Object.values(KEYS).filter(v => v >= 54 && v <= 63).length, 9);
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

test('btnOf maps DOM buttons to the protocol: left 0, right 1, middle 2', () => {
  assert.equal(btnOf({ button: 0 }), 0);
  assert.equal(btnOf({ button: 2 }), 1);
  assert.equal(btnOf({ button: 1 }), 2);
  assert.equal(btnOf({ button: 3 }), 0);
});

test('dragButton picks right, then middle, then left from the held-buttons mask', () => {
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

test('scrollDelta inverts the wheel and scales line mode by 16 px', () => {
  assert.deepEqual(scrollDelta({ deltaX: 3, deltaY: -10, deltaMode: 0 }), { dx: -3, dy: 10 });
  assert.deepEqual(scrollDelta({ deltaX: -1, deltaY: 3, deltaMode: 1 }), { dx: 16, dy: -48 });
  assert.deepEqual(scrollDelta({ deltaX: 2, deltaY: 1, deltaMode: 2 }), { dx: -2, dy: -1 });
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

test('keyMessages: the Command key itself is not doubled', () => {
  const swallowed = new Set();
  const r = keyMessages(key('MetaLeft', 'Meta', { metaKey: true }), true, true, 7, swallowed);
  assert.deepEqual(r.send, [{ t: 'key', win: 7, code: 55, down: true, mods: 8, s: undefined }]);
  assert.equal(swallowed.size, 0);
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
  assert.deepEqual(keyMessages(key('IntlYen', '¥'), true, true, 7, new Set()), { prevent: true, send: [{ t: 'text', win: 7, s: '¥' }] });
  assert.deepEqual(keyMessages(key('IntlYen', '¥'), false, true, 7, new Set()), { prevent: true, send: [] });
  assert.deepEqual(keyMessages(key('AudioVolumeUp', 'AudioVolumeUp'), true, true, 7, new Set()), { prevent: true, send: [] });
});

test('the module also installs window.PortholeCore when loaded by a plain <script> tag', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'porthole-core.js'), 'utf8');
  const ctx = vm.createContext({});
  ctx.self = ctx;
  vm.runInContext(src, ctx);
  assert.equal(ctx.PortholeCore.KEYS.KeyA, 0);
  assert.equal(ctx.PortholeCore.mods({ shiftKey: true, metaKey: true }, true), 9);
});

test('index.html loads porthole-core.js before its own script and only uses exported helpers', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const tag = html.indexOf('<script src="porthole-core.js"></script>');
  assert.ok(tag > 0);
  assert.ok(tag < html.indexOf('<script>'));
  const used = new Set([...html.matchAll(/\bPC\.(\w+)/g)].map(m => m[1]));
  assert.ok(used.size >= 7);
  for (const name of used) assert.equal(typeof core[name], 'function', name);
});
