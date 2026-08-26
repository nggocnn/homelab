# VMID == last octet of the guest IP, per the convention in README.md.

locals {
  guest_ssh_keys = [trimspace(file(var.guest_ssh_public_key_path))]

  # One named Cloudflare tunnel, three replicas - one per node, so losing a
  # node loses one ingress point rather than all of them. Cloudflare
  # load-balances across replicas automatically.
  cloudflared = {
    "cloudflared-01" = { vm_id = 101, node = "pve-01" }
    "cloudflared-02" = { vm_id = 102, node = "pve-02" }
    "cloudflared-03" = { vm_id = 103, node = "pve-03" }
  }
}

resource "proxmox_virtual_environment_container" "cloudflared" {
  for_each = local.cloudflared

  node_name     = each.value.node
  vm_id         = each.value.vm_id
  pool_id       = proxmox_virtual_environment_pool.pools["network"].pool_id
  description   = "Cloudflare Tunnel replica"
  tags          = ["network", "cloudflared"]
  unprivileged  = true
  start_on_boot = true

  cpu { cores = 1 }
  memory { dedicated = 512 }

  disk {
    datastore_id = "local-lvm"
    size         = 4
  }

  operating_system {
    template_file_id = proxmox_download_file.debian13_lxc[each.value.node].id
    type             = "debian"
  }

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = "10.10.10.${each.value.vm_id}/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = [var.gateway]
    }

    user_account {
      keys = local.guest_ssh_keys
    }
  }

  network_interface {
    name   = "veth0"
    bridge = "vmbr0"
  }

  # /dev/net/tun is attached by Ansible (see comment above). Without this,
  # every plan wants to strip it back off - and cannot, because removing it
  # is also root@pam-only.
  lifecycle {
    ignore_changes = [device_passthrough]
  }
}

# Tailscale needs /dev/net/tun, which an unprivileged container does not get by
# default. PVE restricts device passthrough to root@pam, and the automation API
# token deliberately is not that -- so the device is attached by Ansible
# (playbooks/03-guests.yml) over the root SSH channel instead.
#
# The alternative was storing the root@pam password in SOPS to use a second
# provider alias. Not worth introducing the highest-blast-radius credential in
# the repo for one config line. Trade-off: if this container is ever recreated,
# re-run 03-guests.yml to reattach the device.
resource "proxmox_virtual_environment_container" "tailscale" {
  node_name     = "pve-01"
  vm_id         = 106
  pool_id       = proxmox_virtual_environment_pool.pools["network"].pool_id
  description   = "Tailscale subnet router"
  tags          = ["network", "tailscale"]
  unprivileged  = true
  start_on_boot = true

  cpu { cores = 1 }
  memory { dedicated = 512 }

  disk {
    datastore_id = "local-lvm"
    size         = 4
  }

  operating_system {
    template_file_id = proxmox_download_file.debian13_lxc["pve-01"].id
    type             = "debian"
  }

  initialization {
    hostname = "tailscale"

    ip_config {
      ipv4 {
        address = "10.10.10.106/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = [var.gateway]
    }

    user_account {
      keys = local.guest_ssh_keys
    }
  }

  network_interface {
    name   = "veth0"
    bridge = "vmbr0"
  }

  # /dev/net/tun is attached by Ansible (see comment above). Without this,
  # every plan wants to strip it back off - and cannot, because removing it
  # is also root@pam-only.
  lifecycle {
    ignore_changes = [device_passthrough]
  }
}

# DNS chain: clients -> Pi-hole (.104) -> AdGuard (.105) -> public upstream.
# Pinned to different nodes so one dead node cannot take out both halves.
resource "proxmox_virtual_environment_container" "pihole" {
  node_name     = "pve-02"
  vm_id         = 104
  pool_id       = proxmox_virtual_environment_pool.pools["network"].pool_id
  description   = "Pi-hole - client-facing resolver and ad-blocker"
  tags          = ["network", "dns", "pihole"]
  unprivileged  = true
  start_on_boot = true

  cpu { cores = 1 }
  memory { dedicated = 1024 }

  disk {
    datastore_id = "local-lvm"
    size         = 8
  }

  operating_system {
    template_file_id = proxmox_download_file.debian13_lxc["pve-02"].id
    type             = "debian"
  }

  initialization {
    hostname = "pihole"

    ip_config {
      ipv4 {
        address = "10.10.10.104/24"
        gateway = var.gateway
      }
    }

    # Points at the gateway, not at itself - a resolver that depends on its own
    # service cannot recover from a bad config.
    dns {
      servers = [var.gateway]
    }

    user_account {
      keys = local.guest_ssh_keys
    }
  }

  network_interface {
    name   = "veth0"
    bridge = "vmbr0"
  }
}

resource "proxmox_virtual_environment_container" "adguard" {
  node_name     = "pve-03"
  vm_id         = 105
  pool_id       = proxmox_virtual_environment_pool.pools["network"].pool_id
  description   = "AdGuard Home - upstream resolver for Pi-hole"
  tags          = ["network", "dns", "adguard"]
  unprivileged  = true
  start_on_boot = true

  cpu { cores = 1 }
  memory { dedicated = 1024 }

  disk {
    datastore_id = "local-lvm"
    size         = 8
  }

  operating_system {
    template_file_id = proxmox_download_file.debian13_lxc["pve-03"].id
    type             = "debian"
  }

  initialization {
    hostname = "adguard"

    ip_config {
      ipv4 {
        address = "10.10.10.105/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = [var.gateway]
    }

    user_account {
      keys = local.guest_ssh_keys
    }
  }

  network_interface {
    name   = "veth0"
    bridge = "vmbr0"
  }
}
