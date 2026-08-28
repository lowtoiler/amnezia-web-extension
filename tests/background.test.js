const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const chrome = {
  storage: {
    local: {
      get: async () => ({}),
      set: async () => {}
    },
    onChanged: {
      addListener: () => {}
    }
  },
  proxy: {
    settings: {
      set: async () => {}
    }
  },
  alarms: {
    get: async () => null,
    create: () => {},
    onAlarm: {
      addListener: () => {}
    }
  },
  runtime: {
    onInstalled: {
      addListener: () => {}
    },
    onStartup: {
      addListener: () => {}
    },
    onMessage: {
      addListener: () => {}
    },
    getURL: (path) => `chrome-extension://test/${path}`,
    getManifest: () => ({ version: "1" })
  }
};

const context = vm.createContext({
  chrome,
  fetch: async () => {
    throw new Error("fetch must not run in routing unit tests");
  },
  AbortController,
  clearTimeout,
  console,
  Date,
  JSON,
  Number,
  setTimeout,
  URL
});

const source = fs.readFileSync(path.join(__dirname, "..", "extension", "background.js"), "utf8");
vm.runInContext(source, context, { filename: "extension/background.js" });

assert.equal(context.normalizeHost("WWW.Example.COM."), "example.com");
assert.equal(context.canonicalRouteHost("m.youtube.com"), "youtube.com");
assert.equal(context.canonicalRouteHost("youtu.be"), "youtube.com");
assert.equal(context.canonicalRouteHost("cdn.discordapp.com"), "discord.com");
assert.equal(context.canonicalRouteHost("example.com"), "example.com");

const migratedRules = JSON.parse(JSON.stringify(context.canonicalizeRouteRules({
  "m.youtube.com": "vpn",
  "cdn.discordapp.com": "vpn",
  "example.com": "direct"
})));
assert.deepEqual(migratedRules, {
  "youtube.com": "vpn",
  "discord.com": "vpn"
});

const youtubeHosts = Array.from(context.expandVpnHosts({ "m.youtube.com": "vpn" }));
assert.ok(youtubeHosts.includes("youtube.com"));
assert.ok(youtubeHosts.includes("youtu.be"));
assert.ok(youtubeHosts.includes("googlevideo.com"));
assert.ok(youtubeHosts.includes("youtubei.googleapis.com"));
assert.ok(youtubeHosts.includes("youtube.googleapis.com"));

const discordHosts = Array.from(context.expandVpnHosts({ "canary.discord.com": "vpn" }));
assert.ok(discordHosts.includes("discord.com"));
assert.ok(discordHosts.includes("discordapp.net"));
assert.ok(discordHosts.includes("discord.media"));

const pac = context.buildPacScript(["example.com"]);
assert.match(pac, /SOCKS5 127\.0\.0\.1:1080/);
assert.match(pac, /dnsDomainIs/);

assert.equal(context.isNewerVersion("1.0.1", "1"), true);
assert.equal(context.isNewerVersion("1.0.0", "1"), false);
assert.equal(context.isNewerVersion("1", "1.0.1"), false);

context.fetch = async (url) => {
  if (url.endsWith("/version")) {
    return { ok: true, json: async () => ({ version: "1.19.30" }) };
  }

  if (url.includes("/proxies/AMNEZIA/delay")) {
    return { ok: true, json: async () => ({ delay: 82 }) };
  }

  if (url.includes("/proxies/DIRECT/delay")) {
    return { ok: true, json: async () => ({ delay: 21 }) };
  }

  throw new Error(`unexpected fetch: ${url}`);
};

context.backendStatus(true)
  .then((status) => {
    assert.equal(status.tunnel_ready, true);
    assert.equal(status.delay, 82);
    assert.equal(status.direct_delay, 21);
    assert.equal(status.vpn_overhead, 61);
    console.log("background routing/status tests: OK");
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
