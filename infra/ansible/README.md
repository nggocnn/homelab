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
| `playbooks/10-cloudflared.yml` | `apt_packages` (base + extras, `-e apt_upgrade=true` to upgrade), then cloudflared on `cloudflared-01..03`. Tunnel token added by hand. |
| `playbooks/11-tailscale.yml` | Installs Tailscale on `tailscale-01` and advertises `pve_subnet_cidr` once logged in (`tailscale up` by hand, re-run, approve the route in the admin console). |
| `playbooks/12-bastion.yml` | `bastion-01`: console user `nggocnn` (password, sudo) with the container key and an `~/.ssh/config` for every container. No node access. |

```bash
ansible-playbook playbooks/00-host.yml --check --diff     # read the diff first
ansible-playbook playbooks/00-host.yml                    # first run
ansible-playbook playbooks/00-host.yml                    # re-run: changed=0
ansible-playbook playbooks/01-cluster.yml
ansible-playbook playbooks/02-images.yml
ansible-playbook playbooks/03-lxc.yml
ansible-playbook playbooks/10-cloudflared.yml
ansible-playbook playbooks/11-tailscale.yml
mkpasswd -m yescrypt > bastion-password.hash              # bastion user's password, gitignored
ansible-playbook playbooks/12-bastion.yml
```

Optional switches:

```bash
-e pve_allow_reboot=false      # never reboot, just warn that one is pending
-e pve_do_dist_upgrade=true    # apt full-upgrade as part of the run
-e pve_images_throttle=1       # 02-images: one node transferring at a time
--tags nic,repos               # one concern at a time
--limit pve-02                 # one node
```

---

## What `pve_host` owns

| Tag | File | Enforced state |
| --- | --- | --- |
| `repos` | `repos.yml` | `pve-enterprise` and `ceph` disabled, `pve-no-subscription` enabled. |
| `packages` | `packages.yml` | The same package set `first-boot.sh` installs, through the shared `apt_packages` role. |
| `nic` | `nic.yml` | `/usr/local/sbin/pve-nic-fix`, unit and udev rule. Interfaces are matched **by driver**, never by name. Asserts TSO/GSO/GRO `off` and EEE disabled afterwards. |
| `nag` | `nag.yml` | The `orig_checked_command` patch plus the APT `Post-Invoke` hook that reapplies it after every upgrade. |
| `hosts` | `hostsfile.yml` | `/etc/hosts` templated with all three nodes; asserts `hostname -f`. |
| `time` | `time.yml` | chrony running, and asserts the clock is actually synchronised. |
| `ssh` | `ssh.yml` | Root's authorised keys (additive — never pruned) and key-only login, installed through `sshd -t` validation protecting from a malformed drop-in. |
| `tuning` | `tuning.yml` | `vm.swappiness=10`, journal capped at 1 G. |
| `iommu` | `iommu.yml` | `intel_iommu=on iommu=pt` merged into the bootloader **by whole token**, plus the vfio modules. |
| `power` | `power.yml` | CPU governor `powersave`, asserted afterwards. |
| `wol` | `wol.yml` | `/usr/local/sbin/pve-wol`, unit and udev rule arming `wol g` on the uplink, and the uplink MAC registered with `pvenode config set --wakeonlan <MAC>` so `pvenode wakeonlan <node>` works from a peer. |
| `updates` | `updates.yml` | unattended-upgrades, Debian-Security origins only, PVE packages and kernels blacklisted, no automatic reboot. |
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
