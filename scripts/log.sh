#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $# -ge 1 && $# -le 2 ]] || { printf 'Usage: log.sh FILE [MAX_BYTES]\n' >&2; exit 2; }
AMNEZIA_BROWSER_LOG_FILE="$1"
MAX_BYTES="${2:-2097152}"
[[ "$MAX_BYTES" =~ ^[1-9][0-9]{0,8}$ ]] || { printf 'Invalid log size limit\n' >&2; exit 2; }
export AMNEZIA_BROWSER_LOG_FILE
exec 6>"$AMNEZIA_BROWSER_LOG_FILE.lock"
flock -n 6 || { printf 'Another writer owns this log\n' >&2; exit 1; }
TRIMMED=""
trap 'if [[ -n "$TRIMMED" ]]; then rm -f -- "$TRIMMED"; fi' EXIT
for file in "$AMNEZIA_BROWSER_LOG_FILE" "$AMNEZIA_BROWSER_LOG_FILE.previous"; do
  [[ ! -e "$file" || -f "$file" ]] || { printf 'Log path must be a regular file\n' >&2; exit 1; }
  [[ ! -L "$file" ]] || { printf 'Log path must not be a symlink\n' >&2; exit 1; }
  if [[ -f "$file" && "$(stat -c %s -- "$file")" -gt "$MAX_BYTES" ]]; then
    TRIMMED="$(mktemp "$file.trim.XXXXXX")"
    tail -c "$MAX_BYTES" -- "$file" > "$TRIMMED"
    mv -f -- "$TRIMMED" "$file"
    TRIMMED=""
  fi
done
touch -- "$AMNEZIA_BROWSER_LOG_FILE"
chmod 600 "$AMNEZIA_BROWSER_LOG_FILE"
AVAILABLE=$((MAX_BYTES - $(stat -c %s -- "$AMNEZIA_BROWSER_LOG_FILE")))
if (( AVAILABLE > 0 )); then stdbuf -o0 head -c "$AVAILABLE" >> "$AMNEZIA_BROWSER_LOG_FILE"; fi
exec split -b "$MAX_BYTES" -d -a 20 --filter='set -e; mv -f -- "$AMNEZIA_BROWSER_LOG_FILE" "$AMNEZIA_BROWSER_LOG_FILE.previous"; exec cat > "$AMNEZIA_BROWSER_LOG_FILE"'
