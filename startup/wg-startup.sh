#!/bin/bash
# GCE startup script: bring up kernel WireGuard and publish the client config
# through guest attributes. Runs as root on first boot; needs no service
# account (the metadata server authenticates by locality).
set -euo pipefail

WG_NET="10.66.66"
WG_PORT=51820
# GCP VPC MTU is 1460; wg-quick's default of 1420 assumes a 1500 link and
# silently blackholes large packets.
WG_MTU=1380
DNS_SERVER="1.1.1.1"

MD="http://metadata.google.internal/computeMetadata/v1/instance"
GA="$MD/guest-attributes/vpn"

put() { curl -sf -X PUT -H "Metadata-Flavor: Google" --data "$2" "$GA/$1"; }
trap 'put status "error:line-$LINENO" || true' ERR

# Reboot guard: configure only once. Guest attributes persist across reboots.
if [[ -f /etc/wireguard/wg0.conf ]]; then
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard-tools iptables

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl -w net.ipv4.ip_forward=1

umask 077
cd /etc/wireguard
wg genkey | tee server.key | wg pubkey > server.pub
wg genkey | tee client.key | wg pubkey > client.pub

IFACE="$(ip -o -4 route show to default | awk '{print $5}' | head -n1)"
EXT_IP="$(curl -sf -H "Metadata-Flavor: Google" "$MD/network-interfaces/0/access-configs/0/external-ip")"

cat > wg0.conf <<EOF
[Interface]
Address = ${WG_NET}.1/24
ListenPort = ${WG_PORT}
MTU = ${WG_MTU}
PrivateKey = $(cat server.key)
PostUp = iptables -t nat -A POSTROUTING -o ${IFACE} -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${IFACE} -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
PublicKey = $(cat client.pub)
AllowedIPs = ${WG_NET}.2/32
EOF

systemctl enable --now wg-quick@wg0

# Guest attribute values are capped at 512 bytes — keep this config lean.
cat > client.conf <<EOF
[Interface]
PrivateKey = $(cat client.key)
Address = ${WG_NET}.2/32
DNS = ${DNS_SERVER}
MTU = ${WG_MTU}

[Peer]
PublicKey = $(cat server.pub)
Endpoint = ${EXT_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

put client_config "$(base64 -w0 client.conf)"
put status "ready"

# The client private key now exists only in the guest attribute (and on the
# user's device once imported) — keep nothing recoverable on the server, and
# expire the published copy after 30 minutes.
rm -f client.key client.conf
systemd-run --on-active=30min /usr/bin/curl -sf -X PUT \
  -H "Metadata-Flavor: Google" --data "retrieved" "$GA/client_config"
