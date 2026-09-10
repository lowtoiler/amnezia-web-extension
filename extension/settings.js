const element = id => document.getElementById(id);
let current;
let busy = false;
function renderRules() {
  const rows = Object.entries(current.rules).filter(([host]) => host.includes(element('search').value.trim().toLowerCase()));
  element('rules').replaceChildren();
  for (const [host, route] of rows) {
    const row = document.createElement('tr');
    for (const text of [host, route === 'vpn' ? 'VPN' : 'Direct']) { const cell = document.createElement('td'); cell.textContent = text; row.append(cell); }
    const actions = document.createElement('td');
    for (const [label, value] of [['VPN', 'vpn'], ['Direct', 'direct'], ['Удалить', 'remove']]) {
      const button = document.createElement('button');
      button.type = 'button'; button.textContent = label; button.disabled = busy;
      button.addEventListener('click', () => action(() => UI.send('SET_RULE', { host, route: value })));
      actions.append(button);
    }
    row.append(actions);
    element('rules').append(row);
  }
  element('ruleCount').textContent = 'Показано ' + rows.length + ' из ' + Object.keys(current.rules).length;
}
async function refresh() {
  current = await UI.send('SNAPSHOT');
  element('version').textContent = current.version;
  for (const key of ['enabled', 'protectWebRtc', 'preventDnsPrefetch']) element(key).checked = current.preferences[key];
  element('applyStatus').textContent = (!current.proxy.applied ? 'Настройка прокси не подтверждена: ' + (current.applyError || current.proxy.levelOfControl) : current.proxy.mode === 'released' ? 'Настройки прокси освобождены.' : 'PAC подтверждён Chrome.') + (current.privacyWarnings.length ? ' ' + current.privacyWarnings.join('; ') : '');
  renderRules();
  const backend = await UI.send('BACKEND_STATUS', { force: true });
  element('connectionStatus').textContent = !current.paired ? 'Файл подключения ещё не импортирован.' : backend.controller === 'reachable' ? 'Подключение к controller подтверждено. mihomo ' + backend.coreVersion : 'Ключ сохранён; controller недоступен: ' + backend.message;
}
async function action(run) {
  if (busy) return;
  busy = true;
  for (const input of document.querySelectorAll('button, input, select')) input.disabled = true;
  element('message').textContent = 'Выполняется…';
  try { await run(); element('message').textContent = 'Готово.'; }
  catch (error) { UI.error(element('message'), error); }
  finally {
    try { await refresh(); } catch (error) { UI.error(element('message'), error); }
    busy = false;
    for (const input of document.querySelectorAll('button, input, select')) input.disabled = false;
  }
}
element('ruleForm').addEventListener('submit', event => {
  event.preventDefault();
  action(() => UI.send('SET_RULE', { host: element('domain').value, route: element('route').value }));
});
element('search').addEventListener('input', renderRules);
for (const key of ['enabled', 'protectWebRtc', 'preventDnsPrefetch']) element(key).addEventListener('change', () => action(() => UI.send('SET_PREFERENCES', { preferences: { [key]: element(key).checked } })));
element('connectionFile').addEventListener('change', () => action(async () => {
  const data = await UI.readJson(element('connectionFile').files[0]);
  await UI.send('SET_CONNECTION', { connection: data });
  element('connectionFile').value = '';
}));
element('rulesFile').addEventListener('change', () => action(async () => {
  const data = await UI.readJson(element('rulesFile').files[0]);
  await UI.send('IMPORT_RULES', { data });
  element('rulesFile').value = '';
}));
element('exportButton').addEventListener('click', () => action(async () => UI.download('amnezia-browser-rules-v1.json', await UI.send('EXPORT_RULES'))));
element('diagnosticsButton').addEventListener('click', () => action(async () => UI.download('amnezia-browser-diagnostics-v1.json', await UI.send('DIAGNOSTICS'))));
element('refreshButton').addEventListener('click', () => action(() => UI.send('SYNC_PROXY')));
element('updateButton').addEventListener('click', () => action(async () => { element('updateStatus').textContent = UI.updateText(await UI.send('CHECK_UPDATE', { force: true })); }));
refresh().then(() => UI.send('CHECK_UPDATE')).then(status => { element('updateStatus').textContent = UI.updateText(status); }).catch(error => UI.error(element('message'), error));
