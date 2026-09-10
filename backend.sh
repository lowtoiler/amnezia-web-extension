#!/usr/bin/env bash
set -euo pipefail
umask 077
INSTALL_DIR="${AMNEZIA_BROWSER_INSTALL_DIR:-$HOME/.local/lib/amnezia-browser}"
CONFIG_DIR="${AMNEZIA_BROWSER_CONFIG_DIR:-$HOME/.config/amnezia-browser}"
[[ -d "$INSTALL_DIR" ]] || { printf 'Backend is not installed\n' >&2; exit 1; }
INSTALL_DIR="$(readlink -f "$INSTALL_DIR")"
CONFIG_DIR="$(readlink -m "$CONFIG_DIR")"
read -r SELF_PID SELF_STAT_REST < /proc/self/stat
[[ "$SELF_PID" == "$$" ]] || { printf 'Unsupported PID namespace: /proc does not match this process\n' >&2; exit 1; }
CORE="$INSTALL_DIR/mihomo"
CONFIG="$CONFIG_DIR/config.yaml"
MANAGER="$INSTALL_DIR/backend.sh"
PID_FILE="$INSTALL_DIR/supervisor.pid"
LOG="$INSTALL_DIR/mihomo.log"
ACTION="${1:-status}"
LOG_WRITER="$INSTALL_DIR/log.sh"
BACKEND_CHILD=""
LOG_PID=""
RUN_DIR=""


core_pids() {
  local proc exe
  for proc in /proc/[0-9]*; do
    [[ -L "$proc/exe" ]] || continue
    exe="$(readlink "$proc/exe" 2>/dev/null || true)"
    [[ "${exe% (deleted)}" == "$CORE" ]] && printf '%s\n' "${proc##*/}"
  done
  return 0
}
process_started() {
  local data
  local -a fields=()
  IFS= read -r data < "/proc/$1/stat" || return 1
  data="${data##*) }"
  read -ra fields <<< "$data"
  [[ "${fields[0]}" != Z ]] || return 1
  printf '%s\n' "${fields[19]}"
}
supervisor_pid() {
  local pid started actual
  [[ -f "$PID_FILE" ]] || return 1
  read -r pid started < "$PID_FILE" || return 1
  [[ "$pid" =~ ^[0-9]+$ && "$started" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1
  actual="$(process_started "$pid" 2>/dev/null)" || return 1
  [[ "$actual" == "$started" ]] || return 1
  local argument resolved
  while IFS= read -r -d '' argument; do
    [[ "$argument" == *.sh && -f "$argument" ]] || continue
    resolved="$(readlink -f -- "$argument")" || continue
    if [[ "$resolved" == "$MANAGER" ]]; then printf '%s\n' "$pid"; return 0; fi
  done < "/proc/$pid/cmdline"
  return 1
}
supervisor_event() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | bash "$LOG_WRITER" "$INSTALL_DIR/supervisor.log"
}
shutdown() {
  trap - TERM INT EXIT
  if [[ -n "$BACKEND_CHILD" ]] && kill -0 "$BACKEND_CHILD" 2>/dev/null; then
    kill "$BACKEND_CHILD"
    for _ in {1..30}; do kill -0 "$BACKEND_CHILD" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$BACKEND_CHILD" 2>/dev/null; then kill -9 "$BACKEND_CHILD"; fi
    local result=0
    wait "$BACKEND_CHILD" || result=$?
    if (( result != 0 && result != 143 && result != 137 )); then printf 'Backend stop status: %s\n' "$result" >&2; fi
  fi
  if [[ -n "$LOG_PID" ]]; then
    for _ in {1..30}; do kill -0 "$LOG_PID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$LOG_PID" 2>/dev/null; then kill "$LOG_PID"; fi
    wait "$LOG_PID" || printf 'Log writer did not finish successfully\n' >&2
  fi
  [[ -z "$RUN_DIR" ]] || rm -rf -- "$RUN_DIR"
  rm -f "$PID_FILE"
}
stop_backend() {
  local pid
  if pid="$(supervisor_pid)"; then
    kill "$pid"
    for _ in {1..50}; do supervisor_pid >/dev/null || break; sleep 0.1; done
    if supervisor_pid >/dev/null; then kill -9 "$pid"; fi
  fi
  local -a pids=()
  mapfile -t pids < <(core_pids)
  for pid in "${pids[@]}"; do kill "$pid"; done
  for _ in {1..50}; do [[ -z "$(core_pids)" ]] && break; sleep 0.1; done
  mapfile -t pids < <(core_pids)
  for pid in "${pids[@]}"; do kill -9 "$pid"; done
  [[ -z "$(core_pids)" ]] || { printf 'Failed to stop backend\n' >&2; return 1; }
  rm -f "$PID_FILE"
}
run_backend() {
  [[ -x "$CORE" && -f "$CONFIG" && -f "$LOG_WRITER" ]] || { printf 'Backend installation is incomplete\n' >&2; return 1; }
  exec 9>"$INSTALL_DIR/supervisor.lock"
  flock -n 9 || return 0
  printf '%s %s\n' "$$" "$(process_started "$$")" > "$PID_FILE.new"
  mv -f "$PID_FILE.new" "$PID_FILE"
  trap 'shutdown; exit 0' TERM INT
  trap shutdown EXIT
  local attempt=0 started result
  if [[ -n "$(core_pids)" ]]; then supervisor_event 'An unmanaged backend is running; use restart'; return 1; fi
  RUN_DIR="$(mktemp -d "$INSTALL_DIR/runtime.XXXXXX")"
  mkfifo "$RUN_DIR/output"
  while (( attempt < 5 )); do
    started=$SECONDS
    bash "$LOG_WRITER" "$LOG" < "$RUN_DIR/output" 9>&- &
    LOG_PID=$!
    "$CORE" -d "$INSTALL_DIR" -f "$CONFIG" > "$RUN_DIR/output" 2>&1 9>&- &
    BACKEND_CHILD=$!
    while kill -0 "$BACKEND_CHILD" 2>/dev/null && kill -0 "$LOG_PID" 2>/dev/null; do sleep 0.1; done
    if kill -0 "$BACKEND_CHILD" 2>/dev/null; then supervisor_event 'Log writer failed while backend was running'; return 1; fi
    result=0
    wait "$BACKEND_CHILD" || result=$?
    BACKEND_CHILD=""
    wait "$LOG_PID" || { supervisor_event 'Log writer failed'; return 1; }
    LOG_PID=""
    supervisor_event "Backend exited with status $result"
    if (( SECONDS - started >= 60 )); then attempt=0; fi
    attempt=$((attempt + 1))
    (( attempt < 5 )) || break
    sleep "$((attempt * 2))"
  done
  supervisor_event 'Backend stopped after repeated failures. Check mihomo.log'
  return 1
}
start_backend() {
  if supervisor_pid >/dev/null; then printf 'Supervisor is already running\n'; return 0; fi
  [[ -z "$(core_pids)" ]] || { printf 'An unmanaged backend is running; use restart\n' >&2; return 1; }
  nohup "$MANAGER" run > "$INSTALL_DIR/supervisor-start.log" 2>&1 < /dev/null 8>&- &
  for _ in {1..50}; do
    if supervisor_pid >/dev/null && [[ -n "$(core_pids)" ]]; then printf 'Backend process started\n'; return 0; fi
    sleep 0.1
  done
  printf 'Backend process did not start. Check supervisor.log and mihomo.log\n' >&2
  return 1
}
check_backend() {
  local target code
  [[ -n "$(core_pids)" ]] || { printf 'Backend process is not running\n' >&2; return 1; }
  for target in https://cp.cloudflare.com/generate_204 https://www.gstatic.com/generate_204; do
    if code="$(curl -sS --proxy socks5h://127.0.0.1:1080 --noproxy localhost,127.0.0.1 --connect-timeout 5 --max-time 12 -o /dev/null -w '%{http_code}' "$target")"; then
      if [[ "$code" == 200 || "$code" == 204 ]]; then printf 'SOCKS HTTP data path: OK (%s)\n' "$target"; return 0; fi
    fi
  done
  printf 'SOCKS HTTP data path could not be confirmed\n' >&2
  return 1
}
[[ -d "$INSTALL_DIR" ]] || { printf 'Backend is not installed\n' >&2; exit 1; }
case "$ACTION" in
  run) run_backend ;;
  start|stop|restart)
    exec 8>"$INSTALL_DIR/operations.lock"
    flock -w 15 8 || { printf 'Another backend operation is running\n' >&2; exit 1; }
    case "$ACTION" in start) start_backend ;; stop) stop_backend ;; restart) stop_backend; start_backend ;; esac
    ;;
  status)
    printf 'Supervisor: '; supervisor_pid || printf 'not running\n'
    printf 'Core PIDs: %s\n' "$(core_pids)"
    [[ -n "$(core_pids)" ]]
    ;;
  check) check_backend ;;
  *) printf 'Usage: backend.sh {start|stop|restart|status|check|run}\n' >&2; exit 2 ;;
esac
