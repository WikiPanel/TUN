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
      local: ${KH_IP}
      remote: ${IR_IP}
      addresses:
        - 10.10.10.1/30
      mtu: 1476
EOF

netplan generate
netplan apply

