#!/usr/bin/env bash
# Delete the VPN VM and every local artifact. Idempotent — safe to re-run.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_gcloud
info "Project: $PROJECT"

# Collect targets: the tracked instance, or (if state is lost) a label scan.
TARGETS=()
if [[ -f "$STATE_FILE" ]]; then
  load_state
  TARGETS+=("$INSTANCE $ZONE")
else
  warn "No .vpn-state file — scanning for instances labeled ${LABEL_KEY}=${LABEL_VALUE} ..."
  while read -r NAME ZONE_SHORT; do
    if [[ -n "$NAME" ]]; then
      TARGETS+=("$NAME $ZONE_SHORT")
    fi
  done < <(gcloud compute instances list \
    --filter="labels.${LABEL_KEY}=${LABEL_VALUE}" --format="value(name,zone.basename())")
  if [[ ${#TARGETS[@]} -gt 0 ]]; then
    warn "Untracked spot-vpn instances found:"
    printf '  %s\n' "${TARGETS[@]}" >&2
    read -rp "Delete them? [y/N]: " ANS
    [[ "$ANS" =~ ^[Yy]$ ]] || die "Aborted — nothing deleted."
  fi
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  info "Nothing to destroy."
  rm -f "$CLIENT_CONF" "$STATE_FILE"
  exit 0
fi

for TARGET in "${TARGETS[@]}"; do
  read -r NAME ZONE_SHORT <<< "$TARGET"
  if gcloud compute instances describe "$NAME" --zone "$ZONE_SHORT" >/dev/null 2>&1; then
    info "Deleting instance '$NAME' (zone $ZONE_SHORT) — the boot disk auto-deletes with it ..."
    gcloud compute instances delete "$NAME" --zone "$ZONE_SHORT" --quiet
  else
    info "Instance '$NAME' already gone (Spot preemption self-deletes it)."
  fi
done

# Leftover audit — everything here should come back empty.
LEFT_INSTANCES="$(gcloud compute instances list \
  --filter="labels.${LABEL_KEY}=${LABEL_VALUE}" --format="value(name,zone.basename())")"
LEFT_DISKS="$(gcloud compute disks list \
  --filter="name~'^spot-vpn-'" --format="value(name,zone.basename())")"
LEFT_ADDRS="$(gcloud compute addresses list \
  --filter="name~'^spot-vpn'" --format="value(name,region.basename())" 2>/dev/null || true)"
if [[ -n "$LEFT_INSTANCES$LEFT_DISKS$LEFT_ADDRS" ]]; then
  warn "Leftover resources detected — delete these manually:"
  if [[ -n "$LEFT_INSTANCES" ]]; then printf '  instance: %s\n' "$LEFT_INSTANCES" >&2; fi
  if [[ -n "$LEFT_DISKS" ]]; then printf '  disk:     %s\n' "$LEFT_DISKS" >&2; fi
  if [[ -n "$LEFT_ADDRS" ]]; then printf '  address:  %s\n' "$LEFT_ADDRS" >&2; fi
else
  info "Leftover audit clean: no spot-vpn instances, disks, or reserved IPs remain."
fi

rm -f "$STATE_FILE" "$CLIENT_CONF"
info "Local state and client config removed."
info "Kept (free while idle, reused next time): firewall rule '$FIREWALL_RULE' and .vpn-config."
info "To remove the rule too: gcloud compute firewall-rules delete $FIREWALL_RULE"
