const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');

(async () => {
  const extension = path.resolve(__dirname, '../extension');
  const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'amnezia-browser-smoke-'));
  let context;
  try {
    context = await chromium.launchPersistentContext(profile, {
      channel: 'chromium', headless: true,
      args: ['--disable-extensions-except=' + extension, '--load-extension=' + extension]
    });
    const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker', { timeout: 15000 });
    const id = new URL(worker.url()).hostname;
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto('chrome-extension://' + id + '/settings.html');
    await page.waitForFunction(() => document.querySelector('#version').textContent === '1');
    await page.locator('#domain').fill('example.com');
    await page.locator('#ruleForm button').click();
    await page.waitForFunction(() => document.querySelector('#rules').textContent.includes('example.com') && document.querySelector('#message').textContent === 'Готово.');
    const active = await page.evaluate(() => chrome.runtime.sendMessage({ type: 'SNAPSHOT' }));
    assert.equal(active.ok, true);
    assert.equal(active.data.proxy.applied, true);
    assert.equal(active.data.proxy.mode, 'rules');
    assert.equal(active.data.rules['example.com'], 'vpn');
    assert.deepEqual(active.data.privacyWarnings, []);
    await page.locator('#enabled').uncheck();
    await page.waitForFunction(async () => {
      const state = await chrome.runtime.sendMessage({ type: 'SNAPSHOT' });
      return !state.data.preferences.enabled && state.data.proxy.mode === 'released' && state.data.proxy.applied;
    });
    await page.goto('chrome-extension://' + id + '/popup.html');
    await page.waitForFunction(() => document.querySelector('#version').textContent === '1');
    assert.equal(await page.locator('#updateCard').isVisible(), false);
    assert.deepEqual(errors, []);
    console.log('Browser smoke passed: settings, real proxy/privacy APIs, disable, popup hidden state');
  } finally {
    if (context) await context.close();
    await fs.rm(profile, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
