const assert = require('node:assert/strict');
const test = require('node:test');
const vm = require('node:vm');
const R = require('../extension/routing.js');

function pac(rules, host) {
  const context = vm.createContext({ dnsDomainIs: (name, suffix) => name.endsWith(suffix) });
  vm.runInContext(R.buildPacScript(rules), context);
  return context.FindProxyForURL('https://' + host + '/', host);
}
test('normalization and legacy service aliases', () => {
  assert.equal(R.normalizeHost('WWW.Example.COM.'), 'example.com');
  assert.equal(R.canonicalRouteHost('m.youtube.com'), 'youtube.com');
  assert.equal(R.canonicalRouteHost('youtu.be'), 'youtube.com');
  assert.equal(R.canonicalRouteHost('cdn.discordapp.com'), 'discord.com');
  assert.equal(R.normalizeHost('пример.рф'), 'xn--e1afmkfd.xn--p1ai');
});
test('explicit child Direct overrides inherited VPN in resolver and PAC', () => {
  const rules = { 'example.com': 'vpn', 'video.example.com': 'direct' };
  assert.equal(R.resolveRoute(rules, 'video.example.com').route, 'direct');
  assert.equal(pac(rules, 'video.example.com'), 'DIRECT');
  assert.equal(pac(rules, 'other.example.com'), 'SOCKS5 127.0.0.1:1080');
  assert.equal(pac(rules, 'notexample.com'), 'DIRECT');
});
test('most specific rule wins, including grandchild VPN', () => {
  const rules = { 'example.com': 'vpn', 'video.example.com': 'direct', 'private.video.example.com': 'vpn' };
  for (const [host, expected] of [['example.com', 'vpn'], ['video.example.com', 'direct'], ['private.video.example.com', 'vpn']]) {
    assert.equal(R.resolveRoute(rules, host).route, expected);
    assert.equal(pac(rules, host), expected === 'vpn' ? 'SOCKS5 127.0.0.1:1080' : 'DIRECT');
  }
});
test('terminal dot, www and case agree in PAC and UI', () => {
  for (const host of ['example.com.', 'WWW.EXAMPLE.COM.', 'WWW.example.com']) assert.equal(pac({ 'example.com': 'vpn' }, host), 'SOCKS5 127.0.0.1:1080');
});
test('YouTube and Discord bundles retain service coverage and allow exclusions', () => {
  for (const host of ['youtu.be','googlevideo.com','ytimg.com','youtubei.googleapis.com','youtube.googleapis.com']) assert.equal(pac({ 'm.youtube.com':'vpn' }, host), 'SOCKS5 127.0.0.1:1080');
  for (const host of ['discord.com','discordapp.net','discord.media']) assert.equal(pac({ 'canary.discord.com':'vpn' }, host), 'SOCKS5 127.0.0.1:1080');
  assert.equal(pac({ 'youtube.com':'vpn', 'googlevideo.com':'direct' }, 'cdn.googlevideo.com'), 'DIRECT');
});
test('invalid hosts and browser bypass addresses cannot be VPN rules', () => {
  for (const host of ['https://example.com/a','example.com:443','a b','localhost','127.0.0.1','169.254.0.1','[::1]']) assert.throws(() => R.normalizeRules({ [host]: 'vpn' }));
  assert.throws(() => R.normalizeRules({ 'example.com': 'unknown' }));
  assert.throws(() => R.normalizeRules({ 'EXAMPLE.com': 'vpn', 'example.com': 'direct' }));
  assert.throws(() => R.buildPacScript({}, 70000));
});
