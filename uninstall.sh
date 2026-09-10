#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="$HOME/.local/lib/amnezia-browser"
CONFIG_DIR="$HOME/.config/amnezia-browser"
CORE="$(readlink -m "$INSTALL_DIR/mihomo")"
AUTOSTART="$HOME/.config/autostart/amnezia-browser.desktop"
read -r SELF_PID SELF_STAT_REST < /proc/self/stat
[[ "$SELF_PID" == "$$" ]] || { printf 'Unsupported PID namespace: /proc does not match this process\n' >&2; exit 1; }

owned() {
  local exe
  exe="$(readlink "/proc/$1/exe" 2>/dev/null || true)"
  [[ "${exe% (deleted)}" == "$CORE" ]]
}
stop_legacy() {
  local proc pid
  local -a pids=()
  for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    if owned "$pid"; then pids+=("$pid"); fi
  done
  for pid in "${pids[@]}"; do
    if owned "$pid"; then kill "$pid" || { owned "$pid" && return 1; }; fi
  done
  for _ in {1..50}; do
    local alive=0
    for pid in "${pids[@]}"; do if owned "$pid"; then alive=1; fi; done
    (( alive == 0 )) && break
    sleep 0.1
  done
  for pid in "${pids[@]}"; do
    if owned "$pid"; then kill -9 "$pid"; fi
  done
  for _ in {1..20}; do
    local alive=0
    for pid in "${pids[@]}"; do if owned "$pid"; then alive=1; fi; done
    (( alive == 0 )) && return 0
    sleep 0.1
  done
  printf 'Backend did not stop; files have not been removed\n' >&2
  return 1
}

printf 'This removes the backend, connection key, configuration and logs. Disable browser routing and remove the extension separately.\n'
if [[ -d "$INSTALL_DIR" ]]; then
  exec 7>"$INSTALL_DIR/install.lock"
  flock -n 7 || { printf 'Another installation or removal is running\n' >&2; exit 1; }
  if [[ -x "$INSTALL_DIR/backend.sh" ]]; then "$INSTALL_DIR/backend.sh" stop 7>&-; else stop_legacy; fi
fi
rm -f "$AUTOSTART"
rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
[[ ! -e "$INSTALL_DIR" && ! -e "$CONFIG_DIR" ]] || { printf 'Some backend files remain\n' >&2; exit 1; }
printf 'Amnezia Browser backend removed.\n'
