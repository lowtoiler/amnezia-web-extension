importScripts('routing.js', 'controller.js');

const UPDATE_ALARM = 'amnezia-browser-update-check';
const UPDATE_INTERVAL_MS = 6 * 60 * 60 * 1000;
const defaults = { enabled: true, protectWebRtc: true, preventDnsPrefetch: true };
let state;
let queue = Promise.resolve();
let diagnosticsQueue = Promise.resolve();
let statusFlight = null;
let probeFlight = null;
let statusCache = null;
let probeCache = null;
let updateFlight = null;
let lastApplyError = null;
let lastProxyError = null;
let privacyWarnings = [];
const ready = loadState();

async function loadState() {
  await chrome.storage.local.setAccessLevel({ accessLevel: 'TRUSTED_CONTEXTS' });
  const stored = await chrome.storage.local.get(['appState', 'routeRules']);
  const candidate = stored.appState;
  if (candidate && candidate.schemaVersion !== 1) throw new Error('Неподдерживаемый формат настроек');
  state = {
    schemaVersion: 1,
    routeRules: Routing.normalizeRules(candidate?.routeRules || stored.routeRules || {}),
    preferences: validatePreferences(candidate?.preferences || defaults),
    connection: candidate?.connection ? Controller.validateConnection(candidate.connection) : null,
    revision: Number.isSafeInteger(candidate?.revision) ? candidate.revision : 0
  };
  await chrome.storage.local.set({ appState: state });
}

function validatePreferences(value) {
  const result = { ...defaults };
  for (const [key, item] of Object.entries(value)) {
    if (!Object.hasOwn(defaults, key) || typeof item !== 'boolean') throw new Error('Некорректные настройки');
    result[key] = item;
  }
  return result;
}

function serialize(action) {
  const task = queue.then(async () => { await ready; return action(); });
  queue = task.catch(() => {});
  return task;
}

async function saveState(next) {
  const saved = { ...next, revision: state.revision + 1 };
  await chrome.storage.local.set({ appState: saved });
  state = saved;
}

function desiredProxy() {
  const active = state.preferences.enabled && Object.values(state.routeRules).includes('vpn');
  return active ? { mode: 'pac_script', pacScript: { data: Routing.buildPacScript(state.routeRules, state.connection?.proxyPort || 1080), mandatory: true } } : null;
}

function sameProxy(actual, desired) {
  return actual?.mode === desired?.mode && actual?.pacScript?.data === desired?.pacScript?.data && actual?.pacScript?.mandatory === true;
}

async function recordError(action, error) {
  const entry = { at: Date.now(), action, code: error.code || 'ERROR', message: String(error.message || 'Ошибка').slice(0, 300) };
  console.error(action, entry.code, entry.message);
  diagnosticsQueue = diagnosticsQueue.then(async () => {
    try {
      const previous = await chrome.storage.local.get('diagnostics');
      const events = Array.isArray(previous.diagnostics) ? previous.diagnostics : [];
      await chrome.storage.local.set({ diagnostics: [...events, entry].slice(-50) });
    } catch (storageError) {
      console.error('Не удалось сохранить диагностику', storageError.name);
    }
  });
  await diagnosticsQueue;
}

async function applyPrivacy(active) {
  const warnings = [];
  for (const [key, setting, value] of [
    ['protectWebRtc', chrome.privacy.network.webRTCIPHandlingPolicy, 'disable_non_proxied_udp'],
    ['preventDnsPrefetch', chrome.privacy.network.networkPredictionEnabled, false]
  ]) {
    try {
      if (!active || !state.preferences[key]) {
        await setting.clear({ scope: 'regular' });
        continue;
      }
      const current = await setting.get({});
      if (['not_controllable', 'controlled_by_other_extensions'].includes(current.levelOfControl)) throw new Error('Настройка ' + key + ' контролируется извне');
      if (current.levelOfControl !== 'controlled_by_this_extension' || current.value !== value) await setting.set({ value, scope: 'regular' });
      const applied = await setting.get({});
      if (applied.value !== value || applied.levelOfControl !== 'controlled_by_this_extension') throw new Error('Не удалось подтвердить ' + key);
    } catch (error) {
      warnings.push(error.message);
      await recordError('privacy', error);
    }
  }
  privacyWarnings = warnings;
}

async function inspectProxy() {
  const current = await chrome.proxy.settings.get({ incognito: false });
  const desired = desiredProxy();
  if (!desired) return { applied: current.levelOfControl !== 'controlled_by_this_extension', mode: 'released', levelOfControl: current.levelOfControl };
  return { applied: current.levelOfControl === 'controlled_by_this_extension' && sameProxy(current.value, desired), mode: 'rules', levelOfControl: current.levelOfControl };
}

async function inspectPrivacy() {
  const warnings = [];
  const active = Boolean(desiredProxy());
  for (const [key, setting, value] of [
    ['protectWebRtc', chrome.privacy.network.webRTCIPHandlingPolicy, 'disable_non_proxied_udp'],
    ['preventDnsPrefetch', chrome.privacy.network.networkPredictionEnabled, false]
  ]) {
    try {
      const current = await setting.get({});
      if (active && state.preferences[key]) {
        if (current.value !== value || current.levelOfControl !== 'controlled_by_this_extension') warnings.push('Не подтверждена настройка ' + key);
      } else if (current.levelOfControl === 'controlled_by_this_extension') warnings.push('Не освобождена настройка ' + key);
    } catch (error) { warnings.push(error.message); }
  }
  privacyWarnings = warnings;
}

async function updateBadge(applied) {
  await chrome.action.setBadgeText({ text: !applied.applied || privacyWarnings.length ? '!' : applied.mode === 'rules' ? 'ON' : '' });
  await chrome.action.setBadgeBackgroundColor({ color: !applied.applied || privacyWarnings.length ? '#b45309' : '#374151' });
}

async function applyRules() {
  const desired = desiredProxy();
  lastApplyError = null;
  try {
    if (desired) {
      await applyPrivacy(true);
      const current = await chrome.proxy.settings.get({ incognito: false });
      if (['not_controllable', 'controlled_by_other_extensions'].includes(current.levelOfControl)) throw new Error('Прокси управляется политикой или другим расширением');
      if (!sameProxy(current.value, desired) || current.levelOfControl !== 'controlled_by_this_extension') await chrome.proxy.settings.set({ value: desired, scope: 'regular' });
    } else {
      try { await chrome.proxy.settings.clear({ scope: 'regular' }); }
      finally { await applyPrivacy(false); }
    }
    const applied = await inspectProxy();
    if (!applied.applied) throw new Error('Chrome не подтвердил применение настройки прокси');
    await updateBadge(applied);
    return applied;
  } catch (error) {
    lastApplyError = error.message;
    await recordError('apply-proxy', error);
    await updateBadge({ applied: false });
    throw error;
  }
}

async function snapshot(host) {
  await ready;
  const applied = await inspectProxy();
  await inspectPrivacy();
  return {
    version: chrome.runtime.getManifest().version,
    revision: state.revision,
    rules: state.routeRules,
    preferences: state.preferences,
    paired: Boolean(state.connection),
    route: host ? Routing.resolveRoute(state.routeRules, host) : null,
    proxy: applied,
    applyError: lastApplyError,
    lastProxyError,
    privacyWarnings,
    probe: probeCache?.value || null
  };
}

async function backendStatus(force = false) {
  await ready;
  if (!state.connection) return { controller: 'unpaired', checkedAt: Date.now() };
  const fingerprint = state.connection.secret;
  if (statusFlight?.key === fingerprint) return statusFlight.promise;
  if (!force && statusCache?.key === fingerprint && Date.now() - statusCache.value.checkedAt < 5000) return statusCache.value;
  const promise = Controller.client(state.connection).status().catch(error => ({ controller: 'unreachable', code: error.code, message: error.message, checkedAt: Date.now() })).then(value => {
    if (state.connection?.secret === fingerprint) statusCache = { key: fingerprint, value };
    return value;
  }).finally(() => { if (statusFlight?.promise === promise) statusFlight = null; });
  statusFlight = { key: fingerprint, promise };
  return promise;
}

async function probeBackend() {
  await ready;
  if (!state.connection) throw new Error('Импортируй файл подключения backend');
  const fingerprint = state.connection.secret;
  if (probeFlight?.key === fingerprint) return probeFlight.promise;
  const client = Controller.client(state.connection);
  const promise = client.status().then(() => client.probe()).catch(error => ({ outbound: 'unreachable', code: error.code || 'ERROR', message: error.message, checkedAt: Date.now(), dataPath: 'not-tested' })).then(value => {
    if (state.connection?.secret === fingerprint) probeCache = { key: fingerprint, value };
    return value;
  }).finally(() => { if (probeFlight?.promise === promise) probeFlight = null; });
  probeFlight = { key: fingerprint, promise };
  return promise;
}

function parseVersion(value) {
  const text = String(value || '').replace(/^v/u, '');
  if (!/^\d{1,5}(?:\.\d{1,5}){0,3}$/u.test(text)) throw new Error('Некорректная версия релиза');
  const parts = text.split('.').map(Number);
  if (parts.some(part => part > 65535) || parts.every(part => part === 0)) throw new Error('Некорректная версия релиза');
  return parts;
}

function isNewerVersion(latest, current) {
  const a = parseVersion(latest);
  const b = parseVersion(current);
  for (let i = 0; i < 4; i++) {
    if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) > (b[i] || 0);
  }
  return false;
}

async function checkUpdate(force = false) {
  if (updateFlight) return updateFlight;
  updateFlight = (async () => {
    const stored = await chrome.storage.local.get(['updateStatus', 'updateCheckedAt']);
    if (!force && stored.updateStatus && Date.now() - (stored.updateCheckedAt || 0) < UPDATE_INTERVAL_MS) return stored.updateStatus;
    let result;
    try {
      const metadata = await Controller.requestJson(chrome.runtime.getURL('release.json'), {}, 3000);
      const repository = metadata.repository;
      if (!repository || repository === '__REPOSITORY__') {
        result = { state: 'unconfigured' };
      } else {
        if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u.test(repository)) throw new Error('Некорректный репозиторий обновлений');
        const release = await Controller.requestJson('https://api.github.com/repos/' + repository + '/releases/latest', { headers: { Accept: 'application/vnd.github+json' } }, 10000);
        const version = String(release.tag_name || '').replace(/^v/u, '');
        parseVersion(version);
        const url = new URL(release.html_url);
        if (url.origin !== 'https://github.com' || !url.pathname.startsWith('/' + repository + '/releases/tag/')) throw new Error('Некорректная ссылка релиза');
        result = { state: isNewerVersion(version, chrome.runtime.getManifest().version) ? 'available' : 'current', version, url: url.href };
      }
    } catch (error) {
      result = { state: 'error', message: error.message, lastSuccess: stored.updateStatus?.state !== 'error' ? stored.updateStatus || null : stored.updateStatus?.lastSuccess || null };
      await recordError('update', error);
    }
    result.checkedAt = Date.now();
    await chrome.storage.local.set({ updateStatus: result, updateCheckedAt: result.checkedAt });
    return result;
  })().finally(() => { updateFlight = null; });
  return updateFlight;
}

async function handleMessage(message) {
  if (!message || typeof message.type !== 'string') throw new Error('Некорректное сообщение');
  await ready;
  switch (message.type) {
    case 'SNAPSHOT': return snapshot(message.host || '');
    case 'BACKEND_STATUS': return backendStatus(Boolean(message.force));
    case 'PROBE_BACKEND': return probeBackend();
    case 'CHECK_UPDATE': return checkUpdate(Boolean(message.force));
    case 'EXPORT_RULES': return { schemaVersion: 1, routeRules: state.routeRules, preferences: state.preferences };
    case 'DIAGNOSTICS': {
      await diagnosticsQueue;
      const stored = await chrome.storage.local.get('diagnostics');
      return { version: chrome.runtime.getManifest().version, snapshot: await snapshot(), backend: await backendStatus(), events: stored.diagnostics || [] };
    }
    case 'SET_RULE': return serialize(async () => {
      const host = Routing.normalizeHost(message.host);
      if (!['vpn', 'direct', 'remove'].includes(message.route)) throw new Error('Неизвестный маршрут');
      const rules = Object.assign(Object.create(null), state.routeRules);
      if (message.route === 'remove') delete rules[host]; else rules[host] = message.route;
      await saveState({ ...state, routeRules: Routing.normalizeRules(rules) });
      await applyRules();
      return snapshot(host);
    });
    case 'SET_PREFERENCES': return serialize(async () => {
      await saveState({ ...state, preferences: validatePreferences({ ...state.preferences, ...message.preferences }) });
      await applyRules();
      return snapshot();
    });
    case 'IMPORT_RULES': return serialize(async () => {
      if (message.data?.schemaVersion !== 1) throw new Error('Неподдерживаемый формат импорта');
      const imported = Routing.normalizeRules(message.data.routeRules);
      const rules = Routing.normalizeRules({ ...state.routeRules, ...imported });
      await saveState({ ...state, routeRules: rules });
      await applyRules();
      return snapshot();
    });
    case 'SET_CONNECTION': return serialize(async () => {
      const connection = Controller.validateConnection(message.connection);
      await saveState({ ...state, connection });
      statusCache = null;
      probeCache = null;
      await applyRules();
      return { paired: true, backend: await backendStatus(true) };
    });
    case 'SYNC_PROXY': return serialize(applyRules);
    default: throw new Error('Неизвестная команда');
  }
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id) return false;
  handleMessage(message).then(data => respond({ ok: true, data })).catch(error => respond({ ok: false, error: error.message, code: error.code || 'ERROR' }));
  return true;
});

async function ensureAlarm() {
  if (!await chrome.alarms.get(UPDATE_ALARM)) await chrome.alarms.create(UPDATE_ALARM, { periodInMinutes: 360 });
}

function initialize() {
  return serialize(async () => { await applyRules(); await ensureAlarm(); });
}

chrome.runtime.onInstalled.addListener(() => {
  initialize().catch(error => recordError('installed', error));
  checkUpdate().catch(error => recordError('update-storage', error));
});
chrome.runtime.onStartup.addListener(() => {
  initialize().catch(error => recordError('startup', error));
  checkUpdate().catch(error => recordError('update-storage', error));
});
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === UPDATE_ALARM) checkUpdate(true).catch(error => recordError('update-storage', error));
});
function inspectSettingsChanged() {
  serialize(async () => { await inspectPrivacy(); await updateBadge(await inspectProxy()); }).catch(error => recordError('settings-changed', error));
}
chrome.proxy.settings.onChange.addListener(inspectSettingsChanged);
chrome.privacy.network.webRTCIPHandlingPolicy.onChange.addListener(inspectSettingsChanged);
chrome.privacy.network.networkPredictionEnabled.onChange.addListener(inspectSettingsChanged);
chrome.proxy.onProxyError.addListener(details => {
  const error = new Error(String(details.error || 'Ошибка браузерного прокси'));
  serialize(async () => { lastProxyError = { message: error.message, at: Date.now() }; await recordError('proxy-network', error); await updateBadge({ applied: false }); }).catch(failure => recordError('proxy-error', failure));
});
initialize().catch(error => recordError('initialize', error));
