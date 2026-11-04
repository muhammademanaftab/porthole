const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const core = require('../porthole-core.js');

test('guest links keep the share token and never carry a password', () => {
  assert.equal(core.guestWindowLink('a+b/c', 42), '?share=a%2Bb%2Fc&win=42');
  assert.equal(core.guestPickerLink('tok_-9'), '?share=tok_-9');
  assert.ok(!core.guestWindowLink('t', 1).includes('pw='));
});

test('token path: a share token asks for a guest token with the client id', () => {
  assert.equal(core.tokenPath({ share: 'abc', cid: 'a1b2c3d4' }), '/token?share=abc&cid=a1b2c3d4&name=browser');
  assert.equal(core.tokenPath({ share: 'abc', cid: 'BAD!' }), '/token?share=abc&name=browser');
  assert.equal(core.tokenPath({ pw: 'p+w' }), '/token?pw=p%2Bw&name=browser');
});

test('client id is 12 lowercase hex characters the host accepts', () => {
  const id = core.clientId(crypto.webcrypto);
  assert.match(id, /^[0-9a-f]{12}$/);
  assert.notEqual(id, core.clientId(crypto.webcrypto));
});

test('view-only guests send no input; controlling guests and owners do', () => {
  assert.equal(core.mayInput(null, false), true);
  assert.equal(core.mayInput({ link: 'x' }, false), false);
  assert.equal(core.mayInput({ link: 'x' }, true), true);
});

test('ask button: shown for a view-only guest, busy while asking, hidden once controlling', () => {
  assert.deepEqual(core.askButton(null, false, false), { show: false, text: '', disabled: true });
  assert.deepEqual(core.askButton({}, false, false), { show: true, text: 'Ask to Control', disabled: false });
  assert.deepEqual(core.askButton({}, false, true), { show: true, text: 'Ask…'.replace('Ask', 'Asking'), disabled: true });
  assert.equal(core.askButton({}, true, false).show, false);
});

test('guest notice says view only until control is granted', () => {
  assert.match(core.guestNotice({}, false), /view only/);
  assert.match(core.guestNotice({}, true), /type and click/);
  assert.match(core.guestNotice(null, false), /control it/);
});

test('an expired link is explained, a wrong password is not', () => {
  assert.equal(core.linkRefusal(403, { expired: true, error: 'This link has expired.' }), 'This link has expired.');
  assert.equal(core.linkRefusal(403, { error: 'wrong password' }), null);
  assert.equal(core.linkRefusal(200, { expired: true }), null);
});

test('page gates every input path on mayInput', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  for (const marker of ["video.addEventListener('pointerdown'", 'function pointerUp(e)', "video.addEventListener('pointermove'",
    "video.addEventListener('wheel'", 'function onKey(e, down)', "window.addEventListener('paste'", 'function fitToTab()']) {
    const at = html.indexOf(marker);
    assert.ok(at >= 0, marker);
    assert.ok(html.slice(at, at + 260).includes('allowed()'), `${marker} checks allowed()`);
  }
  assert.ok(html.includes("send({ t: 'ask', win: winId })"));
  assert.ok(html.includes("m.t === 'control'"));
  assert.ok(html.includes("if (topic !== 'porthole' || !participant || participant.identity !== 'host') return;"));
});
