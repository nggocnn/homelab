# Monitoring stack: Prometheus + Alertmanager + Grafana, plus pve-exporter.
#
# An LXC rather than a VM: none of these need their own kernel, and RAM is the
# binding constraint on this cluster.
#
# MAC is pinned and derived from the VMID (BC:24:11 is Proxmox's OUI, last
# octet 0x8E = 142). The network enforces MAC/IP binding, so a rebuild that
# issues a fresh MAC would leave the guest silently unreachable.
resource "proxmox_virtual_environment_container" "monitoring" {
  node_name     = "pve-01"
  vm_id         = 142
  pool_id       = proxmox_virtual_environment_pool.pools["infrastructure"].pool_id
  description   = "Prometheus, Alertmanager, Grafana, pve-exporter"
  tags          = ["infrastructure", "monitoring"]
  unprivileged  = true
  start_on_boot = true

  cpu { cores = 2 }
  memory { dedicated = 4096 }

  disk {
    datastore_id = "local-lvm"
    size         = 32
  }

  operating_system {
    template_file_id = proxmox_download_file.debian13_lxc["pve-01"].id
    type             = "debian"
  }

  initialization {
    hostname = "monitoring"

    ip_config {
      ipv4 {
        address = "10.10.10.142/24"
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
    mac_address = "BC:24:11:00:01:8E"
  }

  # nesting=1 is set by Ansible (playbooks/03-guests.yml), not here. Debian's
  # prometheus.service uses systemd hardening built on user namespaces, which
  # fails in an unprivileged container without it - but the API rejects the
  # provider's feature-flag write because it sends the whole struct, and
  # everything except nesting is root@pam-only.
  lifecycle {
    ignore_changes = [features]
  }
}
