const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const core = require('../porthole-core.js');

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const swiftUnlock = fs.readFileSync(path.join(__dirname, '../../Sources/PortholeCore/Unlock.swift'), 'utf8');
const swiftPicker = fs.readFileSync(path.join(__dirname, '../../Sources/PortholeCore/Picker.swift'), 'utf8');
const swiftMessage = fs.readFileSync(path.join(__dirname, '../../Sources/PortholeCore/Message.swift'), 'utf8');

test('unlockMessage puts the password in s under the unlock kind the host knows', () => {
  assert.deepEqual(core.unlockMessage('hunter2'), { t: 'unlock', s: 'hunter2' });
  assert.match(swiftMessage, /case unlock\n/);
});

test('unlockMessage refuses what the host would refuse', () => {
  for (const bad of ['', undefined, null, 42, 'a\nb', 'a\rb', 'a\tb', 'a\u0000b', 'a b', 'x'.repeat(core.UNLOCK_MAX + 1)]) {
    assert.equal(core.unlockMessage(bad), null, JSON.stringify(bad));
  }
  assert.deepEqual(core.unlockMessage('pässwörd 日本 👍'), { t: 'unlock', s: 'pässwörd 日本 👍' });
  assert.notEqual(core.unlockMessage('x'.repeat(core.UNLOCK_MAX)), null);
  assert.match(swiftUnlock, new RegExp(`maxLength = ${core.UNLOCK_MAX}\\b`));
});

test('only owners get the unlock form, never share-link guests', () => {
  assert.equal(core.mayUnlock(null), true);
  assert.equal(core.mayUnlock({ control: true }), false);
  assert.equal(core.mayUnlock({}), false);
  assert.ok(html.includes("if (n.kind === 'locked' && PC.mayUnlock(guest))"));
});

test('both lock notices count, and match the Swift text', () => {
  assert.equal(core.isLockNotice(core.LOCKED_LIST), true);
  assert.equal(core.isLockNotice(core.LOCKED_CONTROL), true);
  assert.equal(core.isLockNotice('Disconnected'), false);
  assert.ok(swiftPicker.includes(`public static let control = "${core.LOCKED_CONTROL}"`));
});

test('unlockOutcome reads on and msg from the host reply', () => {
  assert.deepEqual(core.unlockOutcome({ t: 'unlock', on: true, msg: 'This Mac is unlocked.' }), { ok: true, text: 'This Mac is unlocked.' });
  assert.deepEqual(core.unlockOutcome({ t: 'unlock', on: false, msg: 'Wait 3 s before trying again.' }), { ok: false, text: 'Wait 3 s before trying again.' });
  assert.equal(core.unlockOutcome({ t: 'unlock' }).ok, false);
  assert.equal(core.unlockOutcome(null).ok, false);
});

test('page texts match the Swift side', () => {
  assert.ok(swiftUnlock.includes(`public static let working = "${core.UNLOCK_WORKING.replace('…', '…')}"`));
  assert.ok(swiftUnlock.includes(`public static let noAnswer = "${core.UNLOCK_NO_ANSWER}"`));
  assert.ok(swiftUnlock.includes('Porthole types it into the lock screen and doesn\'t keep it.'));
  assert.ok(core.UNLOCK_HINT.endsWith('Porthole types it into the lock screen and doesn\'t keep it.'));
  assert.equal(core.UNLOCK_ANSWER_MS, 25000);
  assert.match(swiftUnlock, /answerTimeout: TimeInterval = 25\n/);
});

test('the page clears the field, sends once, waits for the answer and refreshes after an unlock', () => {
  const form = html.slice(html.indexOf('function unlockForm()'), html.indexOf('function iconFor('));
  assert.ok(form.includes("input.type = 'password'"));
  assert.ok(form.includes("input.autocomplete = 'off'"));
  assert.ok(form.includes("const msg = PC.unlockMessage(input.value);\n    input.value = '';"));
  assert.ok(form.includes('if (!msg || !live()) return;'));
  assert.ok(form.includes('b.disabled = unlocking'));
  assert.ok(form.includes('if (unlockNote.ok) { unlockNote = null; listError = null; requestList(); }'));
  assert.ok(html.includes("else if (m.t === 'unlock') unlockAnswered(m);"));
  assert.equal(/console\.\w+\([^)]*(pw|password|unlockpw)/i.test(html), false);
  assert.equal(/sessionStorage\.setItem\([^)]*unlock/i.test(html), false);
});
