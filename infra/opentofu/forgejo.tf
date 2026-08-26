# Forgejo: Git SCM + container registry + Actions runners.
#
# Chosen over GitLab CE because it does those three jobs in roughly 512 MB
# rather than 8 GB - see "Decisions and rationale" in README.md. On pve-03 to
# spread load: pve-01 already carries PBS and the monitoring stack.
resource "proxmox_virtual_environment_container" "forgejo" {
  node_name     = "pve-03"
  vm_id         = 143
  pool_id       = proxmox_virtual_environment_pool.pools["infrastructure"].pool_id
  description   = "Forgejo: git, container registry, CI"
  tags          = ["infrastructure", "forgejo", "git"]
  unprivileged  = true
  start_on_boot = true

  cpu { cores = 2 }
  memory { dedicated = 2048 }

  # Roomier than the other service containers: this holds git repositories and
  # a container registry, both of which grow.
  disk {
    datastore_id = "local-lvm"
    size         = 32
  }

  operating_system {
    template_file_id = proxmox_download_file.debian13_lxc["pve-03"].id
    type             = "debian"
  }

  initialization {
    hostname = "forgejo"

    ip_config {
      ipv4 {
        address = "10.10.10.143/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = ["10.10.10.104"]
    }

    user_account {
      keys = local.guest_ssh_keys
    }
  }

  network_interface {
    name        = "veth0"
    bridge      = "vmbr0"
    mac_address = "BC:24:11:00:01:8F"
  }

  lifecycle {
    ignore_changes = [features]
  }
}
