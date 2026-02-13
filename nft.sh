#!/usr/bin/env bash

set -o pipefail

NFT_CONF="${NFT_CONF:-/etc/nftables.conf}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-nft-generic-forward.conf}"
MANAGED_BEGIN="# === nft.sh managed records begin ==="
MANAGED_END="# === nft.sh managed records end ==="

NFTMGR_TEST_MODE="${NFTMGR_TEST_MODE:-0}"
NFTMGR_SKIP_ROOT_CHECK="${NFTMGR_SKIP_ROOT_CHECK:-0}"
NFTMGR_SKIP_PORT_CHECK="${NFTMGR_SKIP_PORT_CHECK:-0}"

declare -a RECORDS=()

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

load_records() {
  local line parsed
  RECORDS=()

  [[ -f "$NFT_CONF" ]] || return 0

  while IFS= read -r line; do
    parsed="$(parse_rule_line "$line" || true)"
    [[ -n "$parsed" ]] && RECORDS+=("$parsed")
  done < "$NFT_CONF"
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

render_config() {
  local output_file="${1:-$NFT_CONF}"
  local rec proto local_port remote_ip remote_port

  {
    echo "#!/usr/sbin/nft -f"
    echo "flush ruleset"
    echo
    echo "# Managed by nft.sh (generic forward)"
    echo "$MANAGED_BEGIN"
    for rec in "${RECORDS[@]}"; do
      echo "# RULE $rec"
    done
    echo "$MANAGED_END"
    echo
    echo "table ip nat {"
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
      printf "        ip daddr %s meta l4proto %s %s dport %s masquerade\n" \
        "$remote_ip" "$proto" "$proto" "$remote_port"
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

  if ! nft -c -f "$tmp_file"; then
    rm -f "$tmp_file"
    echo "nft config check failed. Existing config not changed."
    return 1
  fi

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

  load_records
  if [[ "${#RECORDS[@]}" -eq 0 ]]; then
    echo "No forwarding rules found."
    return 1
  fi

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

  load_records

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

  load_records
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
  cat <<'EOF'

==== nft.sh (generic) ====
1) Add forwarding rule
2) List forwarding rules
3) Delete forwarding rule
4) Apply/reload rules
5) Enable nftables on boot (systemctl enable --now nftables)
6) Install nftables
0) Exit
EOF
}

main() {
  require_root

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

main "$@"
