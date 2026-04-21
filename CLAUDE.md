# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Homecloud on an Intel NUC running Docker stacks managed via Portainer GitOps. Domain: `tlandsberger.de`. All services are reachable externally via a Cloudflare Zero Trust Tunnel and internally via Split-DNS (CoreDNS).

## Common Commands

```bash
# Bootstrap Portainer (initial setup only, before GitOps is configured)
docker compose -f infrastructure/portainer/docker-compose.yml up -d

# Run Ansible playbook on the NUC (idempotent – safe to re-run)
ansible-galaxy collection install -r host/requirements.yml
ansible-playbook host/playbook.yml

# Dry-run the Ansible playbook (shows changes without applying)
ansible-playbook host/playbook.yml --check
```

After a `git push`, Portainer auto-redeploys changed stacks within 60 seconds.

## Architecture

### Access Paths

**External (Internet):** Browser → Cloudflare Edge (Zero Trust, e-mail OTP) → cloudflared tunnel (outbound) → Traefik:8443 → Service

**Internal (LAN):** Browser → CoreDNS (*.tlandsberger.de → NUC LAN-IP) → Traefik:443 → Service

All containers share the external Docker network `proxy`. Traefik discovers services via Docker labels.

### TLS

Traefik fetches Let's Encrypt certificates via DNS challenge using `CF_DNS_API_TOKEN`. Cloudflare mode must be **Full (Strict)**. The cloudflared tunnel backend uses **No TLS Verify** because cloudflared connects via the internal Docker hostname `traefik`, which doesn't match the public certificate.

### CoreDNS Split-DNS

CoreDNS answers all `*.tlandsberger.de` A queries with the NUC's LAN-IP and responds with NOERROR + empty answer for AAAA queries. The AAAA suppression is intentional: without it, the FritzBox (distributed as a secondary DNS via IPv6 RA) would answer AAAA queries with Cloudflare's public IPv6, causing macOS/Linux to prefer IPv6 and bypass the local NUC. All other queries are forwarded to the router. FritzBox must have a DNS-Rebind protection exception for `tlandsberger.de` and must distribute the NUC's IP as the primary DNS server via DHCP.

`systemd-resolved`'s DNS stub listener must be disabled on the NUC host so CoreDNS can bind to port 53 – the Ansible playbook handles this.

### Secrets Management

All per-stack secrets (API tokens, passwords) are entered as environment variables in the Portainer UI and stored in the `portainer_data` Docker volume. They are **not** in this repository.

## Deploying / Updating Stacks

Stack deploy order (only relevant for fresh setup):
1. CoreDNS (then update FritzBox DHCP DNS to NUC IP)
2. cloudflared (creates the `cloudflare` Docker network)
3. Traefik (needs the `cloudflare` network from step 2)
4. All other services

Each stack is added in Portainer via **Stacks → Add stack → Repository** with polling auto-update enabled (60s). For changes: edit the compose file, commit, push – Portainer handles the rest.

## Image Versioning & Renovate

All Docker image tags are pinned to exact versions in the compose files. Renovate Bot (`renovate.json`) opens automated PRs for updates:

- **Patch releases** → auto-merged (always non-critical)
- **Minor releases** for infrastructure (`traefik`, `coredns/coredns`, `cloudflare/cloudflared`, `portainer/portainer-ce`) → require manual approval
- **Minor releases** for all other services → auto-merged
- **Major releases** → always require manual approval

Approval happens via the **"Renovate Dependency Dashboard"** issue in the GitHub repo. The Renovate GitHub App must be installed on the repository.

## Host Ansible Playbook

`host/playbook.yml` is idempotent and covers the complete NUC host setup:
- System updates + unattended upgrades (Sunday 04:00, auto-reboot 04:30 if kernel update)
- systemd-resolved stub listener disabled (required for CoreDNS on port 53)
- Docker installation via official APT repo (packages: docker-ce, docker-ce-cli, containerd.io, buildx, compose)
- Docker `proxy` network creation
- Optional second disk: interactive prompt, ext4, direkt unter `/var/lib/docker` gemountet (transparent für Docker und alle Tools)
- Optional media disk: Automount unter `/mnt/media` (exFAT/NTFS/ext4)
- Portainer auto-update timer: systemd-Timer prüft alle 5 Min. auf Updates (`git pull` + `docker compose up`)

The `Docker` APT origin is included in `host/50unattended-upgrades` so Docker updates automatically.

## Key Design Decisions

- **No open inbound ports at the router** – Cloudflare Tunnel is outbound-only
- **Portainer as GitOps controller** – this repo is the single source of truth for stack configs; direct Portainer UI edits to compose files will be overwritten on next poll
- **Second disk stores all Docker data** – Die zweite Disk wird direkt unter `/var/lib/docker` gemountet; keine Docker-Konfiguration nötig, alle Tools nutzen Standardpfade
- **Traefik dashboard access** requires HTTP BasicAuth (`TRAEFIK_DASHBOARD_AUTH` htpasswd hash) in addition to Cloudflare Access OTP
