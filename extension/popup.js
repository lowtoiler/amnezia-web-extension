const siteElement = document.getElementById("site");
const backendStatusElement = document.getElementById("backendStatus");
const statusDot = document.getElementById("statusDot");
const messageElement = document.getElementById("message");
const directButton = document.getElementById("directButton");
const vpnButton = document.getElementById("vpnButton");
const updateCard = document.getElementById("updateCard");
const updateText = document.getElementById("updateText");
const updateButton = document.getElementById("updateButton");

let routeHostname = "";
let releaseURL = "";

function setRouteButtonsEnabled(enabled) {
  directButton.disabled = !enabled;
  vpnButton.disabled = !enabled;
}

function renderRule(rule) {
  directButton.classList.toggle("active", rule === "direct");
  vpnButton.classList.toggle("active", rule === "vpn");
}

async function getCurrentHostname() {
  const tabs = await chrome.tabs.query({
    active: true,
    currentWindow: true
  });

  const tab = tabs[0];

  if (!tab?.url) {
    return "";
  }

  try {
    const url = new URL(tab.url);

    if (url.protocol !== "http:" && url.protocol !== "https:") {
      return "";
    }

    return url.hostname.toLowerCase();
  } catch {
    return "";
  }
}

async function normalizeHostname(hostname) {
  const response = await chrome.runtime.sendMessage({
    type: "NORMALIZE_HOST",
    host: hostname
  });

  return response?.host || hostname;
}

async function getRule(hostname) {
  const stored = await chrome.storage.local.get("routeRules");
  return stored.routeRules?.[hostname] || "direct";
}

async function saveRule(hostname, rule) {
  const stored = await chrome.storage.local.get("routeRules");
  const rules = stored.routeRules || {};

  if (rule === "direct") {
    delete rules[hostname];
  } else {
    rules[hostname] = rule;
  }

  await chrome.storage.local.set({
    routeRules: rules
  });
}

async function refreshBackendStatus() {
  const status = await chrome.runtime.sendMessage({
    type: "BACKEND_STATUS"
  });

  if (status?.tunnel_ready) {
    const delay = Number(status.delay);
    const directDelay = status.direct_delay == null
      ? Number.NaN
      : Number(status.direct_delay);

    if (Number.isFinite(delay) && Number.isFinite(directDelay)) {
      const delta = delay - directDelay;
      const deltaText = delta >= 0 ? `+${delta}` : String(delta);
      backendStatusElement.textContent = `VPN RTT ${delay} мс · Direct ${directDelay} мс · Δ ${deltaText} мс`;
    } else if (Number.isFinite(delay)) {
      backendStatusElement.textContent = `VPN RTT ${delay} мс`;
    } else {
      backendStatusElement.textContent = "Подключен";
    }

    statusDot.style.background = "#22c55e";
    return true;
  }

  if (status?.running) {
    backendStatusElement.textContent = "VPN недоступен";
    statusDot.style.background = "#f59e0b";
    return false;
  }

  backendStatusElement.textContent = "Не запущен";
  statusDot.style.background = "#ef4444";
  return false;
}

function renderUpdate(status) {
  if (!status?.update_available || !status.release_url) {
    updateCard.hidden = true;
    releaseURL = "";
    return;
  }

  releaseURL = status.release_url;
  updateText.textContent = `Доступна версия ${status.latest_version}`;
  updateCard.hidden = false;
}

async function refreshUpdateStatus() {
  const cached = await chrome.runtime.sendMessage({
    type: "GET_UPDATE_STATUS"
  });

  if (cached?.status) {
    renderUpdate(cached.status);
  }

  const checkedAt = Number(cached?.checked_at) || 0;
  const sixHours = 6 * 60 * 60 * 1000;

  if (Date.now() - checkedAt < sixHours) {
    return;
  }

  const current = await chrome.runtime.sendMessage({
    type: "CHECK_UPDATE"
  });

  renderUpdate(current);
}

async function changeRule(rule) {
  if (!routeHostname) {
    return;
  }

  setRouteButtonsEnabled(false);

  try {
    await saveRule(routeHostname, rule);
    renderRule(rule);

    const result = await chrome.runtime.sendMessage({
      type: "SYNC_PROXY"
    });

    if (!result?.ok) {
      throw new Error(result?.error || "Не удалось применить правило");
    }

    const backendReady = await refreshBackendStatus();

    if (rule === "vpn" && !backendReady) {
      messageElement.textContent = "VPN выбран, но backend не запущен. Direct fallback отключен.";
    } else {
      messageElement.textContent = rule === "vpn"
        ? `${routeHostname} → Amnezia Premium`
        : `${routeHostname} → Direct`;
    }
  } catch (error) {
    messageElement.textContent = error.message;
  } finally {
    setRouteButtonsEnabled(true);
  }
}

async function initialize() {
  setRouteButtonsEnabled(false);

  const hostname = await getCurrentHostname();

  if (!hostname) {
    siteElement.textContent = "Служебная страница";
    backendStatusElement.textContent = "Проверка...";
    await refreshBackendStatus();
    refreshUpdateStatus().catch(() => {});
    return;
  }

  routeHostname = await normalizeHostname(hostname);
  siteElement.textContent = hostname;
  renderRule(await getRule(routeHostname));
  setRouteButtonsEnabled(true);

  const backendReady = await refreshBackendStatus();

  if (!backendReady) {
    messageElement.textContent = "Запусти install.ps1 или install.sh с Amnezia Premium .conf";
  }

  refreshUpdateStatus().catch(() => {});
}

directButton.addEventListener("click", () => changeRule("direct"));
vpnButton.addEventListener("click", () => changeRule("vpn"));

updateButton.addEventListener("click", () => {
  if (releaseURL) {
    chrome.tabs.create({
      url: releaseURL
    });
  }
});

initialize().catch((error) => {
  messageElement.textContent = error.message;
});
