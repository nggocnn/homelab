# Proxmox Backup Server.
#
# A VM, not a container: PBS relies on systemd, udev and FUSE in ways that make
# LXC an officially unsupported configuration.
#
# With no ZFS replication in this cluster, backups are the entire recovery
# story - a dead node means restoring its guests elsewhere. That makes this the
# most load-bearing guest here, which is also why its datastore must not be the
# only copy: see the offsite leg in README.md Phase 2.

resource "proxmox_virtual_environment_vm" "pbs" {
  node_name   = "pve-01"
  vm_id       = 148
  name        = "pbs"
  description = "Proxmox Backup Server"
  tags        = ["infrastructure", "backup"]
  pool_id     = proxmox_virtual_environment_pool.pools["infrastructure"].pool_id

  on_boot = true

  clone {
    vm_id = proxmox_virtual_environment_vm.debian_template["pve-01"].vm_id
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  # Root disk, inherited from the template and grown.
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 16
    discard      = "on"
    ssd          = true
  }

  # Separate datastore disk: keeps backup data off the root filesystem, so a
  # full datastore cannot take the OS down with it.
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi1"
    size         = 120
    discard      = "on"
    ssd          = true
    file_format  = "raw"
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "10.10.10.148/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = [var.gateway]
    }

    user_account {
      username = "debian"
      keys     = local.guest_ssh_keys
    }

    vendor_data_file_id = proxmox_virtual_environment_file.cloud_init_vendor_data["pve-01"].id
  }

  # Pinned so a rebuild keeps the same MAC. Without this every `tofu apply`
  # that replaces the VM issues a new one, which breaks MAC/IP binding on the
  # network and makes the guest silently unreachable.
  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = "BC:24:11:82:58:4C"
  }

  operating_system {
    type = "l26"
  }
}
