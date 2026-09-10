(function (root) {
  const bundles = Object.freeze({
    'youtube.com': ['youtube.com', 'youtu.be', 'googlevideo.com', 'ytimg.com', 'youtube-nocookie.com', 'ggpht.com', 'youtubei.googleapis.com', 'youtube.googleapis.com'],
    'discord.com': ['discord.com', 'discordapp.com', 'discordapp.net', 'discord.gg', 'discord.media']
  });
  const matches = (host, suffix) => host === suffix || host.endsWith('.' + suffix);
  function normalizeHost(value) {
    let host = String(value || '').trim().toLowerCase().replace(/\.$/, '');
    if (!host || /[\s/@?#\\]/u.test(host) || host.includes('://')) throw new Error('Укажи домен без пути и протокола');
    if (host.includes(':') && !host.startsWith('[')) host = '[' + host + ']';
    const parsed = new URL('http://' + host);
    if (parsed.port || parsed.username || parsed.password || parsed.pathname !== '/') throw new Error('Порт и путь в правиле не поддерживаются');
    host = parsed.hostname.toLowerCase().replace(/\.$/, '');
    if (host.startsWith('www.')) host = host.slice(4);
    if (host.length > 253 || (!host.startsWith('[') && !host.split('.').every(label => /^[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?$/u.test(label)))) throw new Error('Некорректное имя домена');
    return host;
  }
  function bypassed(host) {
    return host === 'localhost' || host.endsWith('.localhost') || host === 'loopback' || /^127\./u.test(host) || /^169\.254\./u.test(host) || host === '[::1]' || /^\[fe[89ab][0-9a-f]:/u.test(host);
  }
  function canonicalRouteHost(value) {
    const host = normalizeHost(value);
    return Object.keys(bundles).find(key => bundles[key].some(suffix => matches(host, suffix))) || host;
  }
  function normalizeRules(input) {
    if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Правила должны быть объектом');
    if (Object.keys(input).length > 1000) throw new Error('Допускается не более 1000 правил');
    const rules = Object.create(null);
    for (const [value, route] of Object.entries(input)) {
      if (route !== 'vpn' && route !== 'direct') throw new Error('Неизвестный маршрут');
      const host = normalizeHost(value);
      if (route === 'vpn' && bypassed(host)) throw new Error('Chrome обходит прокси для localhost и link-local адресов');
      if (Object.hasOwn(rules, host) && rules[host] !== route) throw new Error('Конфликт правил после нормализации: ' + host);
      rules[host] = route;
    }
    return Object.fromEntries(Object.entries(rules).sort(([a], [b]) => a.localeCompare(b)));
  }
  function compileRules(input) {
    const rules = normalizeRules(input);
    const entries = [];
    for (const [host, route] of Object.entries(rules)) {
      entries.push({ host, route, source: host, explicit: true });
      if (route === 'vpn') {
        const key = canonicalRouteHost(host);
        const bundle = Object.hasOwn(bundles, key) ? bundles[key] : [];
        for (const suffix of bundle || []) entries.push({ host: suffix, route, source: host, explicit: false });
      }
    }
    return entries.sort((a, b) => b.host.length - a.host.length || Number(b.explicit) - Number(a.explicit) || a.source.localeCompare(b.source));
  }
  function resolveRoute(input, value) {
    const host = normalizeHost(value);
    if (bypassed(host)) return { host, route: 'direct', source: null, reason: 'browser-bypass' };
    const entry = compileRules(input).find(rule => matches(host, rule.host));
    return entry ? { host, route: entry.route, source: entry.source, inherited: entry.source !== host, bundle: !entry.explicit } : { host, route: 'direct', source: null };
  }
  function buildPacScript(input, port = 1080) {
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Некорректный порт прокси');
    return 'var routeRules=' + JSON.stringify(compileRules(input)) + ';\n' +
      'function FindProxyForURL(url,host){host=host.toLowerCase().replace(/\\.$/,"");if(host.indexOf("www.")===0)host=host.slice(4);' +
      'for(var i=0;i<routeRules.length;i++){var r=routeRules[i];if(host===r.host||dnsDomainIs(host,"."+r.host))return r.route==="vpn"?"SOCKS5 127.0.0.1:' + port + '":"DIRECT";}return "DIRECT";}\n';
  }
  const api = { bundles, matches, normalizeHost, bypassed, canonicalRouteHost, normalizeRules, compileRules, resolveRoute, buildPacScript };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.Routing = Object.freeze(api);
})(globalThis);
