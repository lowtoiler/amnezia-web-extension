const assert = require('node:assert/strict');
const test = require('node:test');
const http = require('node:http');
const C = require('../extension/controller.js');
const connection = { schemaVersion:1, controllerUrl:'http://127.0.0.1:9090', proxyHost:'127.0.0.1', proxyPort:1080, secret:'a'.repeat(64) };
const json = value => new Response(JSON.stringify(value), { headers: { 'Content-Type':'application/json' } });

test('connection import is restricted to expected loopback endpoints and a random-sized token', () => {
  assert.equal(C.validateConnection(connection).secret.length, 64);
  for (const item of [{ ...connection, controllerUrl:'https://example.com' }, { ...connection, secret:'legacy-public-token' }, { ...connection, proxyPort:22 }]) assert.throws(() => C.validateConnection(item));
});
test('controller status authenticates and validates both version and configuration', async () => {
  const seen = [];
  const client = C.client(connection, async (url, options) => {
    seen.push(options);
    return url.endsWith('/version') ? json({ version:'1.19.30' }) : json({ 'mixed-port':1080, mode:'rule' });
  });
  assert.equal((await client.status()).controller, 'reachable');
  assert.equal(seen.length, 2);
  assert.equal(seen[0].headers.Authorization, 'Bearer ' + connection.secret);
  assert.equal(seen[0].redirect, 'error');
  const wrong = C.client(connection, async url => url.endsWith('/version') ? json({ version:'x' }) : json({ 'mixed-port':8080, mode:'rule' }));
  await assert.rejects(wrong.status(), error => error.code === 'INSTANCE');
});
test('delay is strictly numeric and cannot turn null into success', async () => {
  for (const delay of [null,'0',true,-1,Infinity,1.5]) {
    const client = C.client(connection, async () => json({ delay }));
    await assert.rejects(client.probe(), error => error.code === 'SCHEMA');
  }
});
test('VPN and direct measurements use the same target', async () => {
  const seen = [];
  const client = C.client(connection, async url => { seen.push(new URL(url).searchParams.get('url')); return json({ delay:url.includes('/AMNEZIA/') ? 82 : 21 }); });
  const result = await client.probe();
  assert.equal(result.delay, 82);
  assert.equal(result.directDelay, 21);
  assert.equal(result.dataPath, 'not-tested');
  assert.equal(new Set(seen).size, 1);
});
test('auth errors are not retried and malformed or oversized bodies fail', async () => {
  let calls = 0;
  const client = C.client(connection, async () => { calls++; return new Response('', { status:401 }); });
  await assert.rejects(client.probe(), error => error.code === 'AUTH');
  assert.equal(calls, 2);
  await assert.rejects(C.requestJson('https://example.test', {}, 1000, async () => new Response('{')), error => error.code === 'JSON');
  await assert.rejects(C.requestJson('https://example.test', {}, 1000, async () => new Response(' '.repeat(262145))), error => error.code === 'BODY_SIZE');
});
test('real HTTP timeout includes delayed body after headers', async () => {
  const server = http.createServer((request, response) => {
    response.writeHead(200, { 'Content-Type':'application/json' });
    response.flushHeaders();
    const timer = setTimeout(() => response.end('{"delay":12}'), 250);
    response.on('close', () => clearTimeout(timer));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    await assert.rejects(C.requestJson('http://127.0.0.1:' + server.address().port, {}, 70), error => error.code === 'TIMEOUT');
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});
test('connection secret must be a string', () => {
  assert.throws(() => C.validateConnection({...connection,secret:[connection.secret]}));
});
test('failed HTTP requests abort their remaining response body', async () => {
  let signal;
  await assert.rejects(C.requestJson('http://example.test',{},1000,async (_,options) => {
    signal = options.signal;
    return new Response('denied',{status:401});
  }), error => error.code === 'AUTH');
  assert.equal(signal.aborted,true);
});
test('real rejected HTTP response closes its unfinished body', async () => {
  let closeResponse;
  const closed = new Promise(resolve => { closeResponse = resolve; });
  const server = http.createServer((request, response) => {
    response.on('close', closeResponse);
    response.writeHead(401);
    response.write('access denied');
  });
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  let timer;
  try {
    await assert.rejects(C.requestJson('http://127.0.0.1:' + server.address().port,{},1000), error => error.code === 'AUTH');
    await Promise.race([closed,new Promise((_,reject) => { timer = setTimeout(() => reject(new Error('response body remained open')),1000); })]);
  } finally {
    clearTimeout(timer);
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});
