(function (root) {
  class RequestError extends Error {
    constructor(code, message, status = null) { super(message); this.name = 'RequestError'; this.code = code; this.status = status; }
  }
  function validateConnection(value) {
    if (!value || value.schemaVersion !== 1 || value.controllerUrl !== 'http://127.0.0.1:9090' || value.proxyHost !== '127.0.0.1' || value.proxyPort !== 1080 || typeof value.secret !== 'string' || !/^[a-f0-9]{64}$/u.test(value.secret)) throw new Error('Некорректный файл подключения версии 1');
    return { schemaVersion: 1, controllerUrl: value.controllerUrl, proxyHost: value.proxyHost, proxyPort: value.proxyPort, secret: value.secret };
  }
  async function requestJson(url, options = {}, timeoutMs = 3000, fetcher = fetch) {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), timeoutMs);
    let reader;
    try {
      const response = await fetcher(url, { ...options, redirect: 'error', credentials: 'omit', cache: 'no-store', signal: abort.signal });
      if (!response.ok) throw new RequestError(response.status === 401 || response.status === 403 ? 'AUTH' : 'HTTP', 'HTTP ' + response.status, response.status);
      if (Number(response.headers.get('content-length')) > 262144) throw new RequestError('BODY_SIZE', 'Ответ сервера слишком большой');
      reader = response.body?.getReader();
      if (!reader) throw new RequestError('JSON', 'Сервер вернул пустой ответ');
      const chunks = [];
      let size = 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 262144) throw new RequestError('BODY_SIZE', 'Ответ сервера слишком большой');
        chunks.push(value);
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
      catch { throw new RequestError('JSON', 'Сервер вернул некорректный JSON'); }
    } catch (error) {
      if (abort.signal.aborted) throw new RequestError('TIMEOUT', 'Истекло время ожидания ответа');
      if (error instanceof RequestError) throw error;
      throw new RequestError('NETWORK', 'Не удалось связаться с сервером');
    } finally {
      abort.abort();
      clearTimeout(timer);
      if (reader) await reader.cancel().catch(() => {});
    }
  }
  function client(connection, fetcher = fetch) {
    const config = validateConnection(connection);
    const get = (path, timeout) => requestJson(config.controllerUrl + path, { headers: { Authorization: 'Bearer ' + config.secret } }, timeout, fetcher);
    return {
      async status() {
        const [version, settings] = await Promise.all([get('/version', 3000), get('/configs', 3000)]);
        if (!version || typeof version.version !== 'string' || !version.version || !settings || settings['mixed-port'] !== config.proxyPort || settings.mode !== 'rule') throw new RequestError('INSTANCE', 'Ответ не соответствует установленному backend');
        return { controller: 'reachable', coreVersion: version.version, listenerConfigured: true, checkedAt: Date.now() };
      },
      async probe() {
        let lastError = null;
        for (const url of ['https://cp.cloudflare.com/generate_204', 'https://www.gstatic.com/generate_204']) {
          const measure = async name => {
            const result = await get('/proxies/' + name + '/delay?url=' + encodeURIComponent(url) + '&timeout=6000', 7000);
            if (!result || typeof result.delay !== 'number' || !Number.isInteger(result.delay) || result.delay < 0 || result.delay > 65535) throw new RequestError('SCHEMA', 'Некорректное измерение задержки');
            return result.delay;
          };
          const [vpn, direct] = await Promise.allSettled([measure('AMNEZIA'), measure('DIRECT')]);
          if (vpn.status === 'fulfilled') return { outbound: 'reachable', delay: vpn.value, directDelay: direct.status === 'fulfilled' ? direct.value : null, testUrl: url, checkedAt: Date.now(), dataPath: 'not-tested' };
          lastError = vpn.reason;
          if (['AUTH', 'INSTANCE', 'SCHEMA', 'JSON'].includes(lastError.code)) break;
        }
        throw lastError;
      }
    };
  }
  const api = { RequestError, validateConnection, requestJson, client };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.Controller = Object.freeze(api);
})(globalThis);
