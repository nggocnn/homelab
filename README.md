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

Total pooled capacity: ~20 CPU cores / 32 threads, ~72 GB RAM, ~1 TB NVMe.

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
| Identity / SSO | Keycloak (OIDC for the Proxmox UI + apps) |
| Monitoring & logs | Prometheus, Grafana, Loki, Alertmanager, InfluxDB, Uptime Kuma, Pulse |
| Host sensors (temp/fan/power) | lm-sensors + node_exporter `hwmon` (temps/fans) & `rapl` (power) collectors |
| Dashboard | Homepage, Homarr |
| Source, registry & CI/CD | GitLab CE — Git SCM + Container Registry + CI/CD runners, mirrored with a GitHub repo; Renovate for update PRs |
| Notifications | ntfy + Telegram bot |
| Backup | Proxmox Backup Server + restic/rclone to object storage |
| Kubernetes lab | Hand-built cluster, fully manual (Cilium CNI); Ansible automation planned later |

---

## Conventions & target layout

**VMID = IP last octet.** Reserved `.1`–`.99`: `.1` gateway · `.11`–`.13` nodes · `.50` DNS VIP ·
`.51` proxy/ingress VIP · `.52` k8s API VIP · `.60`–`.99` client DHCP.

Guests live in `.100`–`.254`, grouped into function blocks and Proxmox resource pools:

| Block | Pool | What lives here |
|-------|------|-----------------|
| `.100–.119` | `network` | Cloudflare tunnels `101/102/103`, Pi-hole `104`, AdGuard `105`, Tailscale `106` |
| `.120–.139` | `access` | bastion `120`, remote desktop `121`, browser workspace `122` |
| `.140–.149` | `infrastructure` | svc-core (proxy/Keycloak/dashboard/ntfy) `141`, monitoring `142`, GitLab `143`, backup `148` |
| `.150–.169` | `container-platform` | Docker host `151`, registry `152`, extra hosts `153+` |
| `.170–.199` | `kubernetes-lab` | hand-built control planes `171–173`, workers `174–176` (manual build) |
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
- [ ] **Keycloak** for SSO, then wire it as the Proxmox **OIDC** login (keep root break-glass).
- [ ] **Monitoring stack**: Prometheus, Grafana, Loki, Alertmanager; Uptime Kuma; alerts → **ntfy + Telegram bot**.
- [ ] **Host sensors**: enable node_exporter `hwmon` + `rapl` collectors (temperature, fan speed where exposed, power draw); run `sensors-detect` per node.
- [ ] **Pulse** as an additional Proxmox-native real-time monitoring view.
- [ ] **Homepage** dashboard with Proxmox/Docker/service widgets; try **Homarr** as an additional option.
- [ ] Quality-of-life apps: Vaultwarden, browser workspace, remote desktop.

### Phase 4 — DNS & ingress

- [ ] **Pi-hole + AdGuard** as an HA pair behind keepalived **VIP `.50`** (primary + standby).
- [ ] Internal `*.nggocnn.io` records → proxy VIP `.51`; external stays on the Cloudflare tunnel.
- [ ] Move Cloudflare tunnel **routes into git** (Terraform Cloudflare provider + file config).

### Phase 5 — CI/CD & GitOps

- [ ] **GitLab CE** on its own VM: Git SCM + **Container Registry** + CI/CD runners; migrate this repo to it.
- [ ] **Mirror with GitHub**: set up pull/push mirroring between the self-hosted GitLab repo and a GitHub repo.
- [ ] **CI/CD pipelines** in GitLab: build/publish images to the registry, and run OpenTofu plan/apply on merge requests.
- [ ] **Renovate** for dependency update PRs (GitLab).

### Phase 6 — Kubernetes lab (independent module)

- [ ] **Hand-built cluster, fully manual**: a runbook that stands up etcd, the control plane,
      kubelets, PKI, and **Cilium** CNI by hand on blank VMs, with verification scripts. Learning-focused.
- [ ] *(Later)* Automate this same build with **Ansible** so it can be stood up/torn down repeatably.

### Phase 7 — Optional

- [ ] Dedicated Proxmox Backup Server

---

## Notes carried forward

- The only manual OS step is installing Proxmox; interactive items (post-install helper,
  Cloudflare tunnel, Tailscale, first SSH key) are done once by hand, then kept in git/automation.
- No shared storage → guests are pinned per node; recovery is via backups, not live migration.
- VMID = IP last octet on a flat `/24`.
- GitLab CE is heavier than a lightweight forge (budget ~4 GB RAM / 2–4 vCPU); give it its own VM.
