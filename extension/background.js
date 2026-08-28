const PROXY_HOST = "127.0.0.1";
const PROXY_PORT = 1080;
const CONTROLLER = "http://127.0.0.1:9090";
const CONTROLLER_SECRET = "amnezia-browser-local-v1-6f2e62c4";
const UPDATE_ALARM = "amnezia-browser-update-check";
const UPDATE_INTERVAL_MINUTES = 360;
const UPDATE_INTERVAL_MS = UPDATE_INTERVAL_MINUTES * 60 * 1000;
const BACKEND_STATUS_TTL_MS = 5000;
const DELAY_TEST_URL = "https://www.gstatic.com/generate_204";

const DOMAIN_BUNDLES = {
  "youtube.com": [
    "youtube.com",
    "youtu.be",
    "googlevideo.com",
    "ytimg.com",
    "youtube-nocookie.com",
    "ggpht.com",
    "youtubei.googleapis.com",
    "youtube.googleapis.com"
  ],
  "discord.com": [
    "discord.com",
    "discordapp.com",
    "discordapp.net",
    "discord.gg",
    "discord.media"
  ]
};

let cachedBackendStatus = null;
let cachedBackendStatusAt = 0;

function normalizeHost(hostname) {
  const host = String(hostname || "").toLowerCase().replace(/\.$/, "");
  return host.startsWith("www.") ? host.slice(4) : host;
}

function hostMatches(host, suffix) {
  return host === suffix || host.endsWith(`.${suffix}`);
}

function canonicalRouteHost(hostname) {
  const normalized = normalizeHost(hostname);

  for (const [root, bundle] of Object.entries(DOMAIN_BUNDLES)) {
    for (const host of bundle) {
      if (hostMatches(normalized, host)) {
        return root;
      }
    }
  }

  return normalized;
}

function canonicalizeRouteRules(rules) {
  const canonical = {};

  for (const [hostname, route] of Object.entries(rules || {})) {
    if (route !== "vpn") {
      continue;
    }

    const host = canonicalRouteHost(hostname);

    if (host) {
      canonical[host] = "vpn";
    }
  }

  return canonical;
}

function routeRulesEqual(left, right) {
  const leftEntries = Object.entries(left || {});
  const rightEntries = Object.entries(right || {});

  if (leftEntries.length !== rightEntries.length) {
    return false;
  }

  return leftEntries.every(([hostname, route]) => right?.[hostname] === route);
}

function expandVpnHosts(rules) {
  const hosts = new Set();

  for (const [hostname, route] of Object.entries(rules)) {
    if (route !== "vpn") {
      continue;
    }

    const normalized = canonicalRouteHost(hostname);
    const bundle = DOMAIN_BUNDLES[normalized] || [normalized];

    for (const host of bundle) {
      if (host) {
        hosts.add(host);
      }
    }
  }

  return Array.from(hosts);
}

function buildPacScript(vpnHosts) {
  const hosts = JSON.stringify(vpnHosts);

  return `
var vpnHosts = ${hosts};
function matchesVpnHost(host) {
  host = host.toLowerCase();
  for (var i = 0; i < vpnHosts.length; i++) {
    var ruleHost = vpnHosts[i];
    if (host === ruleHost || dnsDomainIs(host, "." + ruleHost)) {
      return true;
    }
  }
  return false;
}
function FindProxyForURL(url, host) {
  if (matchesVpnHost(host)) {
    return "SOCKS5 ${PROXY_HOST}:${PROXY_PORT}";
  }
  return "DIRECT";
}
`;
}

async function syncProxyRules() {
  const stored = await chrome.storage.local.get("routeRules");
  const storedRules = stored.routeRules || {};
  const rules = canonicalizeRouteRules(storedRules);

  if (!routeRulesEqual(storedRules, rules)) {
    await chrome.storage.local.set({
      routeRules: rules
    });
  }

  const vpnHosts = expandVpnHosts(rules);

  if (vpnHosts.length === 0) {
    await chrome.proxy.settings.set({
      value: { mode: "direct" },
      scope: "regular"
    });

    return { ok: true, applied: false };
  }

  await chrome.proxy.settings.set({
    value: {
      mode: "pac_script",
      pacScript: {
        data: buildPacScript(vpnHosts),
        mandatory: true
      }
    },
    scope: "regular"
  });

  return { ok: true, applied: true };
}

async function fetchWithTimeout(url, options, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    return await fetch(url, {
      ...options,
      signal: controller.signal
    });
  } finally {
    clearTimeout(timer);
  }
}

async function measureProxyDelay(proxyName) {
  const response = await fetchWithTimeout(
    `${CONTROLLER}/proxies/${encodeURIComponent(proxyName)}/delay?url=${encodeURIComponent(DELAY_TEST_URL)}&timeout=6000&expected=204`,
    {
      headers: {
        Authorization: `Bearer ${CONTROLLER_SECRET}`
      },
      cache: "no-store"
    },
    7000
  );

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }

  const data = await response.json();
  const delay = Number(data.delay);

  if (!Number.isFinite(delay) || delay < 0) {
    throw new Error("Invalid delay result");
  }

  return delay;
}

async function backendStatus(force = false) {
  const now = Date.now();

  if (!force && cachedBackendStatus && now - cachedBackendStatusAt < BACKEND_STATUS_TTL_MS) {
    return cachedBackendStatus;
  }

  let result;

  try {
    const response = await fetchWithTimeout(
      `${CONTROLLER}/version`,
      {
        headers: {
          Authorization: `Bearer ${CONTROLLER_SECRET}`
        },
        cache: "no-store"
      },
      3000
    );

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    const data = await response.json();

    try {
      const [vpnResult, directResult] = await Promise.allSettled([
        measureProxyDelay("AMNEZIA"),
        measureProxyDelay("DIRECT")
      ]);

      if (vpnResult.status !== "fulfilled") {
        throw vpnResult.reason;
      }

      const delay = vpnResult.value;
      const directDelay = directResult.status === "fulfilled"
        ? directResult.value
        : null;

      result = {
        ok: true,
        running: true,
        tunnel_ready: true,
        delay,
        direct_delay: directDelay,
        vpn_overhead: Number.isFinite(directDelay) ? Math.max(0, delay - directDelay) : null,
        version: data.version || ""
      };
    } catch (error) {
      result = {
        ok: false,
        running: true,
        tunnel_ready: false,
        version: data.version || "",
        error: error.name === "AbortError" ? "Tunnel test timeout" : error.message
      };
    }
  } catch (error) {
    result = {
      ok: false,
      running: false,
      tunnel_ready: false,
      error: error.name === "AbortError" ? "Backend timeout" : error.message
    };
  }

  cachedBackendStatus = result;
  cachedBackendStatusAt = Date.now();
  return result;
}

function parseVersion(value) {
  return String(value || "")
    .replace(/^v/i, "")
    .split(".")
    .map((part) => Number.parseInt(part, 10) || 0);
}

function isNewerVersion(latest, current) {
  const a = parseVersion(latest);
  const b = parseVersion(current);
  const length = Math.max(a.length, b.length);

  for (let i = 0; i < length; i++) {
    const left = a[i] || 0;
    const right = b[i] || 0;

    if (left > right) {
      return true;
    }

    if (left < right) {
      return false;
    }
  }

  return false;
}

async function getRepository() {
  try {
    const response = await fetch(chrome.runtime.getURL("release.json"), {
      cache: "no-store"
    });

    const data = await response.json();
    const repository = String(data.repository || "").trim();

    if (!repository || repository === "__REPOSITORY__") {
      return "";
    }

    return repository;
  } catch {
    return "";
  }
}

async function checkUpdate() {
  const repository = await getRepository();

  if (!repository) {
    const result = {
      ok: true,
      configured: false,
      update_available: false
    };

    await chrome.storage.local.set({
      updateStatus: result,
      updateCheckedAt: Date.now()
    });

    return result;
  }

  try {
    const response = await fetchWithTimeout(
      `https://api.github.com/repos/${repository}/releases/latest`,
      {
        headers: {
          Accept: "application/vnd.github+json"
        },
        cache: "no-store"
      },
      10000
    );

    if (!response.ok) {
      throw new Error(`GitHub HTTP ${response.status}`);
    }

    const release = await response.json();
    const currentVersion = chrome.runtime.getManifest().version;
    const latestVersion = String(release.tag_name || "").replace(/^v/i, "");
    const result = {
      ok: true,
      configured: true,
      update_available: isNewerVersion(latestVersion, currentVersion),
      current_version: currentVersion,
      latest_version: latestVersion,
      release_url: release.html_url || ""
    };

    await chrome.storage.local.set({
      updateStatus: result,
      updateCheckedAt: Date.now()
    });

    return result;
  } catch (error) {
    const result = {
      ok: false,
      configured: true,
      update_available: false,
      error: error.name === "AbortError" ? "GitHub timeout" : error.message
    };

    await chrome.storage.local.set({
      updateStatus: result,
      updateCheckedAt: Date.now()
    });

    return result;
  }
}

async function checkUpdateIfStale() {
  const stored = await chrome.storage.local.get("updateCheckedAt");
  const checkedAt = Number(stored.updateCheckedAt) || 0;

  if (Date.now() - checkedAt < UPDATE_INTERVAL_MS) {
    return null;
  }

  return checkUpdate();
}

async function ensureUpdateAlarm() {
  const alarm = await chrome.alarms.get(UPDATE_ALARM);

  if (!alarm) {
    chrome.alarms.create(UPDATE_ALARM, {
      periodInMinutes: UPDATE_INTERVAL_MINUTES
    });
  }
}

chrome.runtime.onInstalled.addListener(() => {
  syncProxyRules().catch(() => {});
  ensureUpdateAlarm().catch(() => {});
  checkUpdate().catch(() => {});
});

chrome.runtime.onStartup.addListener(() => {
  syncProxyRules().catch(() => {});
  ensureUpdateAlarm().catch(() => {});
  checkUpdateIfStale().catch(() => {});
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === UPDATE_ALARM) {
    checkUpdate().catch(() => {});
  }
});

chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName === "local" && changes.routeRules) {
    syncProxyRules().catch(() => {});
  }
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "BACKEND_STATUS") {
    backendStatus(Boolean(message.force)).then(sendResponse);
    return true;
  }

  if (message?.type === "SYNC_PROXY") {
    syncProxyRules()
      .then(sendResponse)
      .catch((error) => sendResponse({ ok: false, error: error.message }));
    return true;
  }

  if (message?.type === "NORMALIZE_HOST") {
    sendResponse({
      ok: true,
      host: canonicalRouteHost(message.host)
    });
    return false;
  }

  if (message?.type === "CHECK_UPDATE") {
    checkUpdate().then(sendResponse);
    return true;
  }

  if (message?.type === "GET_UPDATE_STATUS") {
    chrome.storage.local
      .get(["updateStatus", "updateCheckedAt"])
      .then((stored) => {
        sendResponse({
          ok: true,
          status: stored.updateStatus || null,
          checked_at: stored.updateCheckedAt || null
        });
      })
      .catch((error) => {
        sendResponse({
          ok: false,
          status: null,
          checked_at: null,
          error: error.message
        });
      });
    return true;
  }

  return false;
});

ensureUpdateAlarm().catch(() => {});
syncProxyRules().catch(() => {});
