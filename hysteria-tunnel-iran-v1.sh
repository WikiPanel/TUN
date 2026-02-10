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
CONF_FILE="${CONF_DIR}/iran.conf"
BIN_DIR="/usr/local/bin"

TINYVPN_SERVICE="tinyvpn-iran-v1.service"
UDP2RAW_SERVICE="udp2raw-iran-v1.service"

# Download URLs (as requested)
UDP2RAW_URL="https://wikihost.info/-files/x-other/udp2raw_binaries.tar.gz"
TINYVPN_URL="https://wikihost.info/-files/x-other/tinyvpn_binaries.tar.gz"

# Defaults
D_PUBLIC_PORT="2087"
D_TINYVPN_PORT="5084"
D_UDP2RAW_PORT="4090"
D_SUBNET="10.22.22.0"      # tinyvpn --sub-net
D_TUN_PEER_IP="10.22.22.2" # kharej tunnel IP (tinyvpn default pattern)

# -----------------------------
# Utils
# -----------------------------
rand_key() {
  # 32 hex chars
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

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
# Hysteria Tunnel v1 (IRAN) config
KHAREJ_IP="${KHAREJ_IP}"
PUBLIC_PORT="${PUBLIC_PORT}"
TINYVPN_PORT="${TINYVPN_PORT}"
UDP2RAW_PORT="${UDP2RAW_PORT}"
SUBNET="${SUBNET}"
TUN_PEER_IP="${TUN_PEER_IP}"
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

  # tinyvpn server
  cat > "/etc/systemd/system/${TINYVPN_SERVICE}" <<EOF
[Unit]
Description=Hysteria Tunnel v1 - tinyfecVPN server (IRAN)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/tinyvpn -s -l0.0.0.0:${TINYVPN_PORT} -f20:10 --timeout 0 --sub-net ${SUBNET} --key ${TINYVPN_KEY}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  # udp2raw client (ICMP) - listens on IRAN public port and forwards to KHAREJ via tunnel IP
  cat > "/etc/systemd/system/${UDP2RAW_SERVICE}" <<EOF
[Unit]
Description=Hysteria Tunnel v1 - udp2raw client over ICMP (IRAN)
After=${TINYVPN_SERVICE} network-online.target
Wants=${TINYVPN_SERVICE} network-online.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/udp2raw -c -l0.0.0.0:${PUBLIC_PORT} -r ${TUN_PEER_IP}:${UDP2RAW_PORT} -k "${UDP2RAW_KEY}" --raw-mode icmp -a
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
  echo " Hysteria Tunnel v1 - IRAN Status"
  echo "========================================"

  if load_config_if_exists; then
    echo "Config     : ${CONF_FILE}"
    echo "KHAREJ IP  : ${KHAREJ_IP}"
    echo "Public Port: ${PUBLIC_PORT}/UDP"
    echo "tinyvpn    : ${TINYVPN_PORT}/UDP"
    echo "udp2raw    : ${UDP2RAW_PORT}/UDP (to ${TUN_PEER_IP})"
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
  ss -lunp | grep -E "(:${D_TINYVPN_PORT}\b|:${D_PUBLIC_PORT}\b|:${D_UDP2RAW_PORT}\b)" || true
  ss -lunp | grep -E "(:${PUBLIC_PORT}\b|:${TINYVPN_PORT}\b)" 2>/dev/null || true

  echo
  echo "- Tunnel interfaces (10.22.22.x):"
  ip -brief a | grep -E '10\.22\.22\.' || true

  echo
  echo "- Quick ping test (to ${D_TUN_PEER_IP}):"
  ping -c 2 -W 1 "${D_TUN_PEER_IP}" >/dev/null 2>&1 && ok "Ping OK" || warn "Ping failed (may be normal until kharej is up)"
}

install_flow() {
  require_root
  ensure_packages

  echo "========================================"
  echo " Hysteria Tunnel v1 - IRAN Install"
  echo "========================================"

  read -rp "Enter KHAREJ public IP (required): " KHAREJ_IP
  if [[ -z "${KHAREJ_IP// }" ]]; then
    err "KHAREJ IP is required."
    exit 1
  fi

  read -rp "Public listen port on IRAN [${D_PUBLIC_PORT}]: " PUBLIC_PORT
  PUBLIC_PORT="${PUBLIC_PORT:-$D_PUBLIC_PORT}"

  read -rp "tinyvpn port on IRAN [${D_TINYVPN_PORT}]: " TINYVPN_PORT
  TINYVPN_PORT="${TINYVPN_PORT:-$D_TINYVPN_PORT}"

  read -rp "udp2raw port on KHAREJ (server port) [${D_UDP2RAW_PORT}]: " UDP2RAW_PORT
  UDP2RAW_PORT="${UDP2RAW_PORT:-$D_UDP2RAW_PORT}"

  read -rp "tinyvpn subnet [${D_SUBNET}]: " SUBNET
  SUBNET="${SUBNET:-$D_SUBNET}"

  TUN_PEER_IP="${D_TUN_PEER_IP}"

  read -rp "tinyvpn key (Enter = auto-generate): " TINYVPN_KEY
  if [[ -z "${TINYVPN_KEY}" ]]; then
    TINYVPN_KEY="$(rand_key)"
    ok "Generated tinyvpn key: ${TINYVPN_KEY}"
  fi

  read -rp "udp2raw key (Enter = auto-generate): " UDP2RAW_KEY
  if [[ -z "${UDP2RAW_KEY}" ]]; then
    UDP2RAW_KEY="$(rand_key)"
    ok "Generated udp2raw key: ${UDP2RAW_KEY}"
  fi

  echo
  info "Summary:"
  echo "  KHAREJ IP      : ${KHAREJ_IP}"
  echo "  IRAN Public UDP: ${PUBLIC_PORT}"
  echo "  tinyvpn (IRAN) : ${TINYVPN_PORT}"
  echo "  udp2raw (KHAREJ): ${UDP2RAW_PORT}  (peer IP in tunnel: ${TUN_PEER_IP})"
  echo "  subnet         : ${SUBNET}"
  echo

  # Port check
  if port_in_use_udp "${PUBLIC_PORT}"; then
    warn "UDP port ${PUBLIC_PORT} seems in use on IRAN. Install may fail to bind."
  fi
  if port_in_use_udp "${TINYVPN_PORT}"; then
    warn "UDP port ${TINYVPN_PORT} seems in use on IRAN. Install may fail to bind."
  fi

  download_binaries
  install_binaries
  write_config
  create_systemd_services
  start_services

  echo
  ok "IRAN side installed."
  echo
  echo "IMPORTANT: Save these keys for KHAREJ install:"
  echo "  tinyvpn key : ${TINYVPN_KEY}"
  echo "  udp2raw key : ${UDP2RAW_KEY}"
  echo
  echo "Next: run kharej script and enter same keys."
}

uninstall_flow() {
  require_root
  echo "========================================"
  echo " Hysteria Tunnel v1 - IRAN Uninstall"
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
    echo "====================================="
    echo " Hysteria Tunnel v1 Setup Wizard (IRAN)"
    echo "====================================="
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
