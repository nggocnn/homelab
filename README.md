# homelab

A single-node Proxmox VE cluster, built unattended from a USB stick, plus first boot script.
The node is the one member of cluster `pve`, so adding a node later is a join, not a rebuild.

| Directory | What it does |
| --- | --- |
| [`infra/node`](./infra/node) | Unattended install. Answer files and the first-boot hook that get a node from bare metal to reachable over SSH. Runs once, per node. |
| [`infra/ansible`](./infra/ansible) | Everything after that: host convergence, the cluster `pve`, containers, the VIPs and DNS. Playbooks run in numeric order. |

The split matters: `first-boot.sh` runs exactly once and then nothing owns its work, so a
PVE upgrade quietly undoes parts of it. Ansible takes that ownership.
