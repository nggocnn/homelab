# Homelab Automation — Build Plan & Task List

> **Status: planning.** This is the plan and running checklist for building a fresh, git-managed Proxmox homelab.

---

## Goal

Build a **automated and reproducible end to end** Proxmox VE cluster.

**Guiding rules**
- Configuration lives in git; the cluster can be torn down and rebuilt from this repo.
- **VMID = last octet of the guest's IP** (e.g. VMID `104` → `10.10.10.104`), kept in lockstep.
- A single flat `/24` network keeps the VMID/IP convention clean.

---

## The hardware

Three small-form-factor Lenovo ThinkStation P330 Tiny nodes on a flat `10.10.10.0/24` network
(gateway `.1`). Each machine`pve-01`, `pve-02`, `pve-03` at `.11`, `.12`, `.13`.

**pve-01 (`.11`)** — Intel Core **i7-9700**, 8 cores / 8 threads @ 3.0 GHz, **24 GB** RAM, a
**512 GB NVMe** SSD.

**pve-02 (`.12`)** — Intel Core **i7-8700**, 6 cores / 12 threads @ 3.2 GHz, **24 GB** RAM, a
**256 GB NVMe** SSD.

**pve-03 (`.13`)** — Intel Core **i7-8700**, 6 cores / 12 threads @ 3.2 GHz, **24 GB** RAM, a
**256 GB NVMe** SSD.

Total pooled capacity: ~20 CPU cores / 32 threads, ~72 GB RAM, ~1 TB NVMe. No shared storage,
so guests are pinned per node and recovery is backup-based rather than live-migration.

---

## Tools

| Area | Tool |
|------|------|
| Hypervisor | Proxmox VE |
| Provisioning (guests, pools, firewall, backups) | OpenTofu + `bpg/proxmox` provider |
| Host & guest configuration | Ansible |
| Post-install helpers | Community Proxmox VE helper scripts — https://community-scripts.org/ |
| Secrets | SOPS + age |
| App runtime | Docker + Docker Compose |
| Remote access | Cloudflare Tunnel (cloudflared) + Tailscale |
| DNS + ad-block (HA) | Pi-hole + AdGuard behind keepalived VIP |
| Reverse proxy / internal routing | Traefik (or Caddy) |
| Identity / SSO | Authentik (OIDC for the Proxmox UI + apps) |
| Monitoring & logs | Prometheus, Grafana, Loki, Alertmanager, InfluxDB, Uptime Kuma |
| Dashboard | Homepage |
| CI/CD & GitOps | Forgejo + Actions, Renovate, Atlantis |
| Notifications | ntfy |
| Backup | Proxmox Backup Server + restic/rclone to object storage |
| Kubernetes lab | Talos Linux + Cilium (automated); hand-built cluster (manual) |
| Optional network appliance | OPNsense |

---

## Conventions & target layout

**VMID = IP last octet.** Reserved `.1`–`.99`: `.1` gateway · `.11`–`.13` nodes · `.50` DNS VIP ·
`.51` proxy/ingress VIP · `.52` k8s API VIP · `.60`–`.99` client DHCP.

Guests live in `.100`–`.254`, grouped into function blocks and Proxmox resource pools:

| Block | Pool | What lives here |
|-------|------|-----------------|
| `.100–.119` | `network` | Cloudflare tunnels `101/102/103`, Pi-hole `104`, AdGuard `105`, Tailscale `106` |
| `.120–.139` | `access` | bastion `120`, remote desktop `121`, browser workspace `122` |
| `.140–.149` | `infrastructure` | svc-core (proxy/SSO/dashboard/ntfy) `141`, monitoring `142`, git+CI `143`, backup `148` |
| `.150–.169` | `container-platform` | Docker host `151`, registry `152`, extra hosts `153+` |
| `.170–.199` | `kubernetes-lab` | Talos control planes `171–173`, Talos workers `174–176`, hand-built lab `181–186` |
| `.200–.249` | spare | ad-hoc experiments / playground |

---

## Task list

### Phase 0 — Manual bootstrap (hands-on, per node)

These steps need interactive input (installer prompts, tokens, device logins), so they are done
by hand once per node. Everything after this is automated.

- [ ] **Install Proxmox VE** on each node (the only manual OS install).
- [ ] **Post-install tune-up** via the community *Proxmox VE Post Install* helper
      (https://community-scripts.org/): disable the enterprise APT repo, enable no-subscription,
      remove the subscription-nag message, and run a full package update — on all three nodes.
- [ ] **Form the cluster**: create it on `pve-01`, then join `pve-02` and `pve-03` (`pvecm`).
- [ ] **Cloudflare Tunnel** for remote access: create the tunnel + token in the Cloudflare
      dashboard, install cloudflared, and confirm ingress reaches the cluster.
- [ ] **Tailscale**: install and `tailscale up` (interactive login) for out-of-band admin access.
- [ ] **Seed SSH access**: add your public key to each node and verify key-only login works.

### Phase 1 — Automation groundwork

- [ ] Scaffold the repo (`infra/`, `config/`, `apps/`, `kubernetes-lab/`, `secrets/`, `docs/`).
- [ ] Add `.gitignore` and set up **SOPS + age** for secrets.
- [ ] Create a **least-privilege `automation@pve`** API token; store it via SOPS.
- [ ] Configure OpenTofu with the `bpg/proxmox` provider and **encrypted state**.
- [ ] Build the Ansible **`pve-host`** role (idempotent): keep repos/nag fixed after upgrades,
      set the CPU governor for power saving, apply the **I219-LM NIC fix on every node**,
      distribute SSH keys, and enable unattended security upgrades.

### Phase 2 — Cluster bootstrap (OpenTofu)

- [ ] Create the five resource pools.
- [ ] Enable the datacenter **firewall** safely (allow established + management, then default-drop)
      with per-pool security groups.
- [ ] Configure **ACME** wildcard certs (Let's Encrypt DNS-01 via Cloudflare) for the node UIs.
- [ ] Set up the **metric server** (PVE → InfluxDB) and `pve-exporter`.
- [ ] Configure **backups**: scheduled `vzdump` + offsite copy (restic/rclone to R2/B2); optional
      Proxmox Backup Server VM on `pve-01`.
- [ ] Build a **cloud-init VM template** as the clone source for new VMs.

### Phase 3 — Core services

- [ ] Docker host + **Traefik** reverse proxy with wildcard cert (internal split-horizon routing).
- [ ] **Authentik** for SSO, then wire it as the Proxmox **OIDC** login (keep root break-glass).
- [ ] **Monitoring stack**: Prometheus, Grafana, Loki, Alertmanager; alerts → **ntfy**; Uptime Kuma.
- [ ] **Homepage** dashboard with Proxmox/Docker/service widgets.
- [ ] Quality-of-life apps: Vaultwarden, browser workspace, remote desktop.

### Phase 4 — DNS & ingress

- [ ] **Pi-hole + AdGuard** as an HA pair behind keepalived **VIP `.50`** (primary + standby).
- [ ] Internal `*.nggocnn.io` records → proxy VIP `.51`; external stays on the Cloudflare tunnel.
- [ ] Move Cloudflare tunnel **routes into git** (Terraform Cloudflare provider + file config).

### Phase 5 — CI/CD & GitOps

- [ ] **Forgejo** (self-hosted git) + Actions runner; migrate this repo to it.
- [ ] **Renovate** for dependency update PRs.
- [ ] **Atlantis** for OpenTofu plan/apply on pull requests.

### Phase 6 — Kubernetes lab (independent module)

- [ ] **Talos** path (automated): OpenTofu boots VMs from the Talos image, machineconfig in git,
      `talosctl bootstrap`, **Cilium** CNI — fully reproducible teardown/rebuild.
- [ ] **Hand-built** path (manual): a runbook that stands up etcd, control plane, kubelets, PKI,
      and CNI by hand on blank VMs, with verification scripts. Learning-focused.

### Phase 7 — Optional

- [ ] SDN VLAN segmentation + **OPNsense** appliance (inter-VLAN firewall + IDS/IPS).
- [ ] Dedicated Proxmox Backup Server with cloud sync.

---

## Notes carried forward

- The only manual OS step is installing Proxmox; interactive items (post-install helper,
  Cloudflare tunnel, Tailscale, first SSH key) are done once by hand, then kept in git/automation.
- No shared storage → guests are pinned per node; recovery is via backups, not live migration.
- VMID = IP last octet on a flat `/24`; VLAN segmentation (Phase 7) would require evolving the rule.
