# Forgejo Actions runner.
#
# Its own container rather than sharing Forgejo's: CI executes arbitrary code
# from workflows, and that should not sit in the same blast radius as the git
# repositories and the registry it can push to.
#
# Needs nesting AND keyctl for Docker - set by Ansible, since the API allows
# only nesting to be changed by a non-root@pam token.
resource "proxmox_virtual_environment_container" "ci_runner" {
  node_name     = "pve-02"
  vm_id         = 152
  pool_id       = proxmox_virtual_environment_pool.pools["container-platform"].pool_id
  description   = "Forgejo Actions runner (Docker executor)"
  tags          = ["container-platform", "ci", "forgejo"]
  unprivileged  = true
  start_on_boot = true

  cpu { cores = 2 }
  memory { dedicated = 4096 }

  # CI pulls images and builds; this fills faster than a service container.
  disk {
    datastore_id = "local-lvm"
    size         = 32
  }

  operating_system {
    template_file_id = proxmox_download_file.debian13_lxc["pve-02"].id
    type             = "debian"
  }

  initialization {
    hostname = "ci-runner"

    ip_config {
      ipv4 {
        address = "10.10.10.152/24"
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
    mac_address = "BC:24:11:00:01:98"
  }

  lifecycle {
    ignore_changes = [features]
  }
}
