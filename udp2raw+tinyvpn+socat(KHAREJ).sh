#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Helpers
# -----------------------------
color() { printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
info()  { color "1;34" "[INFO] $*"; }
ok()    { color "1;32" "[OK]   $*"; }
warn()  { color "1;33" "[WARN] $*"; }
err()   { color "1;31" "[ERR]  $*"; }

ask() {
  local prompt="$1" default="$2" var
  read -rp "$prompt [$default]: " var || true
  if [[ -z "${var// }" ]]; then
    echo "$default"
  else
    echo "$var"
  fi
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Please run as root."
    exit 1
  fi
}

svc_write() {
  local name="$1" content="$2"
  install -m 644 /dev/null "/etc/systemd/system/${name}"
  printf "%s\n" "$content" > "/etc/systemd/system/${name}"
}

ensure_packages() {
  info "Updating apt & installing required packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y iproute2 iptables curl ca-certificates tar
  ok "Packages installed."
}

download_binaries() {
  local udp2raw_url="https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz"
  local tinyvpn_url="https://github.com/wangyu-/tinyfecVPN/releases/download/20230206.0/tinyvpn_binaries.tar.gz"

  info "Downloading udp2raw binaries..."
  rm -f /tmp/udp2raw_binaries.tar.gz
  curl -L --fail --retry 3 --retry-delay 2 -o /tmp/udp2raw_binaries.tar.gz "$udp2raw_url"

  info "Downloading tinyvpn binaries..."
  rm -f /tmp/tinyvpn_binaries.tar.gz
  curl -L --fail --retry 3 --retry-delay 2 -o /tmp/tinyvpn_binaries.tar.gz "$tinyvpn_url"

  mkdir -p /opt/tunnel/bin /opt/tunnel/conf

  # sanity check (avoid HTML/404 saved as tiny files)
  local s1 s2
  s1="$(stat -c%s /tmp/udp2raw_binaries.tar.gz 2>/dev/null || echo 0)"
  s2="$(stat -c%s /tmp/tinyvpn_binaries.tar.gz 2>/dev/null || echo 0)"
  if [[ "$s1" -lt 500000 ]]; then
    err "udp2raw archive too small (${s1} bytes). Download failed or blocked."
    exit 1
  fi
  if [[ "$s2" -lt 500000 ]]; then
    err "tinyvpn archive too small (${s2} bytes). Download failed or blocked."
    exit 1
  fi

  local tmp1 tmp2 u t
  tmp1="$(mktemp -d)"
  tmp2="$(mktemp -d)"
  tar -xzf /tmp/udp2raw_binaries.tar.gz -C "$tmp1"
  tar -xzf /tmp/tinyvpn_binaries.tar.gz -C "$tmp2"

  # pick best udp2raw for amd64 (prefer hw_aes if exists)
  u="$(find "$tmp1" -type f \( -name 'udp2raw_amd64_hw_aes' -o -name 'udp2raw_amd64' -o -iname 'udp2raw*amd64*' \) 2>/dev/null | head -n 1)"
  # pick best tinyvpn for amd64
  t="$(find "$tmp2" -type f \( -name 'tinyvpn_amd64' -o -iname 'tinyvpn*amd64*' \) 2>/dev/null | head -n 1)"

  if [[ -z "${u:-}" ]]; then
    err "Could not locate udp2raw amd64 binary inside archive."
    info "Archive listing (first 120):"
    tar -tzf /tmp/udp2raw_binaries.tar.gz | head -n 120 || true
    exit 1
  fi
  if [[ -z "${t:-}" ]]; then
    err "Could not locate tinyvpn amd64 binary inside archive."
    info "Archive listing (first 120):"
    tar -tzf /tmp/tinyvpn_binaries.tar.gz | head -n 120 || true
    exit 1
  fi

  install -m 755 "$u" /opt/tunnel/bin/udp2raw_amd64
  install -m 755 "$t" /opt/tunnel/bin/tinyvpn_amd64

  rm -rf "$tmp1" "$tmp2"

  ok "Binaries installed:"
  ls -lah /opt/tunnel/bin/udp2raw_amd64 /opt/tunnel/bin/tinyvpn_amd64
}

write_tun_up_script() {
  cat > /opt/tunnel/bin/tun_tiny_up.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

TUN_DEV="${TUN_DEV:-tun_tiny}"
TUN_IP_CIDR="${TUN_IP_CIDR:-10.22.22.2/24}"
WAIT_SEC="${WAIT_SEC:-20}"

# Wait until tun device exists (tinyvpn creates it)
for i in $(seq 1 "$WAIT_SEC"); do
  if ip link show "$TUN_DEV" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

ip link show "$TUN_DEV" >/dev/null 2>&1 || { echo "[tun_tiny_up] Device $TUN_DEV not found after ${WAIT_SEC}s"; exit 1; }

ip link set "$TUN_DEV" up || true
ip addr add "$TUN_IP_CIDR" dev "$TUN_DEV" 2>/dev/null || true

ip -br a | egrep "${TUN_DEV}|${TUN_IP_CIDR%/*}" || true
SH
  chmod +x /opt/tunnel/bin/tun_tiny_up.sh
}

# -----------------------------
# Main
# -----------------------------
need_root

echo "========== KHAREJ TUNNEL (udp2raw client + tinyvpn client) =========="

# Defaults (placeholders)
DEFAULT_IRAN_IP="1.2.3.4"
DEFAULT_KHAREJ_IP="5.6.7.8"
DEFAULT_UDP2RAW_PORT="5084"
DEFAULT_TINYVPN_LOCAL_UDP="5085"
DEFAULT_KEY="maya"
DEFAULT_RAW_MODE="icmp"
DEFAULT_CIPHER="xor"
DEFAULT_AUTH="simple"
DEFAULT_SUBNET="10.22.22.0/24"
DEFAULT_TUN_DEV="tun_tiny"
DEFAULT_KHAREJ_TUN_IP="10.22.22.2/24"

ACTION="$(ask "Choose action: install | reinstall | uninstall | status" "install")"

if [[ "$ACTION" == "uninstall" ]]; then
  warn "Stopping and removing services..."
  systemctl disable --now udp2raw-client tinyvpn-client 2>/dev/null || true
  rm -f /etc/systemd/system/udp2raw-client.service /etc/systemd/system/tinyvpn-client.service
  systemctl daemon-reload
  rm -rf /opt/tunnel
  ok "Uninstalled (Kharej)."
  exit 0
fi

if [[ "$ACTION" == "status" ]]; then
  systemctl status udp2raw-client tinyvpn-client --no-pager -l || true
  ss -lunp | egrep ':(5084|5085)\s' || true
  ip -br a | egrep 'tun_tiny|10\.22\.22\.' || true
  exit 0
fi

# install / reinstall flow
IRAN_IP="$(ask "Iran public IP (remote server)" "$DEFAULT_IRAN_IP")"
KHAREJ_IP="$(ask "Kharej public IP (this server)" "$DEFAULT_KHAREJ_IP")"
UDP2RAW_PORT="$(ask "udp2raw remote port on Iran (UDP)" "$DEFAULT_UDP2RAW_PORT")"
TINYVPN_LOCAL_UDP="$(ask "Local udp2raw listen port (127.0.0.1) used by tinyvpn" "$DEFAULT_TINYVPN_LOCAL_UDP")"
RAW_MODE="$(ask "udp2raw raw-mode (icmp/faketcp/udp)" "$DEFAULT_RAW_MODE")"
KEY="$(ask "Shared secret key" "$DEFAULT_KEY")"
CIPHER="$(ask "udp2raw cipher-mode" "$DEFAULT_CIPHER")"
AUTH="$(ask "udp2raw auth-mode" "$DEFAULT_AUTH")"
SUBNET="$(ask "Tunnel subnet" "$DEFAULT_SUBNET")"
KHAREJ_TUN_IP_CIDR="$(ask "Tunnel IP (KHAREJ) CIDR" "$DEFAULT_KHAREJ_TUN_IP")"

echo
echo "========== CONFIG SUMMARY =========="
echo "Iran IP            : ${IRAN_IP}"
echo "Kharej IP          : ${KHAREJ_IP}"
echo "udp2raw            : ${RAW_MODE} -> ${IRAN_IP}:${UDP2RAW_PORT}"
echo "Local udp2raw UDP  : 127.0.0.1:${TINYVPN_LOCAL_UDP}"
echo "Tunnel subnet      : ${SUBNET}"
echo "Tunnel IP (KHAREJ) : ${KHAREJ_TUN_IP_CIDR}"
echo "==================================="
echo

ensure_packages
download_binaries
write_tun_up_script

install -d -m 755 /opt/tunnel/conf

cat > /opt/tunnel/conf/udp2raw-client.conf <<CFG
-c
-r ${IRAN_IP}:${UDP2RAW_PORT}
-l 127.0.0.1:${TINYVPN_LOCAL_UDP}
--raw-mode ${RAW_MODE}
-a
-k ${KEY}
--cipher-mode ${CIPHER}
--auth-mode ${AUTH}
CFG

cat > /opt/tunnel/conf/tinyvpn-client.conf <<CFG
-c
-r 127.0.0.1:${TINYVPN_LOCAL_UDP}
-f20:10
--sub-net ${SUBNET}
--tun-dev ${DEFAULT_TUN_DEV}
--keep-reconnect
CFG

svc_write "udp2raw-client.service" "[Unit]
Description=udp2raw client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -lc 'exec /opt/tunnel/bin/udp2raw_amd64 \$(tr \"\\n\" \" \" < /opt/tunnel/conf/udp2raw-client.conf)'
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
"

svc_write "tinyvpn-client.service" "[Unit]
Description=tinyvpn client
After=udp2raw-client.service network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=TUN_DEV=${DEFAULT_TUN_DEV}
Environment=TUN_IP_CIDR=${KHAREJ_TUN_IP_CIDR}
Environment=WAIT_SEC=20
ExecStart=/bin/bash -lc 'exec /opt/tunnel/bin/tinyvpn_amd64 \$(tr \"\\n\" \" \" < /opt/tunnel/conf/tinyvpn-client.conf)'
ExecStartPost=/opt/tunnel/bin/tun_tiny_up.sh
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
"

systemctl daemon-reload
systemctl enable --now udp2raw-client tinyvpn-client >/dev/null

ok "KHAREJ tunnel installed and started."

echo
info "Quick checks (Kharej):"
echo "  systemctl status udp2raw-client tinyvpn-client --no-pager -l"
echo "  ip -br a | egrep '${DEFAULT_TUN_DEV}|10\\.22\\.22\\.' || true"
echo "  nc -vz 10.22.22.1 587     # example inside tunnel (needs Iran side forward)"
echo
ok "Done."
