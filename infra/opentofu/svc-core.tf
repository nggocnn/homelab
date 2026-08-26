# svc-core: the shared-services container. ntfy now; Traefik, Keycloak and
# Homepage land here later (Phase 3).
#
# MAC pinned and derived from the VMID (0x8D = 141) - the network enforces
# MAC/IP binding, so a rebuild with a fresh MAC would go silently unreachable.
resource "proxmox_virtual_environment_container" "svc_core" {
  node_name     = "pve-02"
  vm_id         = 141
  pool_id       = proxmox_virtual_environment_pool.pools["infrastructure"].pool_id
  description   = "svc-core: ntfy, later Traefik/Keycloak/Homepage"
  tags          = ["infrastructure", "svc-core"]
  unprivileged  = true
  start_on_boot = true

  cpu { cores = 2 }
  memory { dedicated = 2048 }

  disk {
    datastore_id = "local-lvm"
    size         = 16
  }

  operating_system {
    template_file_id = proxmox_download_file.debian13_lxc["pve-02"].id
    type             = "debian"
  }

  initialization {
    hostname = "svc-core"

    ip_config {
      ipv4 {
        address = "10.10.10.141/24"
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
    mac_address = "BC:24:11:00:01:8D"
  }

  # nesting is set by Ansible - see monitoring.tf for why.
  lifecycle {
    ignore_changes = [features]
  }
}
