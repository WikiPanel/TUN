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
  apt-get install -y iproute2 iptables socat curl ca-certificates tar
  ok "Packages installed."
}

download_binaries() {
  local udp2raw_url="http://193.228.169.195/udp2raw_binaries.tar.gz"
  local tinyvpn_url="http://193.228.169.195/tinyvpn_binaries.tar.gz"

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
TUN_IP_CIDR="${TUN_IP_CIDR:-10.22.22.1/24}"
WAIT_SEC="${WAIT_SEC:-15}"

for i in $(seq 1 "$WAIT_SEC"); do
  if ip link show "$TUN_DEV" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

ip link show "$TUN_DEV" >/dev/null 2>&1 || { echo "[tun_tiny_up] Device $TUN_DEV not found after ${WAIT_SEC}s"; exit 1; }

ip link set "$TUN_DEV" up || true

# ensure IP exists (idempotent)
ip addr add "$TUN_IP_CIDR" dev "$TUN_DEV" 2>/dev/null || true

# show state
ip -br a | egrep "${TUN_DEV}|${TUN_IP_CIDR%/*}" || true
SH
  chmod +x /opt/tunnel/bin/tun_tiny_up.sh
}

split_ports() {
  # input: "443, 8443,2087"
  echo "$1" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -E '^[0-9]+$' | awk '!seen[$0]++'
}

# -----------------------------
# Main
# -----------------------------
need_root

echo "========== IRAN TUNNEL (udp2raw server + tinyvpn server + multi-port socat forward) =========="

# Defaults (placeholders)
DEFAULT_KHAREJ_IP="5.6.7.8"
DEFAULT_IRAN_IP="1.2.3.4"
DEFAULT_UDP2RAW_PORT="5084"
DEFAULT_TINYVPN_LOCAL_UDP="5085"
DEFAULT_KEY="maya"
DEFAULT_RAW_MODE="icmp"
DEFAULT_CIPHER="xor"
DEFAULT_AUTH="simple"
DEFAULT_SUBNET="10.22.22.0/24"
DEFAULT_TUN_DEV="tun_tiny"
DEFAULT_IRAN_TUN_IP="10.22.22.1/24"
DEFAULT_KHAREJ_TUN_IP="10.22.22.2"
DEFAULT_FORWARD_PORTS="443,8443,2087,444,587,465"

ACTION="$(ask "Choose action: install | reinstall | uninstall | status" "install")"

if [[ "$ACTION" == "uninstall" ]]; then
  warn "Stopping and removing services..."
  systemctl disable --now udp2raw-server tinyvpn-server 2>/dev/null || true
  for f in /etc/systemd/system/socat-forward-*.service; do
    [[ -e "$f" ]] || continue
    n="$(basename "$f")"
    systemctl disable --now "$n" 2>/dev/null || true
    rm -f "$f"
  done
  rm -f /etc/systemd/system/udp2raw-server.service /etc/systemd/system/tinyvpn-server.service
  systemctl daemon-reload
  rm -rf /opt/tunnel
  ok "Uninstalled (Iran)."
  exit 0
fi

if [[ "$ACTION" == "status" ]]; then
  systemctl status udp2raw-server tinyvpn-server --no-pager -l || true
  ls -1 /etc/systemd/system/socat-forward-*.service 2>/dev/null || true
  ss -lunp | egrep ':(5084|5085)\s' || true
  ip -br a | egrep 'tun_tiny|10\.22\.22\.' || true
  exit 0
fi

# install / reinstall flow
KHAREJ_IP="$(ask "Kharej public IP" "$DEFAULT_KHAREJ_IP")"
IRAN_IP="$(ask "Iran public IP (this server)" "$DEFAULT_IRAN_IP")"
UDP2RAW_PORT="$(ask "udp2raw public port (UDP)" "$DEFAULT_UDP2RAW_PORT")"
TINYVPN_LOCAL_UDP="$(ask "tinyvpn local UDP (127.0.0.1)" "$DEFAULT_TINYVPN_LOCAL_UDP")"
RAW_MODE="$(ask "udp2raw raw-mode (icmp/faketcp/udp)" "$DEFAULT_RAW_MODE")"
KEY="$(ask "Shared secret key" "$DEFAULT_KEY")"
CIPHER="$(ask "udp2raw cipher-mode" "$DEFAULT_CIPHER")"
AUTH="$(ask "udp2raw auth-mode" "$DEFAULT_AUTH")"
SUBNET="$(ask "Tunnel subnet" "$DEFAULT_SUBNET")"
IRAN_TUN_IP_CIDR="$(ask "Tunnel IP (IRAN) CIDR" "$DEFAULT_IRAN_TUN_IP")"
KHAREJ_TUN_IP="$(ask "Tunnel IP (KHAREJ) (no CIDR)" "$DEFAULT_KHAREJ_TUN_IP")"
FORWARD_PORTS_RAW="$(ask "TCP ports to forward (comma separated)" "$DEFAULT_FORWARD_PORTS")"

echo
echo "========== CONFIG SUMMARY =========="
echo "Kharej IP          : ${KHAREJ_IP}"
echo "Iran IP            : ${IRAN_IP}"
echo "udp2raw             : ${RAW_MODE} / UDP ${UDP2RAW_PORT}"
echo "tinyvpn local UDP   : 127.0.0.1:${TINYVPN_LOCAL_UDP}"
echo "Tunnel subnet       : ${SUBNET}"
echo "Tunnel IP (IRAN)    : ${IRAN_TUN_IP_CIDR}"
echo "Tunnel peer (KHA)   : ${KHAREJ_TUN_IP}"
echo "Forwarded TCP ports : ${FORWARD_PORTS_RAW}"
echo "==================================="
echo

ensure_packages
download_binaries
write_tun_up_script

install -d -m 755 /opt/tunnel/conf

# configs
cat > /opt/tunnel/conf/udp2raw-server.conf <<CFG
-s
-l 0.0.0.0:${UDP2RAW_PORT}
-r 127.0.0.1:${TINYVPN_LOCAL_UDP}
--raw-mode ${RAW_MODE}
-k ${KEY}
--cipher-mode ${CIPHER}
--auth-mode ${AUTH}
CFG

cat > /opt/tunnel/conf/tinyvpn-server.conf <<CFG
-s
-l 127.0.0.1:${TINYVPN_LOCAL_UDP}
-f20:10
--sub-net ${SUBNET}
--tun-dev ${DEFAULT_TUN_DEV}
--keep-reconnect
CFG

# systemd services
svc_write "udp2raw-server.service" "[Unit]
Description=udp2raw server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -lc 'exec /opt/tunnel/bin/udp2raw_amd64 \$(tr \"\\n\" \" \" < /opt/tunnel/conf/udp2raw-server.conf)'
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
"

svc_write "tinyvpn-server.service" "[Unit]
Description=tinyvpn server
After=udp2raw-server.service network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=TUN_DEV=${DEFAULT_TUN_DEV}
Environment=TUN_IP_CIDR=${IRAN_TUN_IP_CIDR}
Environment=WAIT_SEC=15
ExecStart=/bin/bash -lc 'exec /opt/tunnel/bin/tinyvpn_amd64 \$(tr \"\\n\" \" \" < /opt/tunnel/conf/tinyvpn-server.conf)'
ExecStartPost=/opt/tunnel/bin/tun_tiny_up.sh
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
"

# create socat units for each port
PORTS=()
while IFS= read -r p; do PORTS+=("$p"); done < <(split_ports "$FORWARD_PORTS_RAW")

if [[ "${#PORTS[@]}" -eq 0 ]]; then
  err "No valid ports provided."
  exit 1
fi

for p in "${PORTS[@]}"; do
  svc_write "socat-forward-${p}.service" "[Unit]
Description=TCP forward ${p} -> ${KHAREJ_TUN_IP}:${p} (over tinyvpn)
After=tinyvpn-server.service
Wants=tinyvpn-server.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${p},reuseaddr,fork TCP:${KHAREJ_TUN_IP}:${p}
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
"
done

# keep IPv4 forwarding enabled (harmless; some people need it for their own use)
sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

systemctl daemon-reload
systemctl enable --now udp2raw-server tinyvpn-server >/dev/null

for p in "${PORTS[@]}"; do
  systemctl enable --now "socat-forward-${p}.service" >/dev/null
done

ok "IRAN tunnel installed and started."

echo
info "Quick checks (Iran):"
echo "  systemctl status udp2raw-server tinyvpn-server --no-pager -l"
echo "  systemctl status socat-forward-* --no-pager -l"
echo "  ss -lunp | egrep ':(\"${UDP2RAW_PORT}\"|\"${TINYVPN_LOCAL_UDP}\")\\s' || true"
echo "  ip -br a | egrep '${DEFAULT_TUN_DEV}|10\\.22\\.22\\.' || true"
echo "  (After Kharej is up)  nc -vz ${KHAREJ_TUN_IP} 587   # example"
echo
ok "Done."
