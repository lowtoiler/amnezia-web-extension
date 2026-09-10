#!/usr/bin/env bash
set -euo pipefail
umask 077

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
      line = $0
      sub(/^\357\273\277/, "", line)
      sub(/#.*/, "", line)
      line = trim(line)

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
        value = trim(substr(line, pos + 1))
        if (want_key == "Address" || want_key == "DNS" || want_key == "AllowedIPs") {
          result = result == "" ? value : result ", " value
        } else {
          print value
          exit
        }
      }
    }
    END { if (result != "") print result }
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
  local -a parts=()
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

  if [[ "$kind" == "number" ]]; then
    [[ "$value" =~ ^[0-9]+$ ]] || die "Invalid numeric field: $ini_key"
    value="$(printf '%s' "$value" | sed 's/^0*//')"
    value="${value:-0}"
    [[ ${#value} -lt 20 || ( ${#value} -eq 20 && ( "$value" < 18446744073709551615 || "$value" == 18446744073709551615 ) ) ]] || die "Numeric field exceeds UInt64: $ini_key"
    printf '      %s: %s\n' "$yaml_key" "$value"
    return
  fi

  printf '      %s: ' "$yaml_key"
  yaml_quote "$value"
  printf '\n'
}

validate_ini() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function fail(text) { print text > "/dev/stderr"; bad=1; exit 1 }
    {
      line=$0; sub(/^\357\273\277/, "", line); sub(/#.*/, "", line); line=trim(line)
      if (line == "" || substr(line,1,1) == ";") next
      if (line ~ /^\[.*\]$/) {
        section=tolower(trim(substr(line,2,length(line)-2)))
        if (section != "interface" && section != "peer") fail("Unsupported INI section")
        count[section]++
        next
      }
      pos=index(line,"=")
      if (section == "" || pos < 2) fail("Invalid INI assignment")
      key=tolower(trim(substr(line,1,pos-1)))
      if (++seen[section SUBSEP key] > 1 && key != "address" && key != "dns" && key != "allowedips") fail("Duplicate INI key: " key)
      if (section == "interface" && key !~ /^(privatekey|address|dns|mtu|jc|jmin|jmax|s1|s2|s3|s4|h1|h2|h3|h4|i1|i2|i3|i4|i5|j1|j2|j3|itime|headerprotectionkey|contentpaddingaddition|rekeyaftertime|rekeytimeout|rejectaftertime|keepalivetimeout|maxhandshakeattempts|randomtrailers|disablecookies)$/) fail("Unsupported Interface field: " key)
      if (section == "peer" && key !~ /^(publickey|presharedkey|endpoint|allowedips|persistentkeepalive)$/) fail("Unsupported Peer field: " key)
    }
    END { if (!bad && (count["interface"] != 1 || count["peer"] != 1)) { print "Config must contain exactly one Interface and Peer" > "/dev/stderr"; exit 1 } }
  ' "$1"
}

[[ $# == 3 ]] || die "Usage: config.sh INPUT OUTPUT SECRET_FILE"
CONF="$1"
STAGED_CONFIG="$2"
IFS= read -r CONTROLLER_SECRET < "$3" || [[ -n "$CONTROLLER_SECRET" ]]
[[ "$CONTROLLER_SECRET" =~ ^[a-f0-9]{64}$ ]] || die "Invalid controller secret"
validate_ini "$CONF"
PRIVATE_KEY="$(ini_get Interface PrivateKey "$CONF")"
PUBLIC_KEY="$(ini_get Peer PublicKey "$CONF")"
PSK="$(ini_get Peer PresharedKey "$CONF")"
ENDPOINT="$(ini_get Peer Endpoint "$CONF")"
ADDRESS="$(ini_get Interface Address "$CONF")"
DNS="$(ini_get Interface DNS "$CONF")"
ALLOWED="$(ini_get Peer AllowedIPs "$CONF")"
PERSISTENT_KEEPALIVE="$(ini_get Peer PersistentKeepalive "$CONF")"
MTU="$(ini_get Interface MTU "$CONF")"

if [[ "${PERSISTENT_KEEPALIVE,,}" == off ]]; then PERSISTENT_KEEPALIVE=0; fi
if [[ -n "$PERSISTENT_KEEPALIVE" ]]; then
  [[ "$PERSISTENT_KEEPALIVE" =~ ^[0-9]{1,5}$ ]] && (( 10#$PERSISTENT_KEEPALIVE <= 65535 )) || die "PersistentKeepalive must be off or 0..65535"
  PERSISTENT_KEEPALIVE=$((10#$PERSISTENT_KEEPALIVE))
fi

[[ -n "$PRIVATE_KEY" ]] || die "Missing Interface.PrivateKey"
[[ -n "$PUBLIC_KEY" ]] || die "Missing Peer.PublicKey"
[[ -n "$ENDPOINT" ]] || die "Missing Peer.Endpoint"
[[ -n "$ADDRESS" ]] || die "Missing Interface.Address"

if [[ "$ENDPOINT" =~ ^\[([0-9a-fA-F:.]+)\]:([0-9]+)$ ]]; then
  SERVER="${BASH_REMATCH[1]}"
  PORT="${BASH_REMATCH[2]}"
elif [[ "$ENDPOINT" =~ ^([A-Za-z0-9][A-Za-z0-9.-]*):([0-9]+)$ ]]; then
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
    [[ -z "$IPV6" || "$IPV6" == "$addr" ]] || die "Multiple distinct IPv6 addresses are not supported by this backend"
    IPV6="$addr"
  else
    [[ -z "$IPV4" || "$IPV4" == "$addr" ]] || die "Multiple distinct IPv4 addresses are not supported by this backend"
    IPV4="$addr"
  fi
done

[[ -n "$IPV4" ]] || die "Amnezia config does not contain an IPv4 Address."

[[ -n "$DNS" ]] || DNS="1.1.1.1"
[[ -n "$ALLOWED" ]] || ALLOWED="0.0.0.0/0"
[[ -n "$MTU" ]] || MTU="1420"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) || die "Endpoint port must be 1..65535"
PORT=$((10#$PORT))
[[ "$MTU" =~ ^[0-9]{1,5}$ ]] && (( 10#$MTU >= 576 && 10#$MTU <= 65535 )) || die "MTU must be 576..65535"
MTU=$((10#$MTU))
[[ -z "$IPV6" ]] || (( MTU >= 1280 )) || die "IPv6 requires MTU >= 1280"
for key in "$PRIVATE_KEY" "$PUBLIC_KEY" ${PSK:+"$PSK"}; do
  [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "WireGuard key must encode exactly 32 bytes"
  [[ "$(printf '%s' "$key" | base64 -d | wc -c)" -eq 32 ]] || die "Invalid WireGuard key"
done

REMOTE_DNS_RESOLVE="true"
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
