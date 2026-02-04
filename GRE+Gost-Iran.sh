#!/bin/bash
set -e

read -p "Enter KHAREJ public IP: " KH_IP
read -p "Enter IRAN public IP: " IR_IP

cat <<EOF > /etc/netplan/gre1.yaml
network:
  version: 2
  renderer: networkd

  tunnels:
    gre1:
      mode: gre
      local: ${IR_IP}
      remote: ${KH_IP}
      addresses:
        - 10.10.10.2/30
      mtu: 1476
EOF

netplan generate
netplan apply

bash <(curl -Ls https://raw.githubusercontent.com/WikiPanel/gost/main/gost.sh) <<'EOF'
1
10.10.10.1
1
443,8443,2087,444,587,465,8951
1
2
EOF
