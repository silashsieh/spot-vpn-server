#!/usr/bin/env bash
# Shared helpers for spot-vpn-server scripts. Source this file; do not execute it.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STATE_FILE="$REPO_DIR/.vpn-state"
CONFIG_FILE="$REPO_DIR/.vpn-config"
CLIENT_CONF="$REPO_DIR/spot-vpn-client.conf"

TAG="openvpn"
LABEL_KEY="app"
LABEL_VALUE="spot-vpn"
WG_PORT=51820
FIREWALL_RULE="spot-vpn-allow-wireguard"

# Country menu — single source of truth. Add a line to add a country.
# Format: code|region|label
COUNTRIES=(
  "jp|asia-northeast1|Japan (Tokyo)"
  "tw|asia-east1|Taiwan"
  "de|europe-west3|Germany (Frankfurt)"
  "us|us-west1|US (Oregon)"
)

info() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

require_gcloud() {
  command -v gcloud >/dev/null 2>&1 \
    || die "gcloud not found. Run these scripts inside GCP Cloud Shell (https://shell.cloud.google.com)."
  PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
    die "No GCP project selected. Run: gcloud config set project <PROJECT_ID>"
  fi
}

# Both files are plain KEY=VALUE, safe to source. Return 1 if absent so callers
# can branch with `if load_config; then ...`.
load_config() {
  # shellcheck source=/dev/null
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
}

load_state() {
  # shellcheck source=/dev/null
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
}

save_config() {
  echo "NETWORK=$NETWORK" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

save_state() {
  cat > "$STATE_FILE" <<EOF
PROJECT=$PROJECT
INSTANCE=$INSTANCE
ZONE=$ZONE
REGION=$REGION
IP=$IP
CREATED_AT=$CREATED_AT
EOF
  chmod 600 "$STATE_FILE"
}
