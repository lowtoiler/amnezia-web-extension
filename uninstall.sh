#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/lib/amnezia-browser"
CONFIG_DIR="$HOME/.config/amnezia-browser"
PID_FILE="$INSTALL_DIR/mihomo.pid"
CORE="$INSTALL_DIR/mihomo"
AUTOSTART="$HOME/.config/autostart/amnezia-browser.desktop"

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

rm -f "$AUTOSTART"
stop_core
rm -rf "$INSTALL_DIR" "$CONFIG_DIR"

printf 'Amnezia Browser backend removed.\n'
