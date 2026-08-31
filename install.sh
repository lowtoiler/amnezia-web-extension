#!/usr/bin/env bash
set -euo pipefail

CORE_VERSION="v1.19.30"
CONTROLLER_SECRET="amnezia-browser-local-v1-6f2e62c4"
INSTALL_DIR="$HOME/.local/lib/amnezia-browser"
CONFIG_DIR="$HOME/.config/amnezia-browser"
AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/amnezia-browser.desktop"
CORE="$INSTALL_DIR/mihomo"
RUNTIME_CONFIG="$CONFIG_DIR/config.yaml"
PID_FILE="$INSTALL_DIR/mihomo.pid"
LOG_FILE="$INSTALL_DIR/mihomo.log"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

ini_get() {
  local section="$1"
  local key="$2"
  local file="$3"

  awk -v want_section="$section" -v want_key="$key" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    BEGIN {
      current = ""
    }
    {
      line = trim($0)

      if (line == "" || substr(line, 1, 1) == "#" || substr(line, 1, 1) == ";") {
        next
      }

      if (substr(line, 1, 1) == "[" && substr(line, length(line), 1) == "]") {
        current = tolower(trim(substr(line, 2, length(line) - 2)))
        next
      }

      if (current != tolower(want_section)) {
        next
      }

      pos = index(line, "=")

      if (pos < 2) {
        next
      }

      k = tolower(trim(substr(line, 1, pos - 1)))

      if (k == tolower(want_key)) {
        print trim(substr(line, pos + 1))
        exit
      }
    }
  ' "$file"
}

yaml_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

csv_yaml() {
  local value="$1"
  local first=1
  local part

  printf '['
  IFS=',' read -ra parts <<< "$value"

  for part in "${parts[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"

    [[ -n "$part" ]] || continue

    if (( first == 0 )); then
      printf ', '
    fi

    yaml_quote "$part"
    first=0
  done

  printf ']'
}

emit_option() {
  local ini_key="$1"
  local yaml_key="$2"
  local kind="$3"
  local conf="$4"
  local value

  value="$(ini_get Interface "$ini_key" "$conf")"

  [[ -n "$value" ]] || return 0

  if [[ "$kind" == "bool" ]]; then
    value="${value,,}"

    case "$value" in
      true|on|1) value="true" ;;
      false|off|0) value="false" ;;
      *) die "Invalid $ini_key value: $value" ;;
    esac

    printf '      %s: %s\n' "$yaml_key" "$value"
    return
  fi

  if [[ "$kind" == "number" && "$value" =~ ^[0-9]+$ ]]; then
    printf '      %s: %s\n' "$yaml_key" "$value"
    return
  fi

  printf '      %s: ' "$yaml_key"
  yaml_quote "$value"
  printf '\n'
}

core_running() {
  local target
  local proc
  local exe

  target="$(readlink -f "$CORE" 2>/dev/null || true)"
  [[ -n "$target" ]] || return 1

  for proc in /proc/[0-9]*; do
    [[ -e "$proc/exe" ]] || continue
    exe="$(readlink "$proc/exe" 2>/dev/null || true)"
    exe="${exe% (deleted)}"

    if [[ "$exe" == "$target" ]]; then
      return 0
    fi
  done

  return 1
}

stop_core() {
  local target
  local proc
  local pid
  local exe
  local -a pids=()

  target="$(readlink -f "$CORE" 2>/dev/null || true)"

  if [[ -n "$target" ]]; then
    for proc in /proc/[0-9]*; do
      [[ -e "$proc/exe" ]] || continue
      exe="$(readlink "$proc/exe" 2>/dev/null || true)"
      exe="${exe% (deleted)}"

      if [[ "$exe" == "$target" ]]; then
        pids+=("${proc##*/}")
      fi
    done
  fi

  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done

  for _ in {1..30}; do
    local alive=0

    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        alive=1
      fi
    done

    (( alive == 0 )) && break
    sleep 0.1
  done

  for pid in "${pids[@]}"; do
    kill -9 "$pid" 2>/dev/null || true
  done

  rm -f "$PID_FILE"
}

download_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 "$url" -o "$output"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget --timeout=15 --tries=3 -O "$output" "$url"
    return
  fi

  die "curl or wget is required."
}

controller_get() {
  local url="$1"
  local timeout="${2:-5}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsS \
      --max-time "$timeout" \
      -H "Authorization: Bearer $CONTROLLER_SECRET" \
      "$url"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO- \
      --timeout="$timeout" \
      --tries=1 \
      --header="Authorization: Bearer $CONTROLLER_SECRET" \
      "$url"
    return
  fi

  die "curl or wget is required."
}

sha256_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return
  fi

  die "sha256sum or shasum is required."
}

choose_config() {
  if [[ $# -gt 0 && -n "${1:-}" ]]; then
    readlink -f "$1"
    return
  fi

  if command -v zenity >/dev/null 2>&1; then
    zenity --file-selection --title="Select Amnezia Premium config" --file-filter="*.conf"
    return
  fi

  local path
  printf 'Amnezia Premium .conf path: ' >&2
  read -r path
  readlink -f "$path"
}

if ! CONF="$(choose_config "${1:-}")"; then
  die "Amnezia Premium config was not selected or could not be resolved."
fi

[[ -f "$CONF" ]] || die "Config not found: $CONF"

INTERFACE_COUNT="$(awk 'BEGIN { count=0 } { line=tolower($0); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); if (line == "[interface]") count++ } END { print count }' "$CONF")"
PEER_COUNT="$(awk 'BEGIN { count=0 } { line=tolower($0); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); if (line == "[peer]") count++ } END { print count }' "$CONF")"

[[ "$INTERFACE_COUNT" == "1" && "$PEER_COUNT" == "1" ]] || die "Config must contain exactly one [Interface] and one [Peer] section."

PRIVATE_KEY="$(ini_get Interface PrivateKey "$CONF")"
PUBLIC_KEY="$(ini_get Peer PublicKey "$CONF")"
PSK="$(ini_get Peer PresharedKey "$CONF")"
ENDPOINT="$(ini_get Peer Endpoint "$CONF")"
ADDRESS="$(ini_get Interface Address "$CONF")"
DNS="$(ini_get Interface DNS "$CONF")"
ALLOWED="$(ini_get Peer AllowedIPs "$CONF")"
PERSISTENT_KEEPALIVE="$(ini_get Peer PersistentKeepalive "$CONF")"
MTU="$(ini_get Interface MTU "$CONF")"

if [[ -n "$PERSISTENT_KEEPALIVE" && ! "$PERSISTENT_KEEPALIVE" =~ ^[0-9]+$ ]]; then
  printf 'Warning: PersistentKeepalive %s is not numeric and is not supported by this mihomo configuration; it will be omitted.\n' "$PERSISTENT_KEEPALIVE" >&2
fi

[[ -n "$PRIVATE_KEY" ]] || die "Missing Interface.PrivateKey"
[[ -n "$PUBLIC_KEY" ]] || die "Missing Peer.PublicKey"
[[ -n "$ENDPOINT" ]] || die "Missing Peer.Endpoint"
[[ -n "$ADDRESS" ]] || die "Missing Interface.Address"

if [[ "$ENDPOINT" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
  SERVER="${BASH_REMATCH[1]}"
  PORT="${BASH_REMATCH[2]}"
elif [[ "$ENDPOINT" =~ ^(.+):([0-9]+)$ ]]; then
  SERVER="${BASH_REMATCH[1]}"
  PORT="${BASH_REMATCH[2]}"
else
  die "Invalid Endpoint: $ENDPOINT"
fi

IPV4=""
IPV6=""
IFS=',' read -ra ADDRESS_PARTS <<< "$ADDRESS"

for part in "${ADDRESS_PARTS[@]}"; do
  part="${part#"${part%%[![:space:]]*}"}"
  part="${part%"${part##*[![:space:]]}"}"
  addr="${part%%/*}"

  if [[ "$addr" == *:* ]]; then
    [[ -n "$IPV6" ]] || IPV6="$addr"
  else
    [[ -n "$IPV4" ]] || IPV4="$addr"
  fi
done

[[ -n "$IPV4" ]] || die "Amnezia config does not contain an IPv4 Address."

[[ -n "$DNS" ]] || DNS="1.1.1.1"
[[ -n "$ALLOWED" ]] || ALLOWED="0.0.0.0/0"
[[ "$MTU" =~ ^[0-9]+$ ]] || MTU="1420"

case "$(uname -m)" in
  x86_64|amd64)
    ASSET="mihomo-linux-amd64-compatible-v1.19.30.gz"
    EXPECTED_SHA="db214c7a2517e63c150d123178d16d102e03a241ccdae4e5e07ffbe9cf56c6f9"
    ;;
  aarch64|arm64)
    ASSET="mihomo-linux-arm64-v1.19.30.gz"
    EXPECTED_SHA="58896873736d28628f66de3677c8654fa0f180662523148e136cff4f6e890069"
    ;;
  *)
    die "Unsupported Linux architecture: $(uname -m)"
    ;;
esac

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$AUTOSTART_DIR"
chmod 700 "$INSTALL_DIR" "$CONFIG_DIR"

TMP_DIR="$(mktemp -d)"
ARCHIVE="$TMP_DIR/$ASSET"
STAGED_CORE="$TMP_DIR/mihomo"
STAGED_CONFIG="$TMP_DIR/config.yaml"
BACKUP_CORE="$TMP_DIR/mihomo.previous"
BACKUP_CONFIG="$TMP_DIR/config.previous.yaml"
BACKUP_AUTOSTART="$TMP_DIR/amnezia-browser.previous.desktop"
URL="https://github.com/MetaCubeX/mihomo/releases/download/$CORE_VERSION/$ASSET"
HAD_CORE=0
HAD_CONFIG=0
HAD_AUTOSTART=0
OLD_RUNNING=0
SWAP_STARTED=0
INSTALL_OK=0

cleanup() {
  local status=$?

  if (( status != 0 && SWAP_STARTED == 1 && INSTALL_OK == 0 )); then
    set +e
    stop_core

    if (( HAD_CORE == 1 )); then
      cp -f "$BACKUP_CORE" "$CORE"
      chmod 700 "$CORE"
    else
      rm -f "$CORE"
    fi

    if (( HAD_CONFIG == 1 )); then
      cp -f "$BACKUP_CONFIG" "$RUNTIME_CONFIG"
      chmod 600 "$RUNTIME_CONFIG"
    else
      rm -f "$RUNTIME_CONFIG"
    fi

    if (( HAD_AUTOSTART == 1 )); then
      cp -f "$BACKUP_AUTOSTART" "$AUTOSTART_FILE"
      chmod 600 "$AUTOSTART_FILE"
    else
      rm -f "$AUTOSTART_FILE"
    fi

    if (( HAD_CORE == 1 && HAD_CONFIG == 1 && OLD_RUNNING == 1 )); then
      nohup "$CORE" -d "$INSTALL_DIR" -f "$RUNTIME_CONFIG" > "$LOG_FILE" 2>&1 &
      printf '%s\n' "$!" > "$PID_FILE"
    fi

    set -e
  fi

  rm -rf "$TMP_DIR"
  return "$status"
}

trap cleanup EXIT

printf '%s\n' "Downloading backend..."
download_file "$URL" "$ARCHIVE"

ACTUAL_SHA="$(sha256_file "$ARCHIVE")"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || die "Backend checksum mismatch."

gzip -dc "$ARCHIVE" > "$STAGED_CORE"
chmod 700 "$STAGED_CORE"

REMOTE_DNS_RESOLVE="false"

if command -v getent >/dev/null 2>&1; then
  if ! getent ahostsv4 www.youtube.com 2>/dev/null |
    awk '$1 != "0.0.0.0" && $1 !~ /^127\./ { found=1 } END { exit(found ? 0 : 1) }'
  then
    REMOTE_DNS_RESOLVE="true"
  fi
else
  REMOTE_DNS_RESOLVE="true"
fi

if [[ "$REMOTE_DNS_RESOLVE" == "true" ]]; then
  printf 'Warning: Local DNS cannot resolve www.youtube.com; tunnel DNS will be used.\n' >&2
fi

{
  printf 'mixed-port: 1080\n'
  printf 'allow-lan: false\n'
  printf 'bind-address: "127.0.0.1"\n'
  printf 'mode: rule\n'
  printf 'unified-delay: true\n'
  printf 'tcp-concurrent: true\n'
  printf 'log-level: warning\n'
  printf 'external-controller: "127.0.0.1:9090"\n'
  printf 'secret: '
  yaml_quote "$CONTROLLER_SECRET"
  printf '\n'
  printf 'proxies:\n'
  printf '  - name: "AMNEZIA"\n'
  printf '    type: wireguard\n'
  printf '    server: '
  yaml_quote "$SERVER"
  printf '\n'
  printf '    port: %s\n' "$PORT"
  printf '    ip: '
  yaml_quote "$IPV4"
  printf '\n'

  if [[ -n "$IPV6" ]]; then
    printf '    ipv6: '
    yaml_quote "$IPV6"
    printf '\n'
  fi

  printf '    private-key: '
  yaml_quote "$PRIVATE_KEY"
  printf '\n'
  printf '    public-key: '
  yaml_quote "$PUBLIC_KEY"
  printf '\n'

  if [[ -n "$PSK" ]]; then
    printf '    pre-shared-key: '
    yaml_quote "$PSK"
    printf '\n'
  fi

  printf '    allowed-ips: '
  csv_yaml "$ALLOWED"
  printf '\n'
  printf '    udp: true\n'
  printf '    mtu: %s\n' "$MTU"
  printf '    remote-dns-resolve: %s\n' "$REMOTE_DNS_RESOLVE"
  printf '    dns: '
  csv_yaml "$DNS"
  printf '\n'

  if [[ "$PERSISTENT_KEEPALIVE" =~ ^[0-9]+$ ]]; then
    printf '    persistent-keepalive: %s\n' "$PERSISTENT_KEEPALIVE"
  fi

  HAS_AWG=0
  IS_V3=0

  for key in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5 J1 J2 J3 ITime HeaderProtectionKey ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts RandomTrailers DisableCookies; do
    if [[ -n "$(ini_get Interface "$key" "$CONF")" ]]; then
      HAS_AWG=1
    fi
  done

  for key in HeaderProtectionKey ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts RandomTrailers DisableCookies; do
    if [[ -n "$(ini_get Interface "$key" "$CONF")" ]]; then
      IS_V3=1
    fi
  done

  if (( HAS_AWG == 1 )); then
    printf '    amnezia-wg-option:\n'

    if (( IS_V3 == 1 )); then
      printf '      version: 3\n'
    fi

    emit_option Jc jc number "$CONF"
    emit_option Jmin jmin number "$CONF"
    emit_option Jmax jmax number "$CONF"
    emit_option S1 s1 number "$CONF"
    emit_option S2 s2 number "$CONF"
    emit_option S3 s3 number "$CONF"
    emit_option S4 s4 number "$CONF"
    emit_option H1 h1 string "$CONF"
    emit_option H2 h2 string "$CONF"
    emit_option H3 h3 string "$CONF"
    emit_option H4 h4 string "$CONF"
    emit_option I1 i1 string "$CONF"
    emit_option I2 i2 string "$CONF"
    emit_option I3 i3 string "$CONF"
    emit_option I4 i4 string "$CONF"
    emit_option I5 i5 string "$CONF"
    emit_option J1 j1 string "$CONF"
    emit_option J2 j2 string "$CONF"
    emit_option J3 j3 string "$CONF"
    emit_option ITime itime number "$CONF"
    emit_option HeaderProtectionKey header-protection-key string "$CONF"
    emit_option ContentPaddingAddition content-padding-addition string "$CONF"
    emit_option RekeyAfterTime rekey-after-time string "$CONF"
    emit_option RekeyTimeout rekey-timeout string "$CONF"
    emit_option RejectAfterTime reject-after-time string "$CONF"
    emit_option KeepaliveTimeout keepalive-timeout string "$CONF"
    emit_option MaxHandshakeAttempts max-handshake-attempts string "$CONF"
    emit_option RandomTrailers random-trailers bool "$CONF"
    emit_option DisableCookies disable-cookies bool "$CONF"
  fi

  printf 'rules:\n'
  printf '  - "MATCH,AMNEZIA"\n'
} > "$STAGED_CONFIG"

chmod 600 "$STAGED_CONFIG"

VALIDATION="$("$STAGED_CORE" -t -d "$TMP_DIR" -f "$STAGED_CONFIG" 2>&1)" || {
  printf '%s\n' "$VALIDATION" >&2
  die "Generated backend config is invalid."
}

if [[ -f "$CORE" ]]; then
  HAD_CORE=1
  cp -f "$CORE" "$BACKUP_CORE"
fi

if [[ -f "$RUNTIME_CONFIG" ]]; then
  HAD_CONFIG=1
  cp -f "$RUNTIME_CONFIG" "$BACKUP_CONFIG"
fi

if [[ -f "$AUTOSTART_FILE" ]]; then
  HAD_AUTOSTART=1
  cp -f "$AUTOSTART_FILE" "$BACKUP_AUTOSTART"
fi

if core_running; then
  OLD_RUNNING=1
fi

SWAP_STARTED=1
stop_core
cp -f "$STAGED_CORE" "$CORE"
chmod 700 "$CORE"
cp -f "$STAGED_CONFIG" "$RUNTIME_CONFIG"
chmod 600 "$RUNTIME_CONFIG"

nohup "$CORE" -d "$INSTALL_DIR" -f "$RUNTIME_CONFIG" > "$LOG_FILE" 2>&1 &
PID="$!"
printf '%s\n' "$PID" > "$PID_FILE"

READY=0

for _ in {1..40}; do
  if controller_get "http://127.0.0.1:9090/version" 2 >/dev/null 2>&1; then
    READY=1
    break
  fi

  sleep 0.25
done

if (( READY == 0 )); then
  tail -n 12 "$LOG_FILE" >&2 || true
  die "Backend did not start."
fi

DELAY_JSON=""

for TEST_URL in   "https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"   "https%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204"
do
  if DELAY_JSON="$(controller_get "http://127.0.0.1:9090/proxies/AMNEZIA/delay?url=${TEST_URL}&timeout=12000" 15 2>/dev/null)"; then
    break
  fi
done

DELAY=""

if [[ -n "$DELAY_JSON" ]]; then
  DELAY="$(printf '%s' "$DELAY_JSON" | sed -n 's/.*"delay"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
fi

if [[ -z "$DELAY" ]]; then
  printf 'Warning: Amnezia Premium RTT test is unavailable. Backend will remain installed.\n' >&2
fi

DIRECT_DELAY=""

if DIRECT_JSON="$(controller_get "http://127.0.0.1:9090/proxies/DIRECT/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=12000" 15 2>/dev/null)"; then
  DIRECT_DELAY="$(printf '%s' "$DIRECT_JSON" | sed -n 's/.*"delay"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"

  if [[ -z "$DIRECT_DELAY" ]]; then
    printf 'Warning: Direct RTT baseline returned an invalid result.\n' >&2
  fi
else
  printf 'Warning: Direct RTT baseline is unavailable.\n' >&2
fi

cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Amnezia Browser Backend
Exec="$CORE" -d "$INSTALL_DIR" -f "$RUNTIME_CONFIG"
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

chmod 600 "$AUTOSTART_FILE"
INSTALL_OK=1

printf '\n'
printf 'Amnezia Browser backend: OK\n'

if [[ -n "$DELAY" ]]; then
  printf 'Amnezia Premium RTT test: %s ms\n' "$DELAY"
else
  printf 'Amnezia Premium RTT test: unavailable\n'
fi

if [[ -n "$DIRECT_DELAY" ]]; then
  printf 'Direct RTT baseline: %s ms\n' "$DIRECT_DELAY"
fi

if [[ -n "$DELAY" && -n "$DIRECT_DELAY" ]]; then
  printf 'VPN RTT delta: %s ms\n' "$((DELAY - DIRECT_DELAY))"
fi

printf 'System VPN: OFF\n'
printf 'System routes: unchanged\n'
printf 'Extension folder: %s\n' "$(cd "$(dirname "$0")" && pwd)/extension"
