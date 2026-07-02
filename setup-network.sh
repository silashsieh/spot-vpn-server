#!/usr/bin/env bash
# One-time setup: pick a VPC and open the WireGuard port for instances tagged
# 'openvpn'. Safe to re-run; does nothing if already configured.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_gcloud
info "Project: $PROJECT"

# Already configured?
if load_config && gcloud compute firewall-rules describe "$FIREWALL_RULE" >/dev/null 2>&1; then
  info "Already set up: firewall rule '$FIREWALL_RULE' targets tag '$TAG' on VPC '$NETWORK'."
  info "To reconfigure, delete the rule and .vpn-config, then re-run this script."
  exit 0
fi

# List VPCs and let the user pick one.
NETWORK_LIST="$(gcloud compute networks list --format="value(name)")" \
  || die "Could not list VPCs. If the Compute API is disabled, run: gcloud services enable compute.googleapis.com"
[[ -n "$NETWORK_LIST" ]] || die "Project '$PROJECT' has no VPC networks. Create one first (the 'default' VPC works fine)."
mapfile -t NETWORKS <<< "$NETWORK_LIST"

if [[ ${#NETWORKS[@]} -eq 1 ]]; then
  NETWORK="${NETWORKS[0]}"
  info "Only one VPC in this project — using '$NETWORK'."
else
  echo
  gcloud compute networks list --format="table(name,x_gcloud_subnet_mode)"
  echo
  echo "Which VPC should the VPN server live in?"
  PS3="Choice [1-${#NETWORKS[@]}]: "
  select NETWORK in "${NETWORKS[@]}"; do
    if [[ -n "${NETWORK:-}" ]]; then break; fi
    echo "Invalid choice, try again."
  done
fi

# Create the firewall rule (idempotent; complain if it exists on another VPC).
EXISTING_NET="$(gcloud compute firewall-rules describe "$FIREWALL_RULE" \
  --format="value(network.basename())" 2>/dev/null || true)"
if [[ -n "$EXISTING_NET" && "$EXISTING_NET" != "$NETWORK" ]]; then
  warn "Firewall rule '$FIREWALL_RULE' already exists on VPC '$EXISTING_NET', not '$NETWORK'."
  die "Delete it first if you want to switch VPCs: gcloud compute firewall-rules delete $FIREWALL_RULE"
fi

if [[ -n "$EXISTING_NET" ]]; then
  info "Firewall rule '$FIREWALL_RULE' already exists on VPC '$NETWORK'."
else
  info "Creating firewall rule '$FIREWALL_RULE' (udp:$WG_PORT -> tag '$TAG') on VPC '$NETWORK' ..."
  gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --network="$NETWORK" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules="udp:$WG_PORT" \
    --source-ranges=0.0.0.0/0 \
    --target-tags="$TAG" \
    --description="WireGuard for spot-vpn-server" \
    || die "Firewall rule creation failed. You need the Compute Security Admin (or Editor) role on '$PROJECT'."
fi

save_config
info "Done. VPC choice saved to $CONFIG_FILE (gitignored)."
info "Next: ./create-vpn.sh"
