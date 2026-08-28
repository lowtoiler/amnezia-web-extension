# Amnezia Browser

Version 1.

Amnezia Browser is an unofficial Chromium extension that routes only the websites you choose through your own Amnezia Premium configuration.

## Supported browsers

Primary targets:

- Google Chrome
- Chromium
- Microsoft Edge
- Brave

It should also work with Chromium-based browsers that support Manifest V3 and the `chrome.proxy` API, including:

- Vivaldi
- Opera
- Opera GX
- Yandex Browser
- Thorium
- Ungoogled Chromium

Firefox and Safari are not currently supported.

## Windows

1. Extract the archive.
2. Run `./install.ps1` in PowerShell.
3. Select your Amnezia Premium `.conf` file.
4. Open your browser's extensions page, enable Developer Mode, choose **Load unpacked**, and select the `extension` folder.

No Go installation, Wintun driver, or system-wide VPN is required.

Common extension pages:

- Chrome / Chromium / Brave / Vivaldi / Yandex Browser / Thorium / Ungoogled Chromium: `chrome://extensions`
- Microsoft Edge: `edge://extensions`
- Opera / Opera GX: `opera://extensions`

## Linux

```bash
chmod +x install.sh uninstall.sh
./install.sh
```

Select your Amnezia Premium `.conf` file when prompted, then load the `extension` folder as an unpacked extension in your Chromium-based browser.

## How it works

- Selected websites → `127.0.0.1:1080` → AmneziaWG → Amnezia Premium
- All other websites → Direct
- System routing tables are not modified
- No OS-level TUN interface is created
- Other applications are not routed through the VPN
- If the local backend is unavailable, VPN-routed websites do not automatically fall back to Direct
- GitHub Releases are checked for project updates every 6 hours

The local backend uses the official [mihomo](https://github.com/MetaCubeX/mihomo) release. The installer downloads the required binary directly from GitHub and verifies its SHA-256 checksum before installation.

## Per-site routing

Open a website and click the Amnezia Browser icon.

Choose:

- **Direct** — use your normal internet connection
- **VPN** — route matching browser requests through Amnezia Premium

Example:

```text
chatgpt.com   → VPN
youtube.com   → VPN
github.com    → Direct
google.com    → Direct
```

Rules are applied per domain. Some services use multiple related domains; Amnezia Browser includes bundles for selected services such as YouTube and Discord. Saved rules from older Version 1 builds are normalized automatically when the backend extension starts.

## Latency and RTT

The popup shows three values when both measurements are available:

- **VPN RTT** — the mihomo delay test through the `AMNEZIA` proxy
- **Direct** — the same test through mihomo's built-in `DIRECT` path
- **Δ** — the difference between VPN RTT and Direct

The test target is `https://www.gstatic.com/generate_204`. This is not an ICMP ping to the VPN server. It is a proxy-path RTT measurement to an HTTP endpoint, so the result also depends on the route to the test target.

Interpret the values together:

- `VPN 300 ms / Direct 25 ms / Δ +275 ms` means the tunnel, VPN endpoint, or route behind it is adding most of the delay.
- `VPN 300 ms / Direct 250 ms / Δ +50 ms` means the local/ISP path or the test destination is already slow before the VPN overhead.
- A much lower value after reinstalling can mean the previous number was inflated by connection-handshake differences rather than the steady RTT.

Generated configs enable mihomo `unified-delay` so the delay API reports RTT without proxy handshake differences, and `tcp-concurrent` so TCP connection attempts can race DNS-resolved addresses and use the first successful path. Re-run the installer after updating the project so the local runtime config is regenerated with these settings.

## Amnezia Premium configuration

Your `.conf` file can be stored anywhere on your computer. The installer always asks you to select the configuration file unless you explicitly pass a path to the installer.

The original `.conf` file is not stored inside the browser extension. The installer creates a local runtime configuration for the backend.

Do not publish or share your `.conf` file. It contains private VPN credentials.

The current installer accepts exactly one `[Interface]` and one `[Peer]` section. Multi-peer WireGuard files are rejected explicitly instead of being converted incorrectly. AWG 1.x/1.5/2.x/3.x fields used by Amnezia Premium are preserved where supported by mihomo. If a configuration uses a non-numeric `PersistentKeepalive` range that cannot be represented safely by this mihomo configuration, the installer prints a warning and omits that field.

Before replacing an existing backend, both installers validate the generated mihomo configuration. If startup or the tunnel test fails after replacement starts, the previous core/configuration is restored; Linux also restores the previous autostart file.

## Updates

Amnezia Browser checks the project's GitHub Releases every 6 hours.

The update card is shown only when a version newer than the installed version is available. Updates are not installed silently; the button opens the corresponding GitHub Release.

The popup also includes a centered Telegram link for project update notifications: [@lowtoiler](https://t.me/lowtoiler).

## Important limitation

Routing is based on Chromium's proxy stack. Traffic that does not use the browser proxy path, such as some WebRTC or other UDP-based browser traffic, is not guaranteed to pass through the local SOCKS proxy.

## Uninstall

Windows:

```powershell
./uninstall.ps1
```

Linux:

```bash
./uninstall.sh
```

## License

Project code is licensed under the MIT License.

## Disclaimer

Amnezia Browser is an independent, unofficial project. It is not affiliated with, endorsed by, or maintained by AmneziaVPN or MetaCubeX.
