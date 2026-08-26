# Homelab Automation — Build Plan & Task List

> **Status: planning.** This is the plan and running checklist for building a fresh, git-managed Proxmox homelab.

---

## Goal

Build an **automated and reproducible end to end** Proxmox VE cluster.

### Guiding rules

- Configuration lives in git; the cluster can be torn down and rebuilt from this repo.
- **VMID = last octet of the guest's IP** (e.g. VMID `104` → `10.10.10.104`), kept in lockstep.
- A single flat `/24` network keeps the VMID/IP convention clean.
- **LXC by default, VM only where required.** RAM is the binding constraint; see
  [Guest type policy](#guest-type-policy).
- **Nothing runs that isn't needed.** Services come up in stages and idle guests get
  shut down. The cluster is not sized for every guest to be resident at once.

---

## The hardware

Three small-form-factor Lenovo ThinkStation P330 Tiny nodes on a flat `10.10.10.0/24` network
(gateway `.1`). Each machine `pve-01`, `pve-02`, `pve-03` at `.11`, `.12`, `.13`.

**pve-01 (`.11`)** — Intel Core **i7-9700**, 8 cores / 8 threads @ 3.0 GHz, **24 GB** RAM, a
**512 GB NVMe** SSD.

**pve-02 (`.12`)** — Intel Core **i7-8700**, 6 cores / 12 threads @ 3.2 GHz, **24 GB** RAM, a
**256 GB NVMe** SSD.

**pve-03 (`.13`)** — Intel Core **i7-8700**, 6 cores / 12 threads @ 3.2 GHz, **24 GB** RAM, a
**256 GB NVMe** SSD.

Total pooled capacity: ~20 CPU cores / 32 threads, ~72 GB RAM, ~1 TB NVMe.

**As built:** PVE **9.2.2**, kernel **7.0.2-6-pve**, all three on ext4 + LVM-thin.
`pve-03` additionally has a wireless interface (`wlo1`, down) — not used, and not
suitable for corosync.

### Known hardware constraints

- **Single NIC per node.** The P330 Tiny has one onboard Intel I219-LM. Corosync shares
  that link with VM traffic, backups, and migrations. See
  [Corosync and the single-NIC ceiling](#corosync-and-the-single-nic-ceiling).
- **I219-LM e1000e hang.** Still present on the 6.17.x / 7.0 kernels shipped with
  PVE 9.x. Requires an offload-disable workaround on every node — applied at
  bootstrap, before the cluster is formed.
- **No UPS.** Accepted risk, and a real one: the nodes run **ext4**, which is less
  forgiving of unclean shutdown than a copy-on-write filesystem. A consumer UPS is
  the cheapest reliability upgrade available and is worth prioritising.
- **NIC is named `nic0`**, not `eno1` — PVE 9 uses the new stable naming scheme.
  `vmbr0` bridges it. Scripts and playbooks must not assume `eno1`.
- **No NAS.** Backups land on local PBS plus a free-tier object store; see
  [Phase 2](#phase-2--cluster-bootstrap-opentofu).

---

## Capacity budget

The plan must fit inside real numbers, so they are stated up front.

| | RAM |
| --- | --- |
| Raw (3 × 24 GB) | 72 GB |
| PVE hypervisor overhead (~2 GB × 3) | −6 GB |
| **Usable for guests** | **~66 GB** |

Storage, as actually installed — ext4 root plus an LVM-thin `local-lvm` pool for guest
disks:

| Node | Disk | root (ext4) | `local-lvm` thin pool | swap |
| --- | --- | --- | --- | --- |
| pve-01 | 477 GB | 96 GB | **349 GB** | 8 GB |
| pve-02 | 238 GB | 69 GB | **141 GB** | 8 GB |
| pve-03 | 238 GB | 69 GB | **141 GB** | 8 GB |

This is why the Kubernetes lab starts minimal and why the forge is Forgejo rather than
GitLab CE — see [Decisions and rationale](#decisions-and-rationale).

---

## Guest type policy

LXC wherever it works. Verified positions:

| Runs as | Services |
| --- | --- |
| **LXC** | cloudflared, Pi-hole, AdGuard, Forgejo, Traefik, Keycloak, ntfy, Homepage, Uptime Kuma, bastion, Prometheus / Grafana / Loki / Alertmanager |
| **LXC + device passthrough** | Tailscale — needs `/dev/net/tun` passed into an unprivileged container |
| **LXC (works) or VM (safer)** | Docker host — `nesting=1` + `keyctl=1` works reliably on PVE 9.x; a VM is the officially supported choice and avoids kernel coupling |
| **VM required** | Proxmox Backup Server (officially unsupported in LXC — relies on systemd, udev, FUSE), Kubernetes nodes (kubelet needs a privileged container and cgroup workarounds; use VMs), remote desktop (GUI) |

---

## Tools

| Area | Tool |
| ------ | ------ |
| Hypervisor | Proxmox VE 9.x |
| Unattended OS install | `proxmox-auto-install-assistant` answer files + first-boot hook |
| Host storage | ext4 root + LVM-thin (`local-lvm`) for guest disks |
| Provisioning (guests, pools, firewall, backups) | OpenTofu + `bpg/proxmox` provider |
| Host & guest configuration | Ansible |
| Post-install helpers | Community Proxmox VE helper scripts — <https://community-scripts.org/> |
| Secrets | SOPS + age (key `pve.nggocnn.io`) |
| App runtime | Docker + Docker Compose |
| Remote access | Cloudflare Tunnel (cloudflared) + Tailscale |
| DNS + ad-block | Pi-hole → AdGuard → public upstream (chained, see Phase 4) |
| Reverse proxy / internal routing | Traefik |
| Identity / SSO | Keycloak (OIDC for the Proxmox UI + apps; `root@pam` stays break-glass) |
| Monitoring & logs | Prometheus, Grafana, Loki, Alertmanager, Uptime Kuma, Pulse |
| Host sensors (temp/fan/power) | lm-sensors + node_exporter `hwmon` (temps/fans) & `rapl` (power) collectors |
| Dashboard | Homepage |
| Source, registry & CI/CD | Forgejo — Git SCM + Container Registry + Forgejo Actions runners, mirrored to GitHub; Renovate for update PRs |
| Notifications | ntfy + Telegram bot |
| Backup | Proxmox Backup Server (VM) + restic/rclone to object storage |
| Kubernetes lab | Hand-built cluster, fully manual (Cilium CNI); Ansible automation planned later |

---

## Conventions & target layout

**VMID = IP last octet.** VMIDs 100–999999999 are legal and LXC and VMs share one
namespace, so the convention holds across both guest types.

Reserved `.1`–`.99`: `.1` gateway · `.11`–`.13` nodes · `.50` reserved for a future DNS
VIP (not used yet) · `.51` proxy/ingress · `.52` reserved for a future k8s API VIP ·
`.60`–`.99` client DHCP.

Guests live in `.100`–`.254`, grouped into function blocks and Proxmox resource pools:

| Block | Pool | What lives here |
| ------- | ------ | ----------------- |
| `.100–.119` | `network` | cloudflared replicas `101/102/103`, Pi-hole `104`, AdGuard `105`, Tailscale `106` |
| `.120–.139` | `access` | bastion `120`, remote desktop `121`, browser workspace `122` |
| `.140–.149` | `infrastructure` | svc-core (Traefik/Keycloak/Homepage/ntfy) `141`, monitoring `142`, Forgejo `143`, PBS `148` |
| `.150–.169` | `container-platform` | Docker host `151`, extra hosts `152+` |
| `.170–.199` | `kubernetes-lab` | control plane `171`, workers `174–175` at first; `172/173/176` reserved for scale-up |
| `.200–.249` | spare | ad-hoc experiments / restore drills / playground |

---

## Working with this repo

    infra/ansible/                    ansible-core 2.21 + community.proxmox
      playbooks/00-host.yml           host config - idempotent, safe to re-run
      playbooks/01-cluster.yml        cluster formation - guarded, no-op once formed
      playbooks/02-access.yml         automation SSH user + PVE API token
      playbooks/03-guests.yml         guest config the API token may not do
      playbooks/10-guest-base.yml     update/upgrade + curl in every container
      playbooks/11-cloudflared.yml    cloudflared from Cloudflare's apt repo
      playbooks/12-tailscale.yml      tailscale subnet router (needs auth key)
      playbooks/13-adguard.yml        AdGuard Home - upstream resolver
      playbooks/14-pihole.yml         Pi-hole - client-facing resolver
      playbooks/15-pbs.yml            Proxmox Backup Server
      playbooks/16-pbs-access.yml     PBS backup token + TLS fingerprint
      playbooks/17-tailscale-hosts.yml  Tailscale on the hypervisors (out-of-band)
    infra/opentofu/
      pools.tf  templates.tf  containers.tf  vm-template.tf  pbs.tf  backup.tf
      ./tofu.sh init|plan|apply       wrapper: injects SOPS creds + state encryption
    secrets/tofu.sops.yaml            age-encrypted; see Secrets below
    secrets/dns.sops.yaml             Pi-hole / AdGuard admin credentials
    secrets/pbs.sops.yaml             PBS token + TLS fingerprint

Tooling is local and unprivileged: `.venv/` for Ansible, `~/.local/bin` for
`tofu`, `sops` and `age`. Nothing needed root on the workstation.

    .venv/bin/ansible-playbook playbooks/00-host.yml --check --diff
    cd infra/opentofu && ./tofu.sh plan

---

## Task list

### Phase 0 — Node bootstrap

Proxmox has been installed by hand on all three nodes. The steps below bring those
manual installs up to a known state and get the cluster formed. The unattended
installer (Phase 0b) is a later experiment that replaces the manual step for the
*next* rebuild.

- [x] **Install Proxmox VE** on each node (done manually).
- [x] **Post-install tune-up** via the community *Proxmox VE Post Install* helper
      (<https://community-scripts.org/>): disable the enterprise APT repo, enable
      no-subscription, remove the subscription-nag message, and run a full package
      update — on all three nodes.
- [x] **Apply the I219-LM e1000e fix on every node** *(before forming the cluster)*.
      A `systemd` oneshot disabling TSO/GSO/GRO on the onboard NIC. A NIC hang while
      corosync is running does not look like a dropped download — it looks like node
      loss. Also captured in the Ansible `pve-host` role so it survives upgrades.
- [x] **Verify time sync** (chrony) on all three nodes. Corosync, certificates and
      TOTP all depend on agreed time.
- [x] **Seed SSH access**: add your public key to each node by hand and verify
      key-only login works. This is the last manual credential step.
- [x] **Form the cluster**: create it on `pve-01`, then join `pve-02` and `pve-03`
      (`pve`). Node names are immutable after join — confirm `pve-01/02/03` is final.
- [x] **Tailscale on the hosts** (not just a guest) — `tailscale up` with interactive
      login. This is the out-of-band path that makes the Phase 2 firewall work safe.
- [ ] **Cloudflare Tunnel**: create **one named tunnel** and its token in the
      Cloudflare dashboard. Three cloudflared instances will run as *replicas of that
      one tunnel*, not three separate tunnels.

### Phase 0b — Unattended install *(experiment, for the next rebuild)*

Not needed now that the nodes are installed, but this is what makes "rebuild from
this repo" literally true. Build it once and the next reinstall is a USB boot.

- [ ] Write `infra/bootstrap/answer-pve-0{1,2,3}.toml` (TOML: keyboard, country, fqdn,
      timezone, hashed root password, SSH keys, static `network`, `disk-setup`).
      Use `filesystem = "ext4"` to reproduce the current layout.
- [ ] Add a `[first-boot]` hook script (PVE 8.3+) to carry the I219-LM fix, the
      `/etc/hosts` entry and chrony, so a fresh node is correct from its first boot.
- [ ] `proxmox-auto-install-assistant validate-answer` in CI on every change.
- [ ] `prepare-iso --fetch-from iso --on-first-boot ...` to produce three bootable ISOs.
- [ ] Point `dns =` at the **gateway `.1`**, never at a guest resolver — the nodes must
      resolve before any guest exists.

### Phase 1 — Automation groundwork

- [x] Scaffold the repo (`infra/`, `config/`, `apps/`, `kubernetes-lab/`, `secrets/`, `docs/`).
- [x] Add `.gitignore` and set up **SOPS + age**. See [Secrets](#secrets) for where the
      private key lives.
- [x] Create a **least-privilege `automation@pve`** API token; store it via SOPS.
- [x] Create a dedicated **automation SSH user with passwordless `sudo` on all three
      nodes**. The `bpg/proxmox` provider needs SSH for file uploads (ISOs, snippets,
      cloud-init user-data), and some operations reject API-token auth outright
      regardless of role. A token alone is not sufficient.
- [x] Configure OpenTofu with the `bpg/proxmox` provider and **native state encryption**
      (OpenTofu 1.7+ — no remote backend required just to keep state safe).
- [x] Build the Ansible **`pve-host`** role (idempotent): keep repos/nag fixed after
      upgrades, template **`/etc/hosts` with each node's name and FQDN**, set the CPU
      governor for power saving, apply the **I219-LM NIC fix**, configure chrony,
      distribute SSH keys, `zpool set autotrim=on`, and enable unattended security
      upgrades.

### Phase 2 — Cluster bootstrap (OpenTofu)

- [x] Create the resource pools.
- [ ] Enable the datacenter **firewall** safely (allow established + management, then
      default-drop) with per-pool security groups. **Rollback path first**: Tailscale on
      the hosts, plus `pve-firewall stop` from the physical console.
- [ ] Configure **ACME** wildcard certs (Let's Encrypt DNS-01 via Cloudflare) for the
      node UIs.
- [ ] Set up **`pve-exporter`** feeding Prometheus.
- [x] Configure **backups**: scheduled `vzdump` to a **PBS VM on `pve-01`**, plus
      restic/rclone of *configs and small state* to a free-tier object store (B2 / R2).
      Full VM images stay local. The local copy dies with `pve-01` — the offsite leg is
      not optional.
- [x] Build a **cloud-init VM template** and an LXC template baseline as clone sources.
      Debian 13 genericcloud, one template per node (9001-9003) since local storage
      is not shared. Cloud-init user-data installs `qemu-guest-agent` — without it
      `vzdump` cannot fsfreeze and backups are only crash-consistent.

### Phase 3 — Core services

- [ ] **svc-core LXC** with **Traefik** reverse proxy on the wildcard cert.
- [ ] **Keycloak** for SSO, then wire it as the Proxmox **OIDC** realm. `root@pam`
      remains and is verified working after every OIDC change.
- [ ] **Monitoring stack**: Prometheus, Grafana, Loki, Alertmanager; Uptime Kuma;
      alerts → **ntfy + Telegram bot**.
- [ ] **Host sensors**: enable node_exporter `hwmon` + `rapl` collectors (temperature,
      fan speed where exposed, power draw); run `sensors-detect` per node. Add an
      **NVMe wearout** alert, and a **`local-lvm` thin-pool usage** alert (see Storage).
- [ ] **Pulse** as an additional Proxmox-native real-time monitoring view.
- [ ] **Homepage** dashboard with Proxmox/Docker/service widgets.
- [ ] Quality-of-life apps: Vaultwarden, browser workspace, remote desktop.

### Phase 4 — DNS & ingress

DNS is a **chain**, not an HA pair: clients → **Pi-hole `.104`** → **AdGuard `.105`** →
public upstream. HA DNS is explicitly out of scope for now; `.50` stays reserved.

- [x] **Pi-hole LXC `.104`**, using AdGuard as its upstream.
- [x] **AdGuard LXC `.105`**, using a public resolver (Quad9 / Cloudflare) upstream.
- [x] **Failure posture: fail soft.** Pi-hole has two upstreams — AdGuard `.105`
      first, then `9.9.9.9`. If AdGuard dies, DNS keeps working and Pi-hole's own
      blocklists still apply; only AdGuard's filtering layer is lost. Verified by
      stopping AdGuard and confirming resolution and blocking both continued.
- [x] Pin Pi-hole and AdGuard to **different physical nodes**.
- [ ] Internal `*.nggocnn.io` records → Traefik at `.51`; external stays on the
      Cloudflare tunnel. **DNS must not sit behind Traefik** — that is a dependency cycle.
- [ ] Move Cloudflare tunnel **routes into git** (Terraform Cloudflare provider + file config).

### Phase 5 — CI/CD & GitOps

- [ ] **Forgejo LXC** `.143`: Git SCM + **Container Registry** + Forgejo Actions runners.
- [ ] **Mirror to GitHub**: Forgejo push-mirroring. GitHub stays the mirror-of-record
      and the bootstrap source — the forge cannot be the only home of the repo that
      deploys the forge.
- [ ] **Pipelines** in `.forgejo/workflows/`: build/publish images to the registry, and
      run OpenTofu plan/apply on pull requests.
- [ ] **Renovate** for dependency update PRs.

> Bootstrap order is deliberate: OpenTofu and Ansible run **from the laptop over SSH**
> first, to stand up the cluster and Forgejo itself. Only once Forgejo is running do the
> same playbooks move into pipelines.

### Phase 6 — Kubernetes lab (independent module)

Built on demand and torn down after. **It does not fit alongside the full service
stack** — see [Capacity budget](#capacity-budget). Kubernetes nodes are VMs, not LXC.

- [ ] **Start minimal**: 1 control plane `.171` + 2 workers `.174/.175`.
- [ ] **Hand-built, fully manual**: a runbook that stands up etcd, the control plane,
      kubelets, PKI, and **Cilium** CNI by hand on blank VMs, with verification scripts.
      Learning-focused.
- [ ] *(Later)* Scale to 3 control planes + 3 workers and add the `.52` API VIP, only
      once other workloads are shut down to free RAM.
- [ ] *(Later)* Automate this same build with **Ansible** so it can be stood up/torn
      down repeatably.

### Phase 7 — Later / optional

- [ ] **Second NIC** (Intel i350-T4 via the P330 Tiny's PCIe riser) for a dedicated
      corosync ring. **Until this exists, PVE HA fencing stays OFF** — see below.
- [ ] External NAS for backups.
- [ ] UPS + NUT.
- [x] **Restore drill passed.** CT 104 restored from PBS into the spare range,
      booted, and served DNS with its gravity database intact (81,395 domains).
      The drill earned its keep: it exposed that `pihole-FTL` came up bound to
      loopback only, which turned out to affect the *live* container too — see
      "Lessons from verification" below. Re-run periodically.

---

## Corosync and the single-NIC ceiling

Corosync is latency-sensitive and currently shares one 1 GbE link with VM traffic,
backups, and migrations. Saturating that link is how three-node clusters end
up fencing and rebooting themselves.

**Current posture:** **PVE HA (automatic fencing and restart) stays off.** With
LVM-thin there is no replication either, so recovery from a node loss means restoring
that node's guests from backup onto a surviving node. Guests are pinned per node and
the RPO is the backup interval.

**To lift this:** add the second NIC and configure a second corosync ring. Only then is
enabling HA fencing a reasonable thing to do.

---

## Storage: ext4 + LVM-thin

All three nodes were installed with the PVE default layout: an **ext4 root** and an
**LVM-thin pool** (`local-lvm`) holding guest disks. This is deliberate — ZFS was
considered and rejected; see [Decisions and rationale](#decisions-and-rationale).

What LVM-thin gives you:

- **Thin provisioning.** Guest disks consume only what they actually write, so you can
  overcommit the pool. `local-lvm` is 349 GB on pve-01 and 141 GB on the other two.
- **Copy-on-write snapshots** on any block device, with no ARC and no RAM overhead.
- Lower RAM cost than ZFS — the whole 24 GB per node is available to guests and the
  hypervisor rather than reserving ~2.4 GB for cache.

What it does not give you, and the consequences:

- **No replication.** `pvesr` is ZFS-only. Guest disks exist on exactly one node, so a
  dead node means restoring its guests from backup onto a survivor. This is the single
  biggest constraint in the whole design and it drives the backup strategy.
- **No checksums.** Silent corruption on a consumer NVMe will not be detected by the
  filesystem. Backups are the only safety net.
- **Migration copies the whole disk.** There is no incremental delta to ship, so moving
  a guest between nodes is a full transfer over the single 1 GbE link.

Operational rules that follow:

- **Watch the thin pool, not just the filesystem.** A thin pool that fills up puts every
  guest on it into read-only or worse, and *overcommitted* pools can fill while the
  guests still think they have space. Alert on `local-lvm` `Data%` well before 100% —
  80% is a sensible trigger. This is the LVM-thin failure mode people get caught by.
- **Enable discard on guest disks** (`discard=on` plus `ssd=1` in the VM/CT config) so
  deletions inside a guest actually return space to the thin pool. Without it, thin
  volumes only ever grow.
- **Run `fstrim` on a schedule** inside guests, and keep `issue_discards` enabled in
  `lvm.conf` so removed LVs release NVMe blocks.
- **Keep snapshots short-lived.** Thin snapshots consume pool space as the origin
  diverges, and a forgotten snapshot is a common way to fill a pool.
- **Watch NVMe wearout.** The PVE disk view reports it; alert on it, since these are
  consumer drives without power-loss protection and there is no UPS.
- **Backups are the recovery mechanism**, not a second line of defence. Their schedule
  *is* the RPO. See [Phase 2](#phase-2--cluster-bootstrap-opentofu).

## Secrets

**SOPS + age**, key name `pve.nggocnn.io`. The `.sops.yaml` in the repo maps path
patterns to the age *public* key, which is safe to commit.

The **age private key** is the root of trust for the whole repo and cannot live in it.
It belongs in two places:

1. **A cloud password manager** (Bitwarden's free tier is sufficient) as a secure note.
   Cloud-hosted is the point — it has to be reachable when the lab is down.
2. **An offline copy.** An age private key is a single short line
   (`AGE-SECRET-KEY-1...`), so printing it or putting it on a USB stick in a drawer is
   genuinely practical.

**Do not store it in Vaultwarden on this cluster.** That is a circular dependency:
cluster down → cannot decrypt → cannot rebuild the cluster.

For consumers, the key is deployed to `~/.config/sops/age/keys.txt` on whatever runs
OpenTofu and Ansible — the laptop today, a Forgejo Actions secret once Phase 5 lands.

Vaultwarden still has a job, but a different one: *human* passwords (app logins, wifi).
That is not what SOPS is for. Dedicated secret managers with dynamic secrets
(OpenBao, Infisical) are deliberately out of scope — unsealing is one more bootstrap
cycle to babysit, and SOPS + age is the right stopping point at this scale.

---

## Decisions and rationale

**LVM-thin over ZFS.** The nodes were installed with the PVE default (ext4 + LVM-thin)
and are staying that way. ZFS was seriously considered, because it is the only path to
`pvesr` replication and would have cut the RPO from the backup interval down to
minutes. It was rejected on cost: switching would have meant reinstalling all three
nodes, which needs physical access to each machine with a USB stick — not the
twenty-minute job it first looked like. The accepted consequence is that **recovery is
restore-from-backup only**, which makes the backup strategy load-bearing rather than
merely prudent. Revisit if a second disk per node ever appears, since a ZFS pool for
guest disks alone would enable replication without touching the root filesystem.

**Forgejo over GitLab CE.** GitLab CE realistically wants 8 GB with CI running; Forgejo
does the same three jobs actually needed here — Git, container registry, CI runners — in
around 512 MB, with push-mirroring to GitHub built in. That is roughly 7 GB back, which
is the difference between a Kubernetes lab that fits and one that does not. GitLab's
real advantage is the full DevOps suite (SAST/DAST, compliance, dependency scanning);
none of that was on the requirements list.

*Caveat on Actions:* Forgejo Actions is deliberately "very similar to, but not
compatible with" GitHub Actions. In practice the YAML is nearly identical and most of
the ecosystem works unchanged — `actions/checkout`, `actions/setup-*`, `actions/cache`,
`docker/build-push-action`. The visible differences are the `.forgejo/workflows/`
directory and the absence of GitHub-hosted runner images. Expect small edits, not a
rewrite.

**Why Traefik and a DNS-01 challenge.** Traefik gives one entry point and one place
where TLS terminates, instead of memorising `IP:port` for twenty services. The DNS-01
challenge matters because HTTP-01 requires Let's Encrypt to reach the server on port 80
from the public internet — which is exactly what the tunnel exists to avoid. DNS-01
proves domain ownership by writing a TXT record through the Cloudflare API, so it works
for purely internal services, and it is the only way to get a **wildcard**
`*.nggocnn.io` certificate. One cert then covers every service, forever, with no
per-service issuance. Skipping Traefik is viable — the cost is `IP:port` everywhere and
no TLS.

**Keycloak does not lock you out.** PVE realms are additive and the `pam` realm cannot
be removed, so `root@pam` always works regardless of what OIDC is doing. Keycloak is an
experiment layered on top, not a replacement.

**One tunnel, three replicas.** Cloudflare Tunnel supports up to 25 replicas of a single
named tunnel sharing one token, with automatic load-balancing and failover. Three
separate tunnels would mean three ingress configs to keep in sync for no benefit.

---

## Lessons from verification

Things that only surfaced because a step was checked rather than assumed:

- **Pi-hole did not survive a reboot.** `dns.listeningMode = BIND` resolves the
  interface address at startup, and `pihole-FTL` starts before the network is
  ready, so after any reboot it bound to loopback only and DNS failed for the
  whole network — silently, with the service reporting `active`. Fixed with
  `listeningMode = LOCAL` plus a systemd drop-in ordering FTL after
  `network-online.target`. AdGuard was checked for the same fault and is immune;
  it retries the bind.
- **A backup that writes is not a backup that restores.** The restore drill is
  the only thing that proved the chain end to end.

---

## Notes carried forward

- The nodes were installed by hand this time. Phase 0b exists so the *next* rebuild is
  unattended and lives in git.
- **No replication.** Guests are pinned per node; recovery from node loss is a restore
  from backup, not a restart elsewhere. The backup schedule is the RPO. Automatic HA
  failover stays off — there is nothing for it to fail over to.
- VMID = IP last octet on a flat `/24`, across both LXC and VMs.
- LXC by default; VM only where verified necessary.
- Nothing runs that is not in use.
- `root@pam` is break-glass. Nodes are always reachable by IP, never only by FQDN.
