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

# --- Utility functions ---

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
  local answer answer_lower
  read -r -p "$prompt" answer
  answer_lower="$(to_lower "$answer")"
  case "$answer_lower" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

confirm_default_yes() {
  local prompt="$1"
  local answer answer_lower
  read -r -p "$prompt" answer
  answer_lower="$(to_lower "$answer")"
  case "$answer_lower" in
    ""|y|yes) return 0 ;;
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

format_rule() {
  local proto="$1" local_port="$2" remote_ip="$3" remote_port="$4"
  printf "%s/%s -> %s:%s" "$local_port" "$proto" "$remote_ip" "$remote_port"
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

parse_quick_input() {
  local input="$1"
  local -a parts
  local local_port proto_str remote_part remote_ip remote_port

  IFS=' ' read -r -a parts <<< "$input"

  case "${#parts[@]}" in
    2)
      local_port="${parts[0]}"
      proto_str="both"
      remote_part="${parts[1]}"
      ;;
    3)
      local_port="${parts[0]}"
      proto_str="${parts[1]}"
      remote_part="${parts[2]}"
      ;;
    *)
      return 1
      ;;
  esac

  if [[ "$remote_part" == *:* ]]; then
    remote_ip="${remote_part%:*}"
    remote_port="${remote_part##*:}"
  else
    remote_ip="$remote_part"
    remote_port="$local_port"
  fi

  valid_port "$local_port" || return 1
  read_protocols "$proto_str" >/dev/null 2>&1 || return 1
  valid_ipv4 "$remote_ip" || return 1
  valid_port "$remote_port" || return 1

  echo "$local_port $proto_str $remote_ip $remote_port"
}

# --- Parse / Load ---

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

# --- RELAY_LAN_IP / TCP_MSS management ---

ensure_relay_lan_ip() {
  local input
  if valid_ipv4 "$RELAY_LAN_IP"; then
    return 0
  fi

  read -r -p "Relay LAN IP (SNAT source IP): " input
  if ! valid_ipv4 "$input"; then
    echo "Invalid Relay LAN IP."
    return 1
  fi
  RELAY_LAN_IP="$input"
}

ensure_tcp_mss() {
  if valid_mss "$TCP_MSS"; then
    return 0
  fi
  TCP_MSS="$DEFAULT_MSS"
  return 0
}

set_relay_lan_ip() {
  local input
  read -r -p "Relay LAN IP (current: ${RELAY_LAN_IP:-unset}): " input
  if ! valid_ipv4 "$input"; then
    echo "Invalid Relay LAN IP."
    return 1
  fi
  RELAY_LAN_IP="$input"
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

# --- System checks ---

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

# --- nft operations ---

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

# --- Rule checks ---

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

# --- Render / Apply ---

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
  local key protos dest_set
  local -A grouped_protos=()
  local -a grouped_order=()

  for rec in "${RECORDS[@]}"; do
    read -r proto local_port remote_ip remote_port <<< "$rec"
    key="${local_port}|${remote_ip}|${remote_port}"
    if [[ -z "${grouped_protos[$key]:-}" ]]; then
      grouped_protos[$key]="$proto"
      grouped_order+=("$key")
    elif [[ "${grouped_protos[$key]}" != *"$proto"* ]]; then
      grouped_protos[$key]+=" $proto"
    fi
  done

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
    for key in "${grouped_order[@]}"; do
      IFS='|' read -r local_port remote_ip remote_port <<< "$key"
      protos="${grouped_protos[$key]}"
      case "$protos" in
        "tcp udp"|"udp tcp")
          printf "        meta l4proto { tcp, udp } th dport %s dnat to %s:%s\n" \
            "$local_port" "$remote_ip" "$remote_port" ;;
        *)
          printf "        %s dport %s dnat to %s:%s\n" \
            "$protos" "$local_port" "$remote_ip" "$remote_port" ;;
      esac
    done
    echo "    }"
    echo
    echo "    chain postrouting {"
    echo "        type nat hook postrouting priority srcnat; policy accept;"
    for key in "${grouped_order[@]}"; do
      IFS='|' read -r local_port remote_ip remote_port <<< "$key"
      protos="${grouped_protos[$key]}"
      case "$protos" in
        "tcp udp"|"udp tcp")
          printf "        ip daddr %s meta l4proto { tcp, udp } th dport %s snat to \$RELAY_LAN_IP\n" \
            "$remote_ip" "$remote_port" ;;
        *)
          printf "        ip daddr %s %s dport %s snat to \$RELAY_LAN_IP\n" \
            "$remote_ip" "$protos" "$remote_port" ;;
      esac
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

# --- Core operations ---

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
    printf "%d) %s\n" "$i" "$(format_rule "$proto" "$local_port" "$remote_ip" "$remote_port")"
  done
}

add_rule_impl() {
  local local_port="$1" proto_input="$2" remote_ip="$3" remote_port="$4"
  local skip_confirm="${5:-0}"
  local proto_values p
  local -a protocols

  if ! proto_values="$(read_protocols "$proto_input")"; then
    echo "Invalid protocol selection."
    return 1
  fi
  IFS=' ' read -r -a protocols <<< "$proto_values"

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

  echo "Add rule: $local_port/$proto_input -> $remote_ip:$remote_port"
  if ((skip_confirm == 0)); then
    if ! confirm_default_yes "Confirm? [Y/n]: "; then
      echo "Cancelled."
      return 1
    fi
  fi

  for p in "${protocols[@]}"; do
    RECORDS+=("$p $local_port $remote_ip $remote_port")
  done

  ensure_ipv4_forwarding || true
  apply_rules
}

add_rule() {
  local local_port remote_ip remote_port proto_input quick_input parsed

  if ! ensure_ss_available; then
    return 1
  fi

  if ! ensure_relay_lan_ip; then
    return 1
  fi
  ensure_tcp_mss

  echo "Quick add format: PORT [PROTO] IP[:RPORT] (e.g. 10086 172.81.1.1:33333)"
  read -r -p "Quick add (or Enter for step-by-step): " quick_input

  if [[ -n "$quick_input" ]]; then
    if ! parsed="$(parse_quick_input "$quick_input")"; then
      echo "Invalid format. Example: 10086 172.81.1.1:33333"
      return 1
    fi
    read -r local_port proto_input remote_ip remote_port <<< "$parsed"
  else
    read -r -p "Local port: " local_port
    if ! valid_port "$local_port"; then
      echo "Invalid local port."
      return 1
    fi

    read -r -p "Protocol [tcp/udp/both] (default: both): " proto_input
    proto_input="${proto_input:-both}"

    read -r -p "Remote IP (IPv4): " remote_ip
    if ! valid_ipv4 "$remote_ip"; then
      echo "Invalid IPv4 address."
      return 1
    fi

    read -r -p "Remote port (default: $local_port): " remote_port
    remote_port="${remote_port:-$local_port}"
    if ! valid_port "$remote_port"; then
      echo "Invalid remote port."
      return 1
    fi
  fi

  add_rule_impl "$local_port" "$proto_input" "$remote_ip" "$remote_port"
}

delete_rule_impl() {
  local id="$1"
  local skip_confirm="${2:-0}"
  local i
  local -a next_records=()
  local del_rec del_proto del_lport del_rip del_rport

  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    echo "Invalid selection."
    return 1
  fi
  if ((id < 1 || id > ${#RECORDS[@]})); then
    echo "Selection out of range."
    return 1
  fi

  del_rec="${RECORDS[$((id - 1))]}"
  read -r del_proto del_lport del_rip del_rport <<< "$del_rec"
  echo "Delete rule: $(format_rule "$del_proto" "$del_lport" "$del_rip" "$del_rport")"

  if ((skip_confirm == 0)); then
    if ! confirm "Confirm delete? [y/N]: "; then
      echo "Cancelled."
      return 1
    fi
  fi

  for i in "${!RECORDS[@]}"; do
    if (( i != id - 1 )); then
      next_records+=("${RECORDS[$i]}")
    fi
  done
  RECORDS=("${next_records[@]}")

  apply_rules
}

delete_rule() {
  local id

  if [[ "${#RECORDS[@]}" -eq 0 ]]; then
    echo "No rules to delete."
    return 1
  fi

  list_rules || true
  read -r -p "Enter rule number to delete: " id
  delete_rule_impl "$id"
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

# --- CLI support ---

show_usage() {
  cat <<EOF
Usage:
  $0                              Interactive menu
  $0 list                         List current rules
  $0 add PORT [PROTO] IP[:RPORT]  Add a forwarding rule
  $0 del NUMBER [-y]              Delete a rule by number
  $0 apply                        Re-apply rules from config
  $0 set-ip IP                    Set RELAY_LAN_IP
  $0 set-mss MSS                  Set TCP MSS (0=disable)
  $0 help                         Show this help

Examples:
  $0 set-ip 10.100.1.1
  $0 add 10086 172.81.1.1:33333       # both tcp+udp
  $0 add 10086 tcp 172.81.1.1:33333   # tcp only
  $0 add 10086 172.81.1.1             # remote port = local port
  $0 del 1 -y                         # delete rule #1, skip confirmation
EOF
}

require_relay_lan_ip_cli() {
  if valid_ipv4 "$RELAY_LAN_IP"; then
    return 0
  fi
  echo "RELAY_LAN_IP not set. Run first: $0 set-ip IP"
  return 1
}

cli_add_rule() {
  local skip_confirm=0
  local -a rule_args=()
  local arg parsed local_port proto_input remote_ip remote_port

  for arg in "$@"; do
    if [[ "$arg" == "-y" ]]; then
      skip_confirm=1
    else
      rule_args+=("$arg")
    fi
  done

  if [[ "${#rule_args[@]}" -lt 2 ]]; then
    echo "Usage: $0 add PORT [PROTO] IP[:RPORT] [-y]"
    return 1
  fi

  if ! ensure_ss_available; then
    return 1
  fi

  if ! require_relay_lan_ip_cli; then
    return 1
  fi
  ensure_tcp_mss

  if ! parsed="$(parse_quick_input "${rule_args[*]}")"; then
    echo "Invalid arguments. Example: $0 add 10086 172.81.1.1:33333"
    return 1
  fi
  read -r local_port proto_input remote_ip remote_port <<< "$parsed"

  add_rule_impl "$local_port" "$proto_input" "$remote_ip" "$remote_port" "$skip_confirm"
}

cli_delete_rule() {
  local skip_confirm=0
  local id=""
  local arg

  for arg in "$@"; do
    if [[ "$arg" == "-y" ]]; then
      skip_confirm=1
    else
      id="$arg"
    fi
  done

  if [[ -z "$id" ]] || ! [[ "$id" =~ ^[0-9]+$ ]]; then
    echo "Usage: $0 del NUMBER [-y]"
    return 1
  fi

  if ! require_relay_lan_ip_cli; then
    return 1
  fi

  if [[ "${#RECORDS[@]}" -eq 0 ]]; then
    echo "No rules to delete."
    return 1
  fi

  delete_rule_impl "$id" "$skip_confirm"
}

cli_set_ip() {
  local ip="$1"
  if [[ -z "$ip" ]]; then
    echo "Usage: $0 set-ip IP"
    return 1
  fi
  if ! valid_ipv4 "$ip"; then
    echo "Invalid IPv4 address."
    return 1
  fi
  RELAY_LAN_IP="$ip"
  echo "RELAY_LAN_IP set to $RELAY_LAN_IP"
  ensure_tcp_mss
  apply_rules
}

cli_set_mss() {
  local mss="$1"
  if [[ -z "$mss" ]]; then
    echo "Usage: $0 set-mss MSS (0=disable, 536-9000)"
    return 1
  fi
  if ! valid_mss "$mss"; then
    echo "Invalid MSS. Use 0 or 536-9000."
    return 1
  fi
  if ! require_relay_lan_ip_cli; then
    return 1
  fi
  TCP_MSS="$mss"
  echo "TCP MSS set to $TCP_MSS"
  apply_rules
}

# --- Menu ---

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
7) Enable nftables on boot
8) Install nftables
0) Exit
EOF
}

interactive_main() {
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

main() {
  require_root

  case "${1:-}" in
    list)
      load_state
      list_rules
      ;;
    add)
      shift
      load_state
      cli_add_rule "$@"
      ;;
    del|delete)
      shift
      load_state
      cli_delete_rule "$@"
      ;;
    apply)
      load_state
      if ! require_relay_lan_ip_cli; then
        exit 1
      fi
      ensure_ipv4_forwarding || true
      apply_rules
      ;;
    set-ip)
      load_state
      cli_set_ip "${2:-}"
      ;;
    set-mss)
      load_state
      cli_set_mss "${2:-}"
      ;;
    help|--help|-h)
      show_usage
      ;;
    "")
      load_state
      if valid_ipv4 "$RELAY_LAN_IP"; then
        echo "Loaded RELAY_LAN_IP: $RELAY_LAN_IP, TCP MSS: $TCP_MSS"
      else
        echo "RELAY_LAN_IP not set."
        if ! ensure_relay_lan_ip; then
          exit 1
        fi
      fi
      interactive_main
      ;;
    *)
      echo "Unknown command: $1"
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
