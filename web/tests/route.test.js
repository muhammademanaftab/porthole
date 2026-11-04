const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { addressScope, routeKind, selectedRoute, ROUTE_LABELS } = require('../porthole-core.js');

test('addressScope sorts LAN, Tailscale, loopback and the rest like the Swift side', () => {
  const cases = {
    '10.0.1.52': 'local', '192.168.1.20': 'local', '172.16.0.1': 'local', '172.31.255.255': 'local', '172.32.0.1': 'other',
    '169.254.3.4': 'local', 'mini.local': 'local', 'mini.local.': 'local', '100.101.102.103': 'tailscale', '100.64.0.1': 'tailscale',
    '100.128.0.1': 'other', '100.63.255.255': 'other', 'mini.tail1.ts.net': 'tailscale', 'fd7a:115c:a1e0::1234': 'tailscale',
    '[fd7a:115c:a1e0:ab12::1]': 'tailscale', 'fd7a:115c:a1e1::1': 'local', 'fe80::1%en0': 'local', 'fd00::5': 'local',
    'fc::1': 'other', '2001:4860:4860::8888': 'other', '8.8.8.8': 'other', '127.0.0.1': 'loopback', '::1': 'loopback',
    'localhost': 'loopback', '::ffff:10.0.0.2': 'local', 'example.com': 'other', '': 'other', '1.2.3': 'other', '300.1.1.1': 'other',
  };
  for (const [host, scope] of Object.entries(cases)) assert.equal(addressScope(host), scope, host);
});

test('routeKind: relay candidates are relayed, otherwise the remote address decides', () => {
  assert.equal(routeKind('10.0.1.52', 'host', 'host'), 'sameNetwork');
  assert.equal(routeKind('100.101.102.103', 'host', 'prflx'), 'tailscale');
  assert.equal(routeKind('10.0.1.52', 'relay', 'host'), 'relayed');
  assert.equal(routeKind('100.101.102.103', 'host', 'relay'), 'relayed');
  assert.equal(routeKind('84.2.1.9', 'srflx', 'srflx'), 'internet');
  assert.equal(routeKind('127.0.0.1', 'host', 'host'), 'thisMac');
});

const report = (entries) => new Map(entries.map(e => [e.id, e]));

test('selectedRoute follows the transport to the selected pair and its remote candidate', () => {
  const r = selectedRoute(report([
    { id: 'T1', type: 'transport', selectedCandidatePairId: 'P2' },
    { id: 'P1', type: 'candidate-pair', localCandidateId: 'L1', remoteCandidateId: 'R1', nominated: true, state: 'succeeded' },
    { id: 'P2', type: 'candidate-pair', localCandidateId: 'L2', remoteCandidateId: 'R2', nominated: true, state: 'succeeded' },
    { id: 'L1', type: 'local-candidate', address: '100.70.0.2', candidateType: 'host' },
    { id: 'R1', type: 'remote-candidate', address: '100.101.102.103', candidateType: 'host' },
    { id: 'L2', type: 'local-candidate', address: 'abcd.local', candidateType: 'host' },
    { id: 'R2', type: 'remote-candidate', address: '10.0.1.52', candidateType: 'host' },
  ]));
  assert.deepEqual(r, { kind: 'sameNetwork', address: '10.0.1.52', label: 'Same network', text: 'Same network (10.0.1.52)' });
});

test('selectedRoute falls back to a nominated, succeeded pair and to the old ip field', () => {
  const r = selectedRoute([
    { id: 'P1', type: 'candidate-pair', localCandidateId: 'L1', remoteCandidateId: 'R1', nominated: false, state: 'in-progress' },
    { id: 'P2', type: 'candidate-pair', localCandidateId: 'L1', remoteCandidateId: 'R2', nominated: true, state: 'succeeded' },
    { id: 'L1', type: 'local-candidate', address: '192.168.1.4', candidateType: 'relay' },
    { id: 'R1', type: 'remote-candidate', address: '10.0.0.1', candidateType: 'host' },
    { id: 'R2', type: 'remote-candidate', ip: '100.101.102.103', candidateType: 'host' },
  ]);
  assert.equal(r.kind, 'relayed');
  assert.equal(r.text, 'Relayed (100.101.102.103)');
});

test('selectedRoute gives nothing before ICE has chosen a pair', () => {
  assert.equal(selectedRoute(null), null);
  assert.equal(selectedRoute(report([{ id: 'T1', type: 'transport' }])), null);
  assert.equal(selectedRoute(report([{ id: 'P1', type: 'candidate-pair', remoteCandidateId: 'R1', nominated: true, state: 'succeeded' }])), null);
});

test('route labels match the Swift side', () => {
  const swift = fs.readFileSync(path.join(__dirname, '../../Sources/PortholeCore/Route.swift'), 'utf8');
  for (const [kind, label] of Object.entries(ROUTE_LABELS)) assert.match(swift, new RegExp(`case \\.${kind}: return "${label}"`), kind);
});

test('index.html shows the route in the bar from the video track stats', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  assert.match(html, /<span id="route" hidden><\/span>/);
  assert.match(html, /getRTCStatsReport/);
  assert.match(html, /PC\.selectedRoute\(/);
  assert.match(html, /watchRoute\(track\)/);
});
