#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# UI Helpers
# -----------------------------
color() { printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
info()  { color "1;34" "[INFO] $*"; }
ok()    { color "1;32" "[OK]   $*"; }
warn()  { color "1;33" "[WARN] $*"; }
err()   { color "1;31" "[ERR]  $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root."
    exit 1
  fi
}

pause() { read -rp "Press Enter to continue... " _; }

# -----------------------------
# Constants
# -----------------------------
CONF_DIR="/etc/hysteria-tunnel-v1"
CONF_FILE="${CONF_DIR}/kharej.conf"
BIN_DIR="/usr/local/bin"

TINYVPN_SERVICE="tinyvpn-kharej-v1.service"
UDP2RAW_SERVICE="udp2raw-kharej-v1.service"

# Download URLs (as requested)
UDP2RAW_URL="https://wikihost.info/-files/x-other/udp2raw_binaries.tar.gz"
TINYVPN_URL="https://wikihost.info/-files/x-other/tinyvpn_binaries.tar.gz"

# Defaults
D_PUBLIC_PORT="2087"        # Hysteria2 local port (destination)
D_TINYVPN_PORT="5084"
D_UDP2RAW_PORT="4090"
D_SUBNET="10.22.22.0"
D_DEST_IP="127.0.0.1"       # Hysteria2 running locally
D_TUNNEL_SELF_IP_HINT="10.22.22.2" # typical client IP

# -----------------------------
# Utils
# -----------------------------
ensure_packages() {
  info "Installing required packages (curl, tar, iproute2, iputils-ping)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl tar iproute2 iputils-ping >/dev/null
  ok "Packages ready."
}

download_binaries() {
  info "Downloading udp2raw binaries..."
  rm -f /tmp/udp2raw_binaries.tar.gz
  curl -L --fail --retry 3 --retry-delay 2 -o /tmp/udp2raw_binaries.tar.gz "$UDP2RAW_URL"

  info "Downloading tinyvpn binaries..."
  rm -f /tmp/tinyvpn_binaries.tar.gz
  curl -L --fail --retry 3 --retry-delay 2 -o /tmp/tinyvpn_binaries.tar.gz "$TINYVPN_URL"

  ok "Downloads completed."
}

install_binaries() {
  info "Installing udp2raw..."
  rm -rf /tmp/udp2raw_extract
  mkdir -p /tmp/udp2raw_extract
  tar -xzf /tmp/udp2raw_binaries.tar.gz -C /tmp/udp2raw_extract
  if [[ -f /tmp/udp2raw_extract/udp2raw_amd64 ]]; then
    install -m 755 /tmp/udp2raw_extract/udp2raw_amd64 "${BIN_DIR}/udp2raw"
  elif [[ -f /tmp/udp2raw_extract/udp2raw ]]; then
    install -m 755 /tmp/udp2raw_extract/udp2raw "${BIN_DIR}/udp2raw"
  else
    err "udp2raw binary not found in tarball."
    exit 1
  fi

  info "Installing tinyfecVPN (tinyvpn)..."
  rm -rf /tmp/tinyvpn_extract
  mkdir -p /tmp/tinyvpn_extract
  tar -xzf /tmp/tinyvpn_binaries.tar.gz -C /tmp/tinyvpn_extract
  if [[ -f /tmp/tinyvpn_extract/tinyvpn_amd64 ]]; then
    install -m 755 /tmp/tinyvpn_extract/tinyvpn_amd64 "${BIN_DIR}/tinyvpn"
  elif [[ -f /tmp/tinyvpn_extract/tinyvpn ]]; then
    install -m 755 /tmp/tinyvpn_extract/tinyvpn "${BIN_DIR}/tinyvpn"
  else
    err "tinyvpn binary not found in tarball."
    exit 1
  fi

  ok "Binaries installed to ${BIN_DIR}."
}

write_config() {
  mkdir -p "$CONF_DIR"
  cat > "$CONF_FILE" <<EOF
# Hysteria Tunnel v1 (KHAREJ) config
IRAN_IP="${IRAN_IP}"
DEST_IP="${DEST_IP}"
DEST_PORT="${DEST_PORT}"
TINYVPN_PORT="${TINYVPN_PORT}"
UDP2RAW_PORT="${UDP2RAW_PORT}"
SUBNET="${SUBNET}"
TINYVPN_KEY="${TINYVPN_KEY}"
UDP2RAW_KEY="${UDP2RAW_KEY}"
EOF
  chmod 600 "$CONF_FILE"
  ok "Config saved: $CONF_FILE"
}

load_config_if_exists() {
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    return 0
  fi
  return 1
}

port_in_use_udp() {
  local p="$1"
  ss -lunp | awk '{print $5}' | grep -qE "[:.]${p}$"
}

create_systemd_services() {
  info "Creating systemd services..."

  # tinyvpn client (connects to IRAN)
  cat > "/etc/systemd/system/${TINYVPN_SERVICE}" <<EOF
[Unit]
Description=Hysteria Tunnel v1 - tinyfecVPN client (KHAREJ)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/tinyvpn -c -r${IRAN_IP}:${TINYVPN_PORT} -f20:10 --timeout 0 --sub-net ${SUBNET} --key ${TINYVPN_KEY}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  # udp2raw server (ICMP) - listens on UDP2RAW_PORT and forwards to local Hysteria2 UDP port
  cat > "/etc/systemd/system/${UDP2RAW_SERVICE}" <<EOF
[Unit]
Description=Hysteria Tunnel v1 - udp2raw server over ICMP (KHAREJ)
After=${TINYVPN_SERVICE} network-online.target
Wants=${TINYVPN_SERVICE} network-online.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/udp2raw -s -l0.0.0.0:${UDP2RAW_PORT} -r ${DEST_IP}:${DEST_PORT} -k "${UDP2RAW_KEY}" --raw-mode icmp -a
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  ok "systemd units created."
}

start_services() {
  info "Enabling & starting services..."
  systemctl enable --now "${TINYVPN_SERVICE}" >/dev/null
  systemctl enable --now "${UDP2RAW_SERVICE}" >/dev/null
  ok "Services started."
}

stop_services() {
  systemctl stop "${UDP2RAW_SERVICE}" >/dev/null 2>&1 || true
  systemctl stop "${TINYVPN_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable "${UDP2RAW_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable "${TINYVPN_SERVICE}" >/dev/null 2>&1 || true
  true
}

remove_services() {
  rm -f "/etc/systemd/system/${UDP2RAW_SERVICE}" "/etc/systemd/system/${TINYVPN_SERVICE}"
  systemctl daemon-reload
}

show_status() {
  echo "========================================"
  echo " Hysteria Tunnel v1 - KHAREJ Status"
  echo "========================================"

  if load_config_if_exists; then
    echo "Config     : ${CONF_FILE}"
    echo "IRAN IP    : ${IRAN_IP}"
    echo "Dest       : ${DEST_IP}:${DEST_PORT} (Hysteria2 local)"
    echo "tinyvpn    : connect to ${IRAN_IP}:${TINYVPN_PORT}"
    echo "udp2raw    : listen ${UDP2RAW_PORT}/UDP (ICMP raw)"
    echo "Subnet     : ${SUBNET}"
  else
    warn "Config not found: ${CONF_FILE}"
  fi

  echo
  echo "- Services:"
  systemctl is-active "${TINYVPN_SERVICE}" 2>/dev/null | sed 's/^/  tinyvpn : /' || true
  systemctl is-active "${UDP2RAW_SERVICE}" 2>/dev/null | sed 's/^/  udp2raw : /' || true

  echo
  echo "- Listening UDP ports:"
  ss -lunp | grep -E "(:${D_UDP2RAW_PORT}\b|:${UDP2RAW_PORT}\b)" 2>/dev/null || true

  echo
  echo "- Tunnel interfaces (10.22.22.x):"
  ip -brief a | grep -E '10\.22\.22\.' || true

  echo
  echo "- Quick ping test (to 10.22.22.1):"
  ping -c 2 -W 1 "10.22.22.1" >/dev/null 2>&1 && ok "Ping OK" || warn "Ping failed (may be normal until iran is up)"
}

install_flow() {
  require_root
  ensure_packages

  echo "========================================"
  echo " Hysteria Tunnel v1 - KHAREJ Install"
  echo "========================================"

  read -rp "Enter IRAN public IP (required): " IRAN_IP
  if [[ -z "${IRAN_IP// }" ]]; then
    err "IRAN IP is required."
    exit 1
  fi

  read -rp "Hysteria2 local port on KHAREJ [${D_PUBLIC_PORT}]: " DEST_PORT
  DEST_PORT="${DEST_PORT:-$D_PUBLIC_PORT}"

  read -rp "Hysteria2 local bind IP [${D_DEST_IP}]: " DEST_IP
  DEST_IP="${DEST_IP:-$D_DEST_IP}"

  read -rp "tinyvpn port on IRAN [${D_TINYVPN_PORT}]: " TINYVPN_PORT
  TINYVPN_PORT="${TINYVPN_PORT:-$D_TINYVPN_PORT}"

  read -rp "udp2raw server port on KHAREJ [${D_UDP2RAW_PORT}]: " UDP2RAW_PORT
  UDP2RAW_PORT="${UDP2RAW_PORT:-$D_UDP2RAW_PORT}"

  read -rp "tinyvpn subnet [${D_SUBNET}]: " SUBNET
  SUBNET="${SUBNET:-$D_SUBNET}"

  # Keys MUST match IRAN side
  read -rp "tinyvpn key (must match IRAN): " TINYVPN_KEY
  if [[ -z "${TINYVPN_KEY}" ]]; then
    err "tinyvpn key is required and must match IRAN."
    exit 1
  fi

  read -rp "udp2raw key (must match IRAN): " UDP2RAW_KEY
  if [[ -z "${UDP2RAW_KEY}" ]]; then
    err "udp2raw key is required and must match IRAN."
    exit 1
  fi

  echo
  info "Summary:"
  echo "  IRAN IP         : ${IRAN_IP}"
  echo "  Hysteria2 local : ${DEST_IP}:${DEST_PORT}/UDP"
  echo "  tinyvpn connect : ${IRAN_IP}:${TINYVPN_PORT}"
  echo "  udp2raw listen  : ${UDP2RAW_PORT}/UDP"
  echo "  subnet          : ${SUBNET}"
  echo

  if port_in_use_udp "${UDP2RAW_PORT}"; then
    warn "UDP port ${UDP2RAW_PORT} seems in use on KHAREJ. Install may fail to bind."
  fi

  download_binaries
  install_binaries
  write_config
  create_systemd_services
  start_services

  echo
  ok "KHAREJ side installed."
  echo
  echo "Now your mapping should be:"
  echo "  IRAN_PUBLIC:${DEST_PORT}/UDP  --->  KHAREJ_LOCAL:${DEST_PORT}/UDP (via udp2raw+tinyvpn)"
  echo
}

uninstall_flow() {
  require_root
  echo "========================================"
  echo " Hysteria Tunnel v1 - KHAREJ Uninstall"
  echo "========================================"
  read -rp "Are you sure you want to uninstall? [y/N]: " ans
  ans="${ans:-N}"
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    info "Cancelled."
    return 0
  fi

  stop_services
  remove_services

  rm -f "$CONF_FILE"
  rmdir "$CONF_DIR" 2>/dev/null || true

  ok "Uninstalled services and config."
  warn "Binaries were not removed: ${BIN_DIR}/tinyvpn and ${BIN_DIR}/udp2raw"
}

menu() {
  while true; do
    echo
    echo "======================================="
    echo " Hysteria Tunnel v1 Setup Wizard (KHAREJ)"
    echo "======================================="
    echo "1) Install"
    echo "2) Uninstall"
    echo "3) Status"
    echo "4) Exit"
    echo
    read -rp "Select an option [1-4]: " opt
    case "${opt:-}" in
      1) install_flow; pause ;;
      2) uninstall_flow; pause ;;
      3) show_status; pause ;;
      4) exit 0 ;;
      *) warn "Invalid option." ;;
    esac
  done
}

menu
