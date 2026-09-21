# Ansible — host convergence and cluster formation

`infra/node` gets a node installed and reachable. This directory owns it from then on.

`first-boot.sh` runs **exactly once**. Then, nothing manages the NIC workaround,
the repo configuration, the subscription-nag patch or `/etc/hosts` — and all of them drift.
A `proxmox-widget-toolkit` upgrade restores the nag; a PVE upgrade can restore the enterprise repo;
a driver reset or link renegotiation undoes the NIC offload and EEE settings without any log.

So `pve_host` re-asserts all of it, every run, converging on **the same paths and markers
`first-boot.sh` uses** so there is one mechanism per concern rather than two fighting.

---

## Setup

```bash
sudo apt install -y ansible               # 13.1.0: ansible-core 2.20.1 + bundled collections
sudo apt install -y python3-paramiko      # the bastion's proxmox_pct_remote connection needs it
cd infra/ansible
ansible-galaxy collection install -r requirements.yml   # into ./collections (gitignored)
ansible pve -m ping                       # expect 3 × SUCCESS
```

`requirements.yml` pins `ansible.posix >= 2.2.2`. The apt package's 2.1.0 prints a `to_native` deprecation warning.

Connection details come from `inventory/group_vars/pve.yml`: `root` over SSH with `~/.ssh/<key>`.

---

## Playbooks

| Playbook | What it does |
| --- | --- |
| `playbooks/00-host.yml` | Makes every first-boot setting permanent. Idempotent — a second run must report `changed=0`. |
| `playbooks/01-cluster.yml` | Forms the cluster **`pve`**, created on **`pve-01`**. No-op once formed. |
| `playbooks/02-images.yml` | Puts `pve_lxc_templates` and `pve_isos` on every node's `local` storage — downloaded on the node, or pushed from local machine with `src:`. Additive, never deletes. |
| `playbooks/03-lxc.yml` | Creates the `lxc` inventory hosts on their `lxc_node` (create-only), trusts their SSH host keys, then the `guest_ssh` role: root keys and key-only sshd (`guest_ssh_harden: false` to turn off). |
| `playbooks/04-vip.yml` | `pve_vip` (`10.10.10.50`) floating across the three nodes, so the web UI and the API have one address. Each node's `pveproxy` certificate is reissued from the cluster CA carrying that name. |
| `playbooks/10-cloudflared.yml` | `apt_packages` (base + extras, `-e apt_upgrade=true` to upgrade), then cloudflared on `cloudflared-01..03`. Tunnel token added by hand. |
| `playbooks/11-tailscale.yml` | `apt_packages`, then Tailscale on `tailscale-01..03`, each advertising `pve_subnet_cidr` once logged in (`tailscale up` by hand, re-run, approve each device's route in the admin console). Tailscale routes through one of them at a time and fails over to another. |
| `playbooks/12-bastion.yml` | `bastion-01`: console user `nggocnn` (password, sudo) with the container key and an `~/.ssh/config` for every container. No node access. Re-run after adding a container — `pve_lxc` seeds root's keys at create time only. |
| `playbooks/13-dns.yml` | `dns-01..03`: Pi-hole on `:53` with AdGuard on `127.0.0.1:5353` as its only upstream, and keepalived floating `dns_vip` (`10.10.10.51`) across the three. Config comes from Ansible - **a change made in either web UI is overwritten on the next run**. |
| `playbooks/14-dns-clients.yml` | Points the nodes (`pvesh`) and the containers (`pct set`) at `lxc_resolvers`. Last, because creation uses the gateway - on a first build `dns_vip` does not exist yet. A container applies it on its next start. |

```bash
ansible-playbook playbooks/00-host.yml --check --diff     # read the diff first
ansible-playbook playbooks/00-host.yml                    # first run
ansible-playbook playbooks/00-host.yml                    # re-run: changed=0
ansible-playbook playbooks/01-cluster.yml
ansible-playbook playbooks/02-images.yml
ansible-playbook playbooks/03-lxc.yml
ansible-playbook playbooks/04-vip.yml
ansible-playbook playbooks/10-cloudflared.yml
export TS_API_KEY=tskey-api-...                            # optional, see below
ansible-playbook playbooks/11-tailscale.yml
mkpasswd -m yescrypt > bastion-password.hash              # bastion user's password, gitignored
ansible-playbook playbooks/12-bastion.yml
(umask 077; mkpasswd -m bcrypt -R 10 > adguard-password.hash)   # both gitignored
(umask 077; read -rsp 'Pi-hole password: ' p && printf '%s' "$p" > pihole-password; unset p)
ansible-playbook playbooks/13-dns.yml
ansible-playbook playbooks/14-dns-clients.yml
```

### Cluster VIP

`10.10.10.50` floats across the three nodes: `https://pve.nggocnn.internal:8006` reaches the
cluster whichever node is up. Proxmox has no management address of its own and needs none to be
cluster-wide — `pveproxy` forwards API calls, the node shell and noVNC to whichever node owns the
resource, and the session cookie is signed cluster-wide, so a session survives the address moving.

The web UI and the API only. SSH keeps using per-node names, because host keys differ per node.

The browser tab reads `pve`, not whichever node answered - `pve_web_title`, in `pve_host`.

`pve_vip` tracks `pveproxy` **and** corosync quorum: a node outvoted in a partition has `/etc/pve`
read-only and serves a UI that can change nothing, so the VIP leaves it.

Each node's `pveproxy-ssl.pem` is reissued from the cluster CA with the VIP name and address as
extra SANs — `pvecm updatecerts` regenerates `pve-ssl.pem` with a fixed set of names and no way to
add one. Trust the cluster CA in the browser and the warning goes for good:

```bash
ansible pve-01 -m fetch -a 'src=/etc/pve/pve-root-ca.pem dest=~/ flat=yes'
```

Measured at 5/s against `https://10.10.10.50:8006/`, reading `NodeName` out of the response so
each sample records which node answered:

| Event | Outage | Path |
| --- | --- | --- |
| reboot the holder | <= 1.5 s | keepalived shuts down cleanly and adverts priority 0, so the backup promotes at once rather than waiting out three missed adverts |
| `systemctl stop pveproxy`, node up | 6.4 s | check fails twice, priority drops 150 to 90, election runs |
| `systemctl stop corosync`, node up | none | `chk_quorum` fails and the VIP leaves, while pveproxy on the old holder serves right up to the handover |

One dropped sample is 1.5 s at this rate, and the baseline produced one with nothing happening, so
the reboot row is at the probe's floor, not a measurement of it. Preempting back cost nothing
measurable in all three. Exactly one node answered at every sample - no split brain.

The third row is the case a service check alone misses: `pveproxy` never stopped answering on the
partitioned node, and without `chk_quorum` the VIP would have stayed on a node whose `/etc/pve` had
gone read-only.

### DNS

Pi-hole's admin is on `:80`, AdGuard's on `:8080`. Query history is per container and does not
merge, so it lives wherever `dns_vip` has been.

Containers are *created* on `pve_gateway` and *moved* to `dns_vip` by `14-dns-clients.yml`.
That split keeps the playbook order linear: on a first build nothing points at the resolver pair
until step 13 has built it. `lxc_nameserver` is the creation value, `lxc_resolvers` the steady state.

The `dns` group stays on the gateway - it is the service itself - and `tailscale` and
`cloudflared` keep the gateway behind the VIP, so an access path can still reach its control
plane while the pair is down.

```bash
ansible-playbook playbooks/14-dns-clients.yml   # nodes now, containers on their next start
```

### DNS failover

Measured with `keepalived_check_interval: 2`. Probe the DNS VIP from a node at 5/s — exit status,
not output, because `dig +short` prints `communications error` to stdout and a non-empty
result is not a success:

```bash
while :; do dig +time=1 +tries=1 @10.10.10.51 A pve-01.nggocnn.internal >/dev/null 2>&1 \
  && echo "$(date +%s.%N) OK" || echo "$(date +%s.%N) FAIL"; sleep 0.2; done
```

| Event | Outage | Path |
| --- | --- | --- |
| `pct stop` the holder | 2.5 s | keepalived exits, the backup promotes on the missing advert |
| `systemctl stop pihole-FTL`, container still up | 5.9 s | check fails twice, priority drops, election runs |

Stopping each container in turn walks the VIP down the priorities, `dns-01` (150) to `dns-02`
(100) to `dns-03` (50), and starting them again walks it back up by preemption. Exactly one
holder at every sample - no split brain.

The second row is the case plain VRRP misses: the container is healthy, only the resolver is
gone, so nothing but the tracked check notices.

```
Script `chk_pihole` now returning 9
VRRP_Script(chk_pihole) failed (exited with status 9)
(VI_1) Changing effective priority from 150 to 90
(VI_1) Master received advert from 10.10.10.108 with higher priority 100, ours 90
(VI_1) Entering BACKUP STATE
```

90, not 100: `keepalived_check_weight` (-60) has to exceed the 50 gap between neighbouring
priorities. At -50 a failed check only levels the holder with its peer and VRRP breaks the
tie on the higher address, not on health.

The same test at `keepalived_check_interval: 5` measured 12.1 s. The floor is the election
itself, which `advert_int` governs, not the checks.

Optional switches:

```bash
-e pve_allow_reboot=false      # never reboot, just warn that one is pending
-e pve_do_dist_upgrade=true    # apt full-upgrade as part of the run
-e pve_images_throttle=1       # 02-images: one node transferring at a time
--tags nic,repos               # one concern at a time
--limit pve-02                 # one node
```

`TS_API_KEY` (a Tailscale API token, read from the environment and never written to disk)
lets `11-tailscale.yml` approve each router's own subnet routes instead of you clicking
approve in the admin console. Unset, approve by hand.

```bash
-e tailscale_login_with_authkey=true    # also mint a single-use key and log in, no `tailscale up`
-e tailscale_approve_routes=false       # advertise only, approve by hand
```

Drain a router before rebooting its node: withdrawing the route hands over with **no packet
loss**, where losing the container costs ~17 s either way (measured, hard stop and graceful
shutdown alike — tailscaled exiting is not a logout, so the coordination server waits for
the keepalive to lapse).

```bash
# Detached: the command reaches the router through the route it is withdrawing.
ansible tailscale-03 -m shell -a 'nohup sh -c "sleep 3; tailscale set --advertise-routes=" >/dev/null 2>&1 &'
# ... reboot pve-03 ...
ansible-playbook playbooks/11-tailscale.yml --limit tailscale-03   # re-advertises; approval persists
```

---

## What `pve_host` owns

| Tag | File | Enforced state |
| --- | --- | --- |
| `repos` | `repos.yml` | `pve-enterprise` and `ceph` disabled, `pve-no-subscription` enabled. |
| `packages` | `packages.yml` | The same package set `first-boot.sh` installs, through the shared `apt_packages` role. |
| `nic` | `nic.yml` | `/usr/local/sbin/pve-nic-fix`, unit and udev rule. Interfaces are matched **by driver**, never by name. Asserts TSO/GSO/GRO `off` and EEE disabled afterwards. |
| `nag` | `nag.yml` | The `orig_checked_command` patch plus the APT `Post-Invoke` hook that reapplies it after every upgrade. |
| `webtitle` | `webtitle.yml` | The browser tab titled `pve_web_title` instead of the node name, with the same APT `Post-Invoke` hook as the nag. Off when `pve_web_title` is empty. |
| `hosts` | `hostsfile.yml` | `/etc/hosts` templated with all three nodes; asserts `hostname -f`. |
| `time` | `time.yml` | chrony running, and asserts the clock is actually synchronised. |
| `ssh` | `ssh.yml` | Root's authorised keys (additive — never pruned) and key-only login, installed through `sshd -t` validation protecting from a malformed drop-in. |
| `tuning` | `tuning.yml` | `vm.swappiness=10`, journal capped at 1 G. |
| `iommu` | `iommu.yml` | `intel_iommu=on iommu=pt` merged into the bootloader **by whole token**, plus the vfio modules. |
| `power` | `power.yml` | CPU governor `powersave`, EPP `balance_power`, PCI runtime PM (NIC excluded), asserted afterwards. |
| `wol` | `wol.yml` | `/usr/local/sbin/pve-wol`, unit and udev rule arming `wol g` on the uplink, and the uplink MAC registered with `pvenode config set --wakeonlan <MAC>` so `pvenode wakeonlan <node>` works from a peer. |
| `updates` | `updates.yml` | unattended-upgrades, Debian-Security origins only, PVE packages and kernels blacklisted, no automatic reboot. |
| — | `dns.yml` | Search domain and `pve_dns_servers` through `pvesh`. Run by `14-dns-clients.yml`, not `00-host.yml`. |
| `reboot` | `reboot.yml` | Reboots only when the running kernel is older than the installed one, or a requested kernel parameter is not yet in `/proc/cmdline`. |

---

## Cluster formation

`pvecm add` is the one genuinely one-way action: it replaces the joining
node's `/etc/pve`, a node's name is immutable once it is a member.

1. **Preflight**, across all nodes in parallel, before anything mutates — membership, and
   for an already-clustered node that it is in `pve` and not some other cluster; the FQDN;
   the clock; that every node resolves every peer to its inventory address; and that a
   node about to join has **zero** guests.

2. **Formation**, `serial: 1` — `pve-01` runs `pvecm create pve`, then each other node
   joins with `--use_ssh`. Concurrent joins against one primary are unsafe.

3. **Verification**, asked of *every* node, not just the primary: quorate, three members,
   the right cluster name, and `/etc/pve/nodes` matching the inventory. A node can believe
   it is a member while the rest of the cluster disagrees; only asking all of them catches
   that.

4. **Pools**, on `pve-01` only — each `pve_pools` entry created, or its comment corrected. Never deleted.

The formation authorises the joiner's root key on the primary and adds the primary's host key
to the joiner's `known_hosts` first. That second step is load-bearing: `pvecm add
--use_ssh` shells out to `ssh-copy-id`, which refuses an unknown host key — **and `pvecm`
still exits 0**, so without it the join silently does nothing and the failure surfaces
much later as a node that never appeared.
