#!/usr/bin/env bash
# Create a minimal Spot VM running WireGuard and print the client config + QR.
# Machine type can be overridden: MACHINE_TYPE=e2-small ./create-vpn.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_gcloud
info "Project: $PROJECT"

# --- Network config -----------------------------------------------------------
NETWORK=""
load_config || true
if [[ -z "$NETWORK" ]]; then
  warn "No .vpn-config found — ./setup-network.sh has not been run."
  read -rp "Continue using VPC 'default'? [y/N]: " ANS
  [[ "$ANS" =~ ^[Yy]$ ]] || die "Run ./setup-network.sh first."
  NETWORK="default"
fi
if ! gcloud compute firewall-rules describe "$FIREWALL_RULE" >/dev/null 2>&1; then
  warn "Firewall rule '$FIREWALL_RULE' not found — clients will NOT reach the VPN."
  read -rp "Continue anyway (only if you manage firewall rules yourself)? [y/N]: " ANS
  [[ "$ANS" =~ ^[Yy]$ ]] || die "Run ./setup-network.sh first."
fi

# --- Guard against an existing VPN --------------------------------------------
if [[ -f "$STATE_FILE" ]]; then
  load_state
  if gcloud compute instances describe "$INSTANCE" --zone "$ZONE" >/dev/null 2>&1; then
    info "VPN '$INSTANCE' is already running at $IP (zone $ZONE)."
    die "Run ./destroy-vpn.sh first if you want a new one."
  fi
  warn "Stale state: '$INSTANCE' no longer exists (Spot VMs self-delete on preemption). Cleaning up."
  rm -f "$STATE_FILE" "$CLIENT_CONF"
fi
ORPHANS="$(gcloud compute instances list \
  --filter="labels.${LABEL_KEY}=${LABEL_VALUE}" --format="value(name,zone.basename())")"
if [[ -n "$ORPHANS" ]]; then
  warn "Found spot-vpn instances not tracked by .vpn-state:"
  echo "$ORPHANS" >&2
  die "Run ./destroy-vpn.sh to remove them first."
fi

# --- Country menu --------------------------------------------------------------
LABELS=()
for ENTRY in "${COUNTRIES[@]}"; do
  LABELS+=("${ENTRY##*|}")
done
echo "Where should the VPN exit?"
PS3="Choice [1-${#LABELS[@]}]: "
select CHOICE in "${LABELS[@]}"; do
  if [[ -n "${CHOICE:-}" ]]; then break; fi
  echo "Invalid choice, try again."
done
IFS='|' read -r CODE REGION _ <<< "${COUNTRIES[$((REPLY - 1))]}"

INSTANCE="spot-vpn-$CODE"
MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"

# --- Subnet resolution (custom-mode VPCs have no subnet in every region) -------
SUBNET="$(gcloud compute networks subnets list --network="$NETWORK" \
  --regions="$REGION" --format="value(name)" --limit=1 2>/dev/null || true)"
[[ -n "$SUBNET" ]] || die "VPC '$NETWORK' has no subnet in $REGION. Pick another country or create a subnet there."

# --- Create the VM, iterating zones until Spot capacity is found ---------------
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

CREATED=false
for ZONE in $(gcloud compute zones list \
    --filter="region:$REGION AND status=UP" --format="value(name)"); do
  info "Creating Spot VM '$INSTANCE' ($MACHINE_TYPE) in $ZONE ..."
  set +e
  ERR="$(gcloud compute instances create "$INSTANCE" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --provisioning-model=SPOT \
    --instance-termination-action=DELETE \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --boot-disk-size=10GB \
    --boot-disk-type=pd-standard \
    --boot-disk-auto-delete \
    --network="$NETWORK" \
    --subnet="$SUBNET" \
    --network-tier=STANDARD \
    --tags="$TAG" \
    --labels="${LABEL_KEY}=${LABEL_VALUE}" \
    --no-service-account \
    --no-scopes \
    --metadata=enable-guest-attributes=TRUE \
    --metadata-from-file=startup-script="$REPO_DIR/startup/wg-startup.sh" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)" \
    2>&1 >"$TMP_OUT")"
  RC=$?
  set -e
  if [[ $RC -eq 0 ]]; then
    IP="$(<"$TMP_OUT")"
    CREATED=true
    break
  fi
  if grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources' <<< "$ERR"; then
    warn "No Spot capacity in $ZONE — trying the next zone."
    continue
  fi
  echo "$ERR" >&2
  if grep -qi 'network tier' <<< "$ERR"; then
    die "This region rejected the STANDARD network tier — change --network-tier to PREMIUM in create-vpn.sh and retry."
  fi
  die "VM creation failed (not a Spot-capacity issue) — see the error above."
done
if [[ "$CREATED" != true ]]; then
  die "No Spot capacity for $MACHINE_TYPE in any $REGION zone right now. Try another country, retry later, or: MACHINE_TYPE=e2-small ./create-vpn.sh"
fi

# Save state immediately so ./destroy-vpn.sh works even if the wait below fails.
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
save_state
info "VM created — external IP: $IP"

# --- Wait for the startup script to publish the client config ------------------
info "Waiting for WireGuard to come up (typically 60-120 s) ..."
CONF_B64=""
for _ in $(seq 1 72); do
  VAL="$(gcloud compute instances get-guest-attributes "$INSTANCE" --zone "$ZONE" \
    --query-path=vpn/client_config --format="value(value)" 2>/dev/null || true)"
  if [[ -n "$VAL" && "$VAL" != "retrieved" ]]; then
    CONF_B64="$VAL"
    break
  fi
  STATUS="$(gcloud compute instances get-guest-attributes "$INSTANCE" --zone "$ZONE" \
    --query-path=vpn/status --format="value(value)" 2>/dev/null || true)"
  if [[ "$STATUS" == error:* ]]; then
    die "Startup script failed ($STATUS). Inspect: gcloud compute instances get-serial-port-output $INSTANCE --zone $ZONE"
  fi
  sleep 5
done
if [[ -z "$CONF_B64" ]]; then
  die "Timed out waiting for the client config. Inspect: gcloud compute instances get-serial-port-output $INSTANCE --zone $ZONE  (then ./destroy-vpn.sh to clean up)"
fi

base64 -d <<< "$CONF_B64" > "$CLIENT_CONF"
chmod 600 "$CLIENT_CONF"

# --- Hand the config to the user -----------------------------------------------
echo
echo "----- WireGuard client config (saved to $CLIENT_CONF) -----"
cat "$CLIENT_CONF"
echo "------------------------------------------------------------"

if ! command -v qrencode >/dev/null 2>&1; then
  info "Installing qrencode (for the QR code) ..."
  sudo apt-get install -y -qq qrencode >/dev/null 2>&1 || warn "Could not install qrencode — skipping the QR code."
fi
if command -v qrencode >/dev/null 2>&1; then
  echo
  info "Scan with the WireGuard mobile app:"
  qrencode -t ansiutf8 < "$CLIENT_CONF"
fi

echo
info "VPN endpoint:  $IP:$WG_PORT (UDP)"
info "Client config: $CLIENT_CONF (import into any WireGuard client)"
info "This config is fetchable for 30 minutes, then expires from the VM."
warn "Spot VM: Google may preempt it at any time, and it deletes itself. Just re-run ./create-vpn.sh."
warn "Cost: the VM is pennies — network egress (~\$0.05-0.12/GB) is the real cost."
info "When you are done: ./destroy-vpn.sh"
