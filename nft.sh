#!/usr/bin/env bash

set -o pipefail

NFT_CONF="${NFT_CONF:-/etc/nftables.conf}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-nft-generic-forward.conf}"
MANAGED_BEGIN="# === nft.sh managed records begin ==="
MANAGED_END="# === nft.sh managed records end ==="
NAT_TABLE="nft_mgr_nat"

NFTMGR_TEST_MODE="${NFTMGR_TEST_MODE:-0}"
NFTMGR_SKIP_ROOT_CHECK="${NFTMGR_SKIP_ROOT_CHECK:-0}"
NFTMGR_SKIP_PORT_CHECK="${NFTMGR_SKIP_PORT_CHECK:-0}"

declare -a RECORDS=()

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
  local check_file check_nat

  check_file="$(mktemp)"
  check_nat="${NAT_TABLE}_check_${RANDOM}_$$"

  sed -e "s/table ip ${NAT_TABLE}/table ip ${check_nat}/g" "$input_file" > "$check_file"
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

render_config() {
  local output_file="${1:-$NFT_CONF}"
  local rec proto local_port remote_ip remote_port
  local key protos
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

  {
    echo "#!/usr/sbin/nft -f"
    echo
    echo "# Managed by nft.sh (generic forward, docker-safe no flush)"
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
          printf "        ip daddr %s meta l4proto { tcp, udp } th dport %s masquerade\n" \
            "$remote_ip" "$remote_port" ;;
        *)
          printf "        ip daddr %s %s dport %s masquerade\n" \
            "$remote_ip" "$protos" "$remote_port" ;;
      esac
    done
    echo "    }"
    echo "}"
  } > "$output_file"
}

apply_rules() {
  local tmp_file

  if ! ensure_nftables_installed; then
    return 1
  fi

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

  load_records
  if [[ "${#RECORDS[@]}" -eq 0 ]]; then
    echo "No forwarding rules found."
    return 1
  fi

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

  load_records

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

  if ! list_rules; then
    return 1
  fi

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
  $0 help                         Show this help

Examples:
  $0 add 10086 172.81.1.1:33333       # both tcp+udp
  $0 add 10086 tcp 172.81.1.1:33333   # tcp only
  $0 add 10086 172.81.1.1             # remote port = local port
  $0 del 1 -y                         # delete rule #1, skip confirmation
EOF
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

  load_records

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

  load_records
  if [[ "${#RECORDS[@]}" -eq 0 ]]; then
    echo "No rules to delete."
    return 1
  fi

  delete_rule_impl "$id" "$skip_confirm"
}

# --- Menu ---

show_menu() {
  cat <<'EOF'

==== nft.sh (generic) ====
1) Add forwarding rule
2) List forwarding rules
3) Delete forwarding rule
4) Apply/reload rules
5) Enable nftables on boot
6) Install nftables
0) Exit
EOF
}

interactive_main() {
  while true; do
    show_menu
    read -r -p "Select: " choice
    case "$choice" in
      1) add_rule || true ;;
      2) list_rules || true ;;
      3) delete_rule || true ;;
      4) ensure_ipv4_forwarding || true; load_records; apply_rules || true ;;
      5) enable_nftables_service || true ;;
      6) ensure_nftables_installed || true ;;
      0|q|Q|quit|exit) exit 0 ;;
      *) echo "Invalid selection." ;;
    esac
  done
}

main() {
  require_root

  case "${1:-}" in
    list)
      list_rules
      ;;
    add)
      shift
      cli_add_rule "$@"
      ;;
    del|delete)
      shift
      cli_delete_rule "$@"
      ;;
    apply)
      ensure_ipv4_forwarding || true
      load_records
      apply_rules
      ;;
    help|--help|-h)
      show_usage
      ;;
    "")
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
