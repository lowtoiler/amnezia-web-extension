const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const clone = value => structuredClone(value);
const flush = () => new Promise(resolve => setImmediate(resolve));
const event = () => ({ listeners:[], addListener(fn) { this.listeners.push(fn); } });

async function setup(initial = {}) {
  const data = clone(initial);
  const events = [];
  function setting(base) {
    return {
      current:{ value:base, levelOfControl:'controllable_by_this_extension' }, onChange:event(), fail:false, sets:0,
      async get() { return clone(this.current); },
      async set({ value }) {
        if (this.fail) throw new Error('Apply denied');
        this.sets++;
        this.current = { value:clone(value), levelOfControl:'controlled_by_this_extension' };
        for (const fn of this.onChange.listeners) fn(this.current);
      },
      async clear() { this.current = { value:base, levelOfControl:'controllable_by_this_extension' }; }
    };
  }
  const chrome = {
    storage:{ local:{ async get() { return clone(data); }, async set(value) { Object.assign(data,clone(value)); }, async setAccessLevel() {} } },
    proxy:{ settings:setting({ mode:'system' }), onProxyError:event() },
    privacy:{ network:{ webRTCIPHandlingPolicy:setting('default'), networkPredictionEnabled:setting(true) } },
    runtime:{ id:'test', onInstalled:event(), onStartup:event(), onMessage:event(), getManifest:() => ({version:'1'}), getURL:value => 'chrome-extension://test/' + value },
    alarms:{ async get() { return null; }, async create() {}, onAlarm:event() },
    action:{ async setBadgeText() {}, async setBadgeBackgroundColor() {} }
  };
  let fetchCalls = 0;
  const context = vm.createContext({ chrome, URL, TextDecoder, Uint8Array, AbortController, setTimeout, clearTimeout, console:{ error(...args) { events.push(args); } }, fetch:async url => {
    fetchCalls++;
    if (url.endsWith('release.json')) return new Response('{"repository":"__REPOSITORY__"}');
    if (url.endsWith('/version')) return Response.json({ version:'1.19.30' });
    if (url.endsWith('/configs')) return Response.json({ 'mixed-port':1080,mode:'rule' });
    return Response.json({ delay:45 });
  } });
  context.importScripts = (...files) => files.forEach(file => vm.runInContext(fs.readFileSync(path.join(__dirname,'../extension',file),'utf8'), context, { filename:file }));
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../extension/background.js'),'utf8'),context,{filename:'background.js'});
  await flush();
  await flush();
  return { context, chrome, data, events, fetchCalls:() => fetchCalls };
}
test('empty rules release the override and restore underlying privacy values', async () => {
  const app = await setup();
  assert.equal(app.chrome.proxy.settings.sets, 0);
  assert.equal((await app.context.snapshot()).proxy.mode, 'released');
  await app.context.handleMessage({type:'SET_RULE',host:'example.com',route:'vpn'});
  assert.equal(app.chrome.privacy.network.webRTCIPHandlingPolicy.current.value,'disable_non_proxied_udp');
  await app.context.handleMessage({type:'SET_PREFERENCES',preferences:{enabled:false}});
  assert.equal(app.chrome.proxy.settings.current.value.mode,'system');
  assert.equal(app.chrome.privacy.network.webRTCIPHandlingPolicy.current.value,'default');
});
test('parallel writes preserve both rules and popup resolves inherited Direct correctly', async () => {
  const app = await setup({routeRules:{'example.com':'vpn'}});
  await Promise.all([
    app.context.handleMessage({type:'SET_RULE',host:'one.example',route:'vpn'}),
    app.context.handleMessage({type:'SET_RULE',host:'two.example',route:'vpn'}),
    app.context.handleMessage({type:'SET_RULE',host:'video.example.com',route:'direct'})
  ]);
  assert.equal(Object.keys(app.data.appState.routeRules).length,4);
  const view = await app.context.snapshot('video.example.com');
  assert.equal(view.route.route,'direct');
  assert.equal(view.proxy.applied,true);
});
test('failed application is observable and never reported applied', async () => {
  const app = await setup();
  app.chrome.proxy.settings.fail = true;
  await assert.rejects(app.context.handleMessage({type:'SET_RULE',host:'example.com',route:'vpn'}), /Apply denied/);
  const view = await app.context.snapshot('example.com');
  assert.equal(view.route.route,'vpn');
  assert.equal(view.proxy.applied,false);
  assert.equal(view.applyError,'Apply denied');
  assert.ok(app.data.diagnostics.length > 0);
});
test('other extension ownership is detected without overwriting it', async () => {
  const app = await setup();
  app.chrome.proxy.settings.current.levelOfControl = 'controlled_by_other_extensions';
  await assert.rejects(app.context.handleMessage({type:'SET_RULE',host:'example.com',route:'vpn'}));
  assert.equal(app.chrome.proxy.settings.sets,0);
});
test('status calls share one operation and diagnostic exports omit secrets', async () => {
  const app = await setup();
  const connection={schemaVersion:1,controllerUrl:'http://127.0.0.1:9090',proxyHost:'127.0.0.1',proxyPort:1080,secret:'b'.repeat(64)};
  await app.context.handleMessage({type:'SET_CONNECTION',connection});
  const before = app.fetchCalls();
  await Promise.all([app.context.backendStatus(true), app.context.backendStatus(true)]);
  assert.equal(app.fetchCalls()-before,2);
  for (const type of ['SNAPSHOT','EXPORT_RULES','DIAGNOSTICS']) assert.equal(JSON.stringify(await app.context.handleMessage({type})).includes(connection.secret),false);
});
test('version checks and update configuration have explicit outcomes', async () => {
  const app = await setup();
  assert.equal(app.context.isNewerVersion('1.0.1','1'),true);
  assert.equal(app.context.isNewerVersion('1.0.0','1'),false);
  assert.equal(app.context.isNewerVersion('1','1.0.1'),false);
  assert.throws(() => app.context.isNewerVersion('garbage','1'));
  assert.equal((await app.context.checkUpdate(true)).state,'unconfigured');
});
test('privacy takeover and proxy network errors remain visible in a fresh snapshot', async () => {
  const app = await setup({routeRules:{'example.com':'vpn'}});
  app.chrome.privacy.network.webRTCIPHandlingPolicy.current = {value:'default',levelOfControl:'controlled_by_other_extensions'};
  assert.equal((await app.context.snapshot()).privacyWarnings.length,1);
  app.chrome.proxy.onProxyError.listeners[0]({error:'ERR_PROXY_CONNECTION_FAILED'});
  await flush();
  const view = await app.context.snapshot();
  assert.equal(view.proxy.applied,true);
  assert.equal(view.lastProxyError.message,'ERR_PROXY_CONNECTION_FAILED');
});
test('a host named __proto__ is stored as an ordinary rule', async () => {
  const app = await setup();
  await app.context.handleMessage({type:'SET_RULE',host:'__proto__',route:'vpn'});
  assert.equal(Object.hasOwn(app.data.appState.routeRules,'__proto__'),true);
  assert.equal((await app.context.snapshot('__proto__')).route.route,'vpn');
});
test('simultaneous diagnostic writes retain all events', async () => {
  const app = await setup();
  await Promise.all(Array.from({length:8},(_,index) => app.context.recordError('event-'+index,new Error('failure-'+index))));
  assert.equal(app.data.diagnostics.length,8);
});
test('privacy changes update the badge without reopening the popup', async () => {
  const app = await setup({routeRules:{'example.com':'vpn'}});
  let badge = '';
  app.chrome.action.setBadgeText = async ({text}) => { badge = text; };
  const privacy = app.chrome.privacy.network.webRTCIPHandlingPolicy;
  privacy.current = {value:'default',levelOfControl:'controlled_by_other_extensions'};
  for (const listener of privacy.onChange.listeners) listener(privacy.current);
  await flush();
  await flush();
  assert.equal(badge,'!');
});
test('failed proxy release is visible and still releases privacy overrides', async () => {
  const app = await setup({routeRules:{'example.com':'vpn'}});
  app.chrome.proxy.settings.clear = async () => { throw new Error('Clear denied'); };
  await assert.rejects(app.context.handleMessage({type:'SET_PREFERENCES',preferences:{enabled:false}}),/Clear denied/);
  const view = await app.context.snapshot();
  assert.equal(view.proxy.applied,false);
  assert.equal(view.applyError,'Clear denied');
  assert.equal(app.chrome.privacy.network.webRTCIPHandlingPolicy.current.value,'default');
});
