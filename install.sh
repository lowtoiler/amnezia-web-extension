#!/usr/bin/env bash
set -euo pipefail
umask 077
CORE_VERSION="v1.19.30"
INSTALL_DIR="$HOME/.local/lib/amnezia-browser"
CONFIG_DIR="$HOME/.config/amnezia-browser"
AUTOSTART_FILE="$HOME/.config/autostart/amnezia-browser.desktop"
CORE="$INSTALL_DIR/mihomo"
MANAGER="$INSTALL_DIR/backend.sh"
RUNTIME_CONFIG="$CONFIG_DIR/config.yaml"
CONNECTION="$CONFIG_DIR/connection.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

die() { printf '%s\n' "$*" >&2; exit 1; }
for tool in curl awk gzip sha256sum base64 readlink flock ss od timeout split head tail stat stdbuf; do command -v "$tool" >/dev/null || die "Required command is missing: $tool"; done
read -r SELF_PID SELF_STAT_REST < /proc/self/stat
[[ "$SELF_PID" == "$$" ]] || die "Unsupported PID namespace: /proc does not match this process"
CONF="${1:-}"
if [[ -z "$CONF" ]]; then
  if command -v zenity >/dev/null && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    CONF="$(zenity --file-selection --title='Select Amnezia Premium config' --file-filter='*.conf')" || die "Config was not selected"
  else
    read -r -p 'Amnezia Premium .conf path: ' CONF
  fi
fi
CONF="$(readlink -f "$CONF")"
[[ -f "$CONF" ]] || die "Config not found"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$(dirname "$AUTOSTART_FILE")"
chmod 700 "$INSTALL_DIR" "$CONFIG_DIR"
CORE="$(readlink -m "$CORE")"
MANAGER="$(readlink -m "$MANAGER")"
LOG_WRITER="$INSTALL_DIR/log.sh"
exec 7>"$INSTALL_DIR/install.lock"
flock -n 7 || die "Another installation or removal is running"
TMP_DIR="$(mktemp -d)"
SWAPPED=0
INSTALL_OK=0
OLD_RUNNING=0
declare -a DESTINATIONS=("$CORE" "$RUNTIME_CONFIG" "$CONNECTION" "$MANAGER" "$AUTOSTART_FILE" "$LOG_WRITER")
declare -a HAD=()

legacy_stop() {
  local proc exe pid
  local -a pids=()
  for proc in /proc/[0-9]*; do
    exe="$(readlink "$proc/exe" 2>/dev/null || true)"
    if [[ "${exe% (deleted)}" == "$CORE" ]]; then pids+=("${proc##*/}"); fi
  done
  for pid in "${pids[@]}"; do kill "$pid"; done
  for _ in {1..50}; do
    local alive=0
    for pid in "${pids[@]}"; do
      exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
      if [[ "${exe% (deleted)}" == "$CORE" ]]; then alive=1; fi
    done
    (( alive == 0 )) && return 0
    sleep 0.1
  done
  printf 'Old backend did not stop\n' >&2
  return 1
}
cleanup() {
  local result=$?
  trap - EXIT
  if (( result != 0 && SWAPPED == 1 && INSTALL_OK == 0 )); then
    local recovery=0
    if [[ -x "$MANAGER" ]]; then "$MANAGER" stop 7>&- || recovery=1; else legacy_stop || recovery=1; fi
    if (( recovery != 0 )); then printf 'Rollback stopped because backend could not be stopped; protected backup remains at %s\n' "$TMP_DIR" >&2; return "$result"; fi
    for index in "${!DESTINATIONS[@]}"; do
      if [[ "${HAD[index]}" == 1 ]]; then cp -p "$TMP_DIR/backup.$index" "${DESTINATIONS[index]}" || recovery=1
      else rm -f "${DESTINATIONS[index]}" || recovery=1; fi
    done
    if (( recovery != 0 )); then printf 'Rollback could not restore all files; backend was not restarted. Protected backup remains at %s\n' "$TMP_DIR" >&2; return "$result"; fi
    if (( OLD_RUNNING == 1 )); then
      if [[ -x "$MANAGER" ]]; then "$MANAGER" start 7>&- || recovery=1
      else nohup "$CORE" -d "$INSTALL_DIR" -f "$RUNTIME_CONFIG" >> "$INSTALL_DIR/mihomo.log" 2>&1 < /dev/null 7>&- & fi
    fi
    if (( recovery != 0 )); then printf 'Rollback needs attention; protected backup remains at %s\n' "$TMP_DIR" >&2; return "$result"; fi
  fi
  for destination in "${DESTINATIONS[@]}"; do rm -f "$destination.new"; done
  rm -rf "$TMP_DIR"
  return "$result"
}
trap cleanup EXIT
CONTROLLER_SECRET=""
if [[ -f "$CONNECTION" ]]; then
  CONTROLLER_SECRET="$(sed -n 's/.*"secret"[[:space:]]*:[[:space:]]*"\([a-f0-9]\{64\}\)".*/\1/p' "$CONNECTION")"
fi
if [[ ! "$CONTROLLER_SECRET" =~ ^[a-f0-9]{64}$ ]]; then CONTROLLER_SECRET="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"; fi
printf '%s\n' "$CONTROLLER_SECRET" > "$TMP_DIR/secret"
bash "$SCRIPT_DIR/scripts/config.sh" "$CONF" "$TMP_DIR/config.yaml" "$TMP_DIR/secret"
printf '{"schemaVersion":1,"controllerUrl":"http://127.0.0.1:9090","proxyHost":"127.0.0.1","proxyPort":1080,"secret":"%s"}\n' "$CONTROLLER_SECRET" > "$TMP_DIR/connection.json"
printf 'Authorization: Bearer %s\n' "$CONTROLLER_SECRET" > "$TMP_DIR/headers"

case "$(uname -m)" in
  x86_64|amd64) ASSET="mihomo-linux-amd64-compatible-v1.19.30.gz"; EXPECTED_SHA="db214c7a2517e63c150d123178d16d102e03a241ccdae4e5e07ffbe9cf56c6f9" ;;
  aarch64|arm64) ASSET="mihomo-linux-arm64-v1.19.30.gz"; EXPECTED_SHA="58896873736d28628f66de3677c8654fa0f180662523148e136cff4f6e890069" ;;
  *) die "Unsupported Linux architecture" ;;
esac
printf 'Downloading verified backend %s...\n' "$CORE_VERSION"
curl -fL --proto '=https' --proto-redir '=https' --retry 3 --retry-max-time 180 --connect-timeout 15 --max-time 120 "https://github.com/MetaCubeX/mihomo/releases/download/$CORE_VERSION/$ASSET" -o "$TMP_DIR/core.gz"
[[ "$(sha256sum "$TMP_DIR/core.gz" | awk '{print $1}')" == "$EXPECTED_SHA" ]] || die "Backend checksum mismatch"
gzip -dc "$TMP_DIR/core.gz" > "$TMP_DIR/mihomo"
chmod 700 "$TMP_DIR/mihomo"
if ! timeout 30 "$TMP_DIR/mihomo" -t -d "$TMP_DIR" -f "$TMP_DIR/config.yaml" 2>&1 | bash "$SCRIPT_DIR/scripts/log.sh" "$TMP_DIR/validation.log"; then
  cp "$TMP_DIR/validation.log" "$CONFIG_DIR/validation-failed.log"
  chmod 600 "$CONFIG_DIR/validation-failed.log"
  die "Generated config failed mihomo validation. Details: $CONFIG_DIR/validation-failed.log (may contain private configuration; do not share the raw log)"
fi

for index in "${!DESTINATIONS[@]}"; do
  if [[ -f "${DESTINATIONS[index]}" ]]; then HAD[index]=1; cp -p "${DESTINATIONS[index]}" "$TMP_DIR/backup.$index"; else HAD[index]=0; fi
done
for proc in /proc/[0-9]*; do
  exe="$(readlink "$proc/exe" 2>/dev/null || true)"
  if [[ "${exe% (deleted)}" == "$CORE" ]]; then OLD_RUNNING=1; fi
done
SWAPPED=1
if [[ -x "$MANAGER" ]]; then "$MANAGER" stop 7>&-; else legacy_stop; fi
if [[ -n "$(ss -H -ltn '( sport = :1080 or sport = :9090 )')" ]]; then die "Ports 1080 or 9090 are occupied by another application"; fi
for pair in "mihomo:$CORE" "config.yaml:$RUNTIME_CONFIG" "connection.json:$CONNECTION"; do
  from="${pair%%:*}"; to="${pair#*:}"
  cp "$TMP_DIR/$from" "$to.new"
  chmod 600 "$to.new"
  mv -f "$to.new" "$to"
done
chmod 700 "$CORE"
cp "$SCRIPT_DIR/backend.sh" "$MANAGER.new"
chmod 700 "$MANAGER.new"
mv -f "$MANAGER.new" "$MANAGER"
cp "$SCRIPT_DIR/scripts/log.sh" "$LOG_WRITER.new"
chmod 700 "$LOG_WRITER.new"
mv -f "$LOG_WRITER.new" "$LOG_WRITER"
"$MANAGER" start 7>&-
READY=0
for _ in {1..20}; do
  if curl -fsS --noproxy '*' --max-time 2 --max-filesize 262144 --header @"$TMP_DIR/headers" http://127.0.0.1:9090/version > "$TMP_DIR/version.json" 2>/dev/null; then
    if grep -Eq '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$TMP_DIR/version.json"; then READY=1; break; fi
  fi
  sleep 0.25
done
(( READY == 1 )) || die "Controller did not become ready; restoring the previous installation"
case "$MANAGER" in *'%'*|*'"'*|*'\'*|*'$'*|*'`'*|*$'\n'*|*$'\r'*) die "Autostart path contains unsupported desktop-entry characters" ;; esac
cat > "$AUTOSTART_FILE.new" <<EOF
[Desktop Entry]
Type=Application
Name=Amnezia Browser Backend
Exec="$MANAGER" run
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
chmod 600 "$AUTOSTART_FILE.new"
mv -f "$AUTOSTART_FILE.new" "$AUTOSTART_FILE"
INSTALL_OK=1
printf 'Backend installed; controller authentication confirmed.\n'
if ! "$MANAGER" check 7>&-; then printf 'Warning: installation completed, but network connectivity is unconfirmed. Run backend.sh check after resolving the network error.\n' >&2; fi
printf 'Import this connection file in extension settings: %s\n' "$CONNECTION"
printf 'Extension folder: %s/extension\n' "$SCRIPT_DIR"
printf 'System routes were not changed. Browser routing is configured separately.\n'
