const element = id => document.getElementById(id);
let hostname = '';
let stopped = false;
let writing = false;
let probing = false;
let refreshing = false;
let releaseURL = '';
let generation = 0;

function buttons(enabled) {
  for (const id of ['directButton', 'vpnButton', 'inheritButton']) element(id).disabled = !enabled;
}

function renderProbe(probe) {
  if (!probe) return;
  element('probeStatus').textContent = probe.outbound === 'reachable'
    ? 'HTTP через AMNEZIA: ' + probe.delay + ' мс' + (probe.directDelay !== null ? '; Direct на том же URL: ' + probe.directDelay + ' мс' : '') + '. ' + new Date(probe.checkedAt).toLocaleTimeString() + '. Доступность текущего сайта и WebRTC этим не проверяются.'
    : 'Выход не подтверждён: ' + probe.message;
}

function render(snapshot) {
  element('version').textContent = snapshot.version;
  const route = snapshot.route;
  for (const [id, value] of [['directButton', 'direct'], ['vpnButton', 'vpn']]) {
    const selected = route?.route === value && snapshot.preferences.enabled;
    element(id).setAttribute('aria-pressed', String(selected));
    element(id).classList.toggle('selected', selected);
  }
  element('ruleSource').textContent = route?.source ? (route.bundle ? 'Набор доменов сервиса: ' : route.inherited ? 'Наследуется от: ' : 'Правило: ') + route.source : 'Собственное правило отсутствует.';
  element('appliedStatus').textContent = !snapshot.proxy.applied
    ? 'Настройка прокси не подтверждена: ' + (snapshot.applyError || snapshot.proxy.levelOfControl)
    : snapshot.proxy.mode === 'released' ? 'Расширение не управляет прокси.' : 'PAC подтверждён Chrome.';
  element('statusDot').style.background = snapshot.proxy.applied && !snapshot.privacyWarnings.length ? '#64748b' : '#f59e0b';
  if (snapshot.privacyWarnings.length) element('appliedStatus').textContent += ' Защита приватности требует внимания в настройках.';
  if (snapshot.lastProxyError) element('appliedStatus').textContent += ' Последняя ошибка прокси: ' + snapshot.lastProxyError.message + ' (' + new Date(snapshot.lastProxyError.at).toLocaleTimeString() + ').';
  element('probeButton').disabled = !snapshot.paired || probing;
  buttons(Boolean(hostname) && !writing && !Routing.bypassed(hostname));
  renderProbe(snapshot.probe);
}

async function refresh() {
  if (stopped || refreshing) return;
  refreshing = true;
  const requestGeneration = generation;
  try {
    const [snapshot, backend] = await Promise.all([UI.send('SNAPSHOT', { host: hostname }), UI.send('BACKEND_STATUS')]);
    if (stopped || requestGeneration !== generation) return;
    render(snapshot);
    element('backendStatus').textContent = backend.controller === 'unpaired' ? 'Импортируй файл подключения в настройках.'
      : backend.controller === 'reachable' ? 'Controller отвечает · mihomo ' + backend.coreVersion
      : 'Controller недоступен: ' + backend.message;
  } catch (error) { if (!stopped) UI.error(element('message'), error); }
  finally { refreshing = false; }
}

async function changeRule(route) {
  if (!hostname || writing) return;
  writing = true;
  generation++;
  buttons(false);
  element('message').textContent = 'Сохранение и проверка применения…';
  try {
    render(await UI.send('SET_RULE', { host: hostname, route }));
    element('message').textContent = 'Правило сохранено; применение проверено. Для уже открытого сайта обнови страницу.';
  } catch (error) {
    UI.error(element('message'), error);
    try { render(await UI.send('SNAPSHOT', { host: hostname })); } catch (failure) { UI.error(element('message'), failure); }
  } finally {
    writing = false;
    buttons(!Routing.bypassed(hostname));
  }
}

async function initialize() {
  element('version').textContent = chrome.runtime.getManifest().version;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.url) {
    const url = new URL(tab.url);
    if (['http:', 'https:'].includes(url.protocol)) hostname = Routing.normalizeHost(url.hostname);
  }
  element('site').textContent = hostname || 'Служебная страница';
  if (hostname && Routing.bypassed(hostname)) element('message').textContent = 'Для localhost и link-local Chrome использует прямое соединение.';
  await refresh();
  const status = await UI.send('CHECK_UPDATE');
  if (stopped) return;
  element('updateStatus').textContent = UI.updateText(status);
  element('updateCard').hidden = status.state !== 'available';
  if (status.state === 'available') {
    releaseURL = status.url;
    element('updateText').textContent = 'Доступна версия ' + status.version;
  }
}

element('directButton').addEventListener('click', () => changeRule('direct'));
element('vpnButton').addEventListener('click', () => changeRule('vpn'));
element('inheritButton').addEventListener('click', () => changeRule('remove'));
element('settingsButton').addEventListener('click', () => chrome.runtime.openOptionsPage());
element('updateButton').addEventListener('click', () => { if (releaseURL) chrome.tabs.create({ url: releaseURL }); });
element('probeButton').addEventListener('click', async () => {
  if (probing) return;
  probing = true;
  element('probeButton').disabled = true;
  element('probeStatus').textContent = 'HTTP-проверка, до 17 секунд…';
  try { renderProbe(await UI.send('PROBE_BACKEND')); }
  catch (error) { UI.error(element('probeStatus'), error); }
  finally { probing = false; element('probeButton').disabled = false; }
});
const interval = setInterval(refresh, 5000);
window.addEventListener('pagehide', () => { stopped = true; clearInterval(interval); });
initialize().catch(error => UI.error(element('message'), error));
