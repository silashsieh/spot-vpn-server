# spot-vpn-server

Boot a **fully self-controlled WireGuard VPN server** on a minimal GCP Spot VM in ~90 seconds, at a location you choose — and delete it completely when you're done.

For engineers who don't trust commercial VPN providers: the keys are generated on *your* VM inside *your* GCP project, never transit any third party, and the server ceases to exist the moment you're finished with it.

## Quick start

Run everything in [GCP Cloud Shell](https://shell.cloud.google.com) (nothing else is required — no Ansible, no Terraform, no local tooling):

```bash
git clone https://github.com/silashsieh/spot-vpn-server.git
cd spot-vpn-server

./setup-network.sh   # once per project: pick a VPC, open the WireGuard port
./create-vpn.sh      # pick a country, get a client config + QR code
./destroy-vpn.sh     # when you're done: delete the VM, leave nothing behind
```

`create-vpn.sh` ends by printing the WireGuard client config as text **and as a QR code** — scan it with the WireGuard mobile app, or import the saved `spot-vpn-client.conf` into any desktop client, and you're connected.

## What gets created

| Resource | Details |
|---|---|
| 1 Spot VM | `e2-micro`, Debian 12, 10 GB pd-standard disk, ephemeral IP, **no service account**, no ops agent, no extras |
| 1 firewall rule | `spot-vpn-allow-wireguard`: UDP 51820 → instances tagged `openvpn` (created once by `setup-network.sh`, kept across cycles — it's free) |

That's the complete inventory. No static IPs, no snapshots, no images. `destroy-vpn.sh` deletes the VM (the disk auto-deletes with it) and finishes with a leftover audit that verifies nothing remains.

## Locations

| Choice | Region |
|---|---|
| Japan (Tokyo) | `asia-northeast1` |
| Taiwan | `asia-east1` |
| Singapore | `asia-southeast1` |
| Germany (Frankfurt) | `europe-west3` |
| US (Oregon) | `us-west1` |

To add a country, append one line to the `COUNTRIES` array in `lib/common.sh`.

## Cost

- **The VM is pennies.** A Spot `e2-micro` costs roughly US$1.5–2.5/month if left running — fractions of a cent for a few hours. The 10 GB disk adds ~$0.40/month pro-rated.
- **Network egress is the real cost** (~US$0.05–0.12/GB on the Standard tier, which these scripts use because it's ~30% cheaper than Premium). An evening of video streaming outweighs a month of VM time.
- Free-tier note: a **non-Spot** `e2-micro` in `us-west1`/`us-central1`/`us-east1` is [free-tier eligible](https://cloud.google.com/free/docs/free-cloud-features#compute). Spot pricing is usually cheaper anyway for short-lived use, but if you keep a US VPN running long-term, a standard instance may cost $0.
- Need more throughput? `MACHINE_TYPE=e2-small ./create-vpn.sh`

## Spot preemption

Google may reclaim a Spot VM at any time. When that happens the VM **deletes itself** (`--instance-termination-action=DELETE`) — a restart would get a new IP and break your client config anyway. Recovery is simply re-running `./create-vpn.sh` (~90 s); it detects the stale state and cleans up automatically. In practice, preemption of an `e2-micro` is rare over a few hours.

## Security notes

- WireGuard runs in the Debian kernel — fully open source, no licensing, no vendor binary.
- Key pairs are generated on the VM at first boot with `wg genkey`. The client config (containing the client private key) is handed back through GCP [guest attributes](https://cloud.google.com/compute/docs/metadata/manage-guest-attributes), readable only with your own GCP credentials — and it **expires from the VM 30 minutes after boot**; the private key is deleted from the server's disk immediately after publishing.
- The VM runs with **no service account**, so a compromised VPN server has zero GCP API access.
- The only open port is UDP 51820. There is no SSH rule, no admin web UI, no password.
- Client DNS defaults to `1.1.1.1` — change `DNS_SERVER` in `startup/wg-startup.sh` if you prefer another resolver.
- WireGuard is UDP-only with a recognizable protocol signature. On networks that block it (some corporate/censored environments), you'd want OpenVPN over TCP 443 instead — out of scope for this tool.

## Troubleshooting

- **`create-vpn.sh` times out waiting for the config** — inspect the boot log:
  `gcloud compute instances get-serial-port-output spot-vpn-<code> --zone <zone>`
  then `./destroy-vpn.sh` and retry.
- **No Spot capacity** — the script automatically tries every zone in the region; if all are dry, pick another country or retry in a few minutes.
- **Connected but pages don't load** — the configs pin `MTU = 1380` (GCP's VPC MTU is 1460); if you edited that, put it back.
- **Lost `.vpn-state`** (e.g. re-cloned the repo) — both `create-vpn.sh` and `destroy-vpn.sh` find stray instances via the `app=spot-vpn` label.

## Runtime files (gitignored, never commit)

| File | Lifetime |
|---|---|
| `.vpn-config` | VPC choice — persists across create/destroy cycles |
| `.vpn-state` | Current VM info — removed by `destroy-vpn.sh` |
| `spot-vpn-client.conf` | WireGuard client config — removed by `destroy-vpn.sh` |
