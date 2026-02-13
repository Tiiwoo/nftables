#!/usr/bin/env bash

set -o pipefail

NFT_CONF="${NFT_CONF:-/etc/nftables.conf}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-nft-po0-forward.conf}"
MANAGED_BEGIN="# === nft-po0.sh managed records begin ==="
MANAGED_END="# === nft-po0.sh managed records end ==="
DEFAULT_MSS="${DEFAULT_MSS:-1452}"
NAT_TABLE="nft_po0_nat"
FILTER_TABLE="nft_po0_filter"

NFTMGR_TEST_MODE="${NFTMGR_TEST_MODE:-0}"
NFTMGR_SKIP_ROOT_CHECK="${NFTMGR_SKIP_ROOT_CHECK:-0}"
NFTMGR_SKIP_PORT_CHECK="${NFTMGR_SKIP_PORT_CHECK:-0}"

declare -a RECORDS=()
RELAY_LAN_IP=""
TCP_MSS="$DEFAULT_MSS"

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_enabled() {
  local value="${1:-0}"
  value="$(to_lower "$value")"
  [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
}

require_root() {
  if is_enabled "$NFTMGR_TEST_MODE" || is_enabled "$NFTMGR_SKIP_ROOT_CHECK"; then
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must run as root. Use: sudo $0"
    exit 1
  fi
}

confirm() {
  local prompt="$1"
  local answer
  local answer_lower
  read -r -p "$prompt" answer
  answer_lower="$(to_lower "$answer")"
  case "$answer_lower" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  ((p >= 1 && p <= 65535))
}

valid_ipv4() {
  local ip="$1"
  local -a octets
  local o

  IFS='.' read -r -a octets <<< "$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1

  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    ((o >= 0 && o <= 255)) || return 1
  done
}

valid_mss() {
  local mss="$1"
  [[ "$mss" =~ ^[0-9]+$ ]] || return 1
  ((mss == 0 || (mss >= 536 && mss <= 9000)))
}

parse_rule_line() {
  local line="$1"
  local hash tag proto local_port remote_ip remote_port extra

  read -r hash tag proto local_port remote_ip remote_port extra <<< "$line"
  [[ "${hash:-}" == "#" && "${tag:-}" == "RULE" ]] || return 1
  [[ -z "${extra:-}" ]] || return 1
  [[ "$proto" == "tcp" || "$proto" == "udp" ]] || return 1
  valid_port "$local_port" || return 1
  valid_ipv4 "$remote_ip" || return 1
  valid_port "$remote_port" || return 1

  echo "$proto $local_port $remote_ip $remote_port"
}

ensure_nftables_installed() {
  if is_enabled "$NFTMGR_TEST_MODE"; then
    return 0
  fi

  if command -v nft >/dev/null 2>&1; then
    return 0
  fi

  echo "nft command not found."
  if ! confirm "Install nftables with apt-get now? [y/N]: "; then
    echo "Skipped installation."
    return 1
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get not found. Please install nftables manually."
    return 1
  fi

  apt-get update
  apt-get install -y nftables
}

ensure_ss_available() {
  if is_enabled "$NFTMGR_TEST_MODE" || is_enabled "$NFTMGR_SKIP_PORT_CHECK"; then
    return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    return 0
  fi
  echo "ss command not found. Please install iproute2 first."
  return 1
}

ensure_ipv4_forwarding() {
  local current

  if is_enabled "$NFTMGR_TEST_MODE"; then
    return 0
  fi

  current="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
  if [[ "$current" == "1" ]]; then
    return 0
  fi

  echo "IPv4 forwarding is disabled."
  if confirm "Enable IPv4 forwarding now and persist it? [y/N]: "; then
    if sysctl -w net.ipv4.ip_forward=1 >/dev/null; then
      echo "net.ipv4.ip_forward=1" > "$SYSCTL_FILE"
      echo "IPv4 forwarding enabled and persisted in $SYSCTL_FILE"
      return 0
    fi
    echo "Failed to enable IPv4 forwarding."
    return 1
  fi

  echo "Forwarding not enabled. Port forwarding may not work."
  return 1
}

table_exists() {
  local table="$1"
  nft list table ip "$table" >/dev/null 2>&1
}

delete_table_if_exists() {
  local table="$1"
  if table_exists "$table"; then
    nft delete table ip "$table"
  fi
}

syntax_check_rules_file() {
  local input_file="$1"
  local check_file check_nat check_filter

  check_file="$(mktemp)"
  check_nat="${NAT_TABLE}_check_${RANDOM}_$$"
  check_filter="${FILTER_TABLE}_check_${RANDOM}_$$"

  sed \
    -e "s/table ip ${NAT_TABLE}/table ip ${check_nat}/g" \
    -e "s/table ip ${FILTER_TABLE}/table ip ${check_filter}/g" \
    "$input_file" > "$check_file"

  if ! nft -c -f "$check_file"; then
    rm -f "$check_file"
    return 1
  fi

  rm -f "$check_file"
  return 0
}

load_records() {
  local line parsed
  RECORDS=()
  [[ -f "$NFT_CONF" ]] || return 0

  while IFS= read -r line; do
    parsed="$(parse_rule_line "$line" || true)"
    [[ -n "$parsed" ]] && RECORDS+=("$parsed")
  done < "$NFT_CONF"
}

load_relay_lan_ip() {
  local line
  local matched_ip
  RELAY_LAN_IP=""
  [[ -f "$NFT_CONF" ]] || return 0

  while IFS= read -r line; do
    if [[ "$line" =~ ^define[[:space:]]+RELAY_LAN_IP[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      matched_ip="${BASH_REMATCH[1]}"
      if valid_ipv4 "$matched_ip"; then
        RELAY_LAN_IP="$matched_ip"
        return 0
      fi
    fi
  done < "$NFT_CONF"
}

load_tcp_mss() {
  local line
  local matched_mss
  TCP_MSS="$DEFAULT_MSS"
  [[ -f "$NFT_CONF" ]] || return 0

  while IFS= read -r line; do
    if [[ "$line" =~ ^define[[:space:]]+TCP_MSS[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
      matched_mss="${BASH_REMATCH[1]}"
      if valid_mss "$matched_mss"; then
        TCP_MSS="$matched_mss"
        return 0
      fi
    fi
  done < "$NFT_CONF"
}

load_state() {
  load_records
  load_relay_lan_ip
  load_tcp_mss
}

ensure_relay_lan_ip() {
  if valid_ipv4 "$RELAY_LAN_IP"; then
    return 0
  fi

  read -r -p "Relay LAN IP (SNAT source IP): " RELAY_LAN_IP
  if ! valid_ipv4 "$RELAY_LAN_IP"; then
    echo "Invalid Relay LAN IP."
    return 1
  fi
}

prompt_relay_lan_ip_on_start() {
  local input

  while true; do
    if valid_ipv4 "$RELAY_LAN_IP"; then
      read -r -p "Relay LAN IP (SNAT source IP) [current: $RELAY_LAN_IP, Enter to keep]: " input
      if [[ -z "$input" ]]; then
        echo "Relay LAN IP kept: $RELAY_LAN_IP"
        return 0
      fi
    else
      read -r -p "Relay LAN IP (SNAT source IP): " input
      if [[ -z "$input" ]]; then
        echo "Relay LAN IP cannot be empty."
        continue
      fi
    fi

    if valid_ipv4 "$input"; then
      RELAY_LAN_IP="$input"
      echo "Relay LAN IP set to $RELAY_LAN_IP"
      return 0
    fi
    echo "Invalid Relay LAN IP."
  done
}

ensure_tcp_mss() {
  if valid_mss "$TCP_MSS"; then
    return 0
  fi
  TCP_MSS="$DEFAULT_MSS"
  return 0
}

set_relay_lan_ip() {
  read -r -p "Relay LAN IP (current: ${RELAY_LAN_IP:-unset}): " RELAY_LAN_IP
  if ! valid_ipv4 "$RELAY_LAN_IP"; then
    echo "Invalid Relay LAN IP."
    return 1
  fi
  echo "Relay LAN IP set to $RELAY_LAN_IP"
}

set_tcp_mss() {
  local value
  read -r -p "TCP MSS (0=disable, current: ${TCP_MSS}): " value
  if ! valid_mss "$value"; then
    echo "Invalid MSS. Use 0 or 536-9000."
    return 1
  fi
  TCP_MSS="$value"
  echo "TCP MSS set to $TCP_MSS"
}

rule_exists() {
  local proto="$1"
  local local_port="$2"
  local rec p l ip r

  for rec in "${RECORDS[@]}"; do
    read -r p l ip r <<< "$rec"
    if [[ "$p" == "$proto" && "$l" == "$local_port" ]]; then
      return 0
    fi
  done
  return 1
}

port_in_use() {
  local proto="$1"
  local local_port="$2"

  if is_enabled "$NFTMGR_TEST_MODE" || is_enabled "$NFTMGR_SKIP_PORT_CHECK"; then
    return 1
  fi

  case "$proto" in
    tcp)
      ss -H -ltn "sport = :$local_port" 2>/dev/null | grep -q .
      ;;
    udp)
      ss -H -lun "sport = :$local_port" 2>/dev/null | grep -q .
      ;;
    *)
      return 1
      ;;
  esac
}

read_protocols() {
  local input="$1"
  local input_lower
  input_lower="$(to_lower "$input")"
  case "$input_lower" in
    ""|both|b) echo "tcp udp" ;;
    tcp|t) echo "tcp" ;;
    udp|u) echo "udp" ;;
    *) return 1 ;;
  esac
}

build_dest_ip_set() {
  local rec proto local_port remote_ip remote_port
  local -a unique=()
  local u exists joined

  for rec in "${RECORDS[@]}"; do
    read -r proto local_port remote_ip remote_port <<< "$rec"
    exists=0
    for u in "${unique[@]}"; do
      if [[ "$u" == "$remote_ip" ]]; then
        exists=1
        break
      fi
    done
    if ((exists == 0)); then
      unique+=("$remote_ip")
    fi
  done

  joined=""
  for u in "${unique[@]}"; do
    if [[ -n "$joined" ]]; then
      joined+=", "
    fi
    joined+="$u"
  done

  echo "$joined"
}

render_config() {
  local output_file="${1:-$NFT_CONF}"
  local rec proto local_port remote_ip remote_port
  local dest_set

  dest_set="$(build_dest_ip_set)"

  {
    echo "#!/usr/sbin/nft -f"
    echo
    echo "# Managed by nft-po0.sh (fixed SNAT source IP, docker-safe no flush)"
    echo "define RELAY_LAN_IP = $RELAY_LAN_IP"
    echo "define TCP_MSS = $TCP_MSS"
    echo
    echo "$MANAGED_BEGIN"
    for rec in "${RECORDS[@]}"; do
      echo "# RULE $rec"
    done
    echo "$MANAGED_END"
    echo
    echo "table ip $NAT_TABLE {"
    echo "    chain prerouting {"
    echo "        type nat hook prerouting priority dstnat; policy accept;"
    for rec in "${RECORDS[@]}"; do
      read -r proto local_port remote_ip remote_port <<< "$rec"
      printf "        meta l4proto %s %s dport %s dnat to %s:%s\n" \
        "$proto" "$proto" "$local_port" "$remote_ip" "$remote_port"
    done
    echo "    }"
    echo
    echo "    chain postrouting {"
    echo "        type nat hook postrouting priority srcnat; policy accept;"
    for rec in "${RECORDS[@]}"; do
      read -r proto local_port remote_ip remote_port <<< "$rec"
      printf "        ip daddr %s meta l4proto %s %s dport %s snat to \$RELAY_LAN_IP\n" \
        "$remote_ip" "$proto" "$proto" "$remote_port"
    done
    echo "    }"
    echo "}"
    echo
    echo "table ip $FILTER_TABLE {"
    echo "    chain forward {"
    echo "        type filter hook forward priority 0; policy accept;"
    if [[ -n "$dest_set" ]] && ((TCP_MSS > 0)); then
      printf "        ip daddr { %s } tcp flags syn tcp option maxseg size set \$TCP_MSS\n" \
        "$dest_set"
    fi
    echo "    }"
    echo "}"
  } > "$output_file"
}

apply_rules() {
  local tmp_file

  if ! ensure_nftables_installed; then
    return 1
  fi
  if ! ensure_relay_lan_ip; then
    return 1
  fi
  ensure_tcp_mss

  tmp_file="$(mktemp)"
  render_config "$tmp_file"

  if is_enabled "$NFTMGR_TEST_MODE"; then
    if ! install -m 644 "$tmp_file" "$NFT_CONF"; then
      rm -f "$tmp_file"
      echo "Failed to write config file: $NFT_CONF"
      return 1
    fi
    rm -f "$tmp_file"
    echo "Test mode: config rendered to $NFT_CONF (nft apply skipped)."
    return 0
  fi

  if ! syntax_check_rules_file "$tmp_file"; then
    rm -f "$tmp_file"
    echo "nft config check failed. Existing config not changed."
    return 1
  fi

  delete_table_if_exists "$NAT_TABLE"
  delete_table_if_exists "$FILTER_TABLE"

  if ! nft -f "$tmp_file"; then
    rm -f "$tmp_file"
    echo "Failed to apply nft rules."
    return 1
  fi

  if ! install -m 644 "$tmp_file" "$NFT_CONF"; then
    rm -f "$tmp_file"
    echo "Rules are active, but failed to persist config to $NFT_CONF"
    return 1
  fi

  rm -f "$tmp_file"
  echo "Rules applied and persisted successfully."
}

list_rules() {
  local i=0
  local rec proto local_port remote_ip remote_port

  if [[ "${#RECORDS[@]}" -eq 0 ]]; then
    echo "No forwarding rules found."
    echo "Relay LAN IP: ${RELAY_LAN_IP:-unset}"
    echo "TCP MSS: ${TCP_MSS}"
    return 1
  fi

  echo "Relay LAN IP: ${RELAY_LAN_IP:-unset}"
  echo "TCP MSS: ${TCP_MSS} (0 means disabled)"
  echo "Current forwarding rules:"
  for rec in "${RECORDS[@]}"; do
    read -r proto local_port remote_ip remote_port <<< "$rec"
    i=$((i + 1))
    printf "%d) %s/%s -> %s:%s\n" "$i" "$local_port" "$proto" "$remote_ip" "$remote_port"
  done
}

add_rule() {
  local local_port remote_ip remote_port proto_input proto_values
  local -a protocols
  local p

  if ! ensure_ss_available; then
    return 1
  fi

  if ! ensure_relay_lan_ip; then
    return 1
  fi
  ensure_tcp_mss

  read -r -p "Local port: " local_port
  if ! valid_port "$local_port"; then
    echo "Invalid local port."
    return 1
  fi

  read -r -p "Protocol [tcp/udp/both] (default: both): " proto_input
  if ! proto_values="$(read_protocols "$proto_input")"; then
    echo "Invalid protocol selection."
    return 1
  fi
  IFS=' ' read -r -a protocols <<< "$proto_values"

  read -r -p "Remote IP (IPv4): " remote_ip
  if ! valid_ipv4 "$remote_ip"; then
    echo "Invalid IPv4 address."
    return 1
  fi

  read -r -p "Remote port: " remote_port
  if ! valid_port "$remote_port"; then
    echo "Invalid remote port."
    return 1
  fi

  for p in "${protocols[@]}"; do
    if rule_exists "$p" "$local_port"; then
      echo "Rule already exists for $local_port/$p."
      return 1
    fi
    if port_in_use "$p" "$local_port"; then
      echo "Local port $local_port/$p is already in use."
      return 1
    fi
  done

  for p in "${protocols[@]}"; do
    RECORDS+=("$p $local_port $remote_ip $remote_port")
  done

  echo "Rule added."
  ensure_ipv4_forwarding || true
  apply_rules
}

delete_rule() {
  local id i
  local -a next_records=()

  if [[ "${#RECORDS[@]}" -eq 0 ]]; then
    echo "No rules to delete."
    return 1
  fi

  list_rules || true
  read -r -p "Enter rule number to delete: " id

  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    echo "Invalid selection."
    return 1
  fi
  if ((id < 1 || id > ${#RECORDS[@]})); then
    echo "Selection out of range."
    return 1
  fi

  for i in "${!RECORDS[@]}"; do
    if (( i != id - 1 )); then
      next_records+=("${RECORDS[$i]}")
    fi
  done
  RECORDS=("${next_records[@]}")

  echo "Rule deleted."
  apply_rules
}

enable_nftables_service() {
  if ! ensure_nftables_installed; then
    return 1
  fi
  if is_enabled "$NFTMGR_TEST_MODE"; then
    echo "Test mode: skip systemctl enable/start."
    return 0
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found on this system."
    return 1
  fi

  systemctl enable --now nftables
  echo "nftables service enabled and started."
}

show_menu() {
  echo
  echo "==== nft-po0.sh (fixed SNAT source IP) ===="
  echo "Current RELAY_LAN_IP: ${RELAY_LAN_IP:-unset}"
  echo "Current TCP MSS: ${TCP_MSS} (0 means disabled)"
  cat <<'EOF'
1) Set RELAY_LAN_IP
2) Set TCP MSS (0=disable)
3) Add forwarding rule
4) List forwarding rules
5) Delete forwarding rule
6) Apply/reload rules
7) Enable nftables on boot (systemctl enable --now nftables)
8) Install nftables
0) Exit
EOF
}

main() {
  require_root
  load_state
  prompt_relay_lan_ip_on_start

  while true; do
    show_menu
    read -r -p "Select: " choice
    case "$choice" in
      1) set_relay_lan_ip || true ;;
      2) set_tcp_mss || true ;;
      3) add_rule || true ;;
      4) list_rules || true ;;
      5) delete_rule || true ;;
      6) ensure_ipv4_forwarding || true; apply_rules || true ;;
      7) enable_nftables_service || true ;;
      8) ensure_nftables_installed || true ;;
      0|q|Q|quit|exit) exit 0 ;;
      *) echo "Invalid selection." ;;
    esac
  done
}

main "$@"
