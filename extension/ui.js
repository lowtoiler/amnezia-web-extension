globalThis.UI = Object.freeze({
  async send(type, fields = {}) {
    const response = await chrome.runtime.sendMessage({ type, ...fields });
    if (!response?.ok) throw new Error(response?.error || 'Расширение не ответило');
    return response.data;
  },
  updateText(status) {
    const time = status.checkedAt ? new Date(status.checkedAt).toLocaleString() : '';
    return ({ unconfigured: 'Проверка обновлений не настроена для этого архива.', current: 'Обновлений нет. Проверено: ' + time, available: 'Доступна версия ' + status.version, error: 'Не удалось проверить обновления: ' + status.message })[status.state] || '';
  },
  async readJson(file) {
    if (!file || file.size > 524288) throw new Error('Выбери JSON-файл размером до 512 КБ');
    try { return JSON.parse(await file.text()); } catch { throw new Error('Некорректный JSON-файл'); }
  },
  download(name, data) {
    const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2) + '\n'], { type: 'application/json' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = name;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  },
  error(element, error) { element.textContent = error.message || String(error); }
});
