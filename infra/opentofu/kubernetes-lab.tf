# Kubernetes lab - blank VMs for a hand-built cluster.
#
# Created stopped and with on_boot disabled. The plan builds this on demand and
# tears it down after: 16 GB resident permanently is a quarter of the cluster's
# usable RAM for something that is only running while being worked on.
#
#   qm start 171 172 175   # when working on the lab
#   qm stop  171 174 175   # when finished
#
# Starts minimal at one control plane and two workers. The plan's 3+3 layout
# and the .52 API VIP come later, once other workloads can be shut down.
#
# These are VMs, not containers: kubelet needs its own kernel view, cgroup
# control and swap handling that an unprivileged LXC cannot give it.

locals {
  k8s_nodes = {
    "k8s-cp-01" = { vm_id = 171, node = "pve-01", cores = 2, memory = 4096, mac = "BC:24:11:00:01:AB" }
    "k8s-w-01"  = { vm_id = 174, node = "pve-02", cores = 2, memory = 6144, mac = "BC:24:11:00:01:AE" }
    "k8s-w-02"  = { vm_id = 175, node = "pve-03", cores = 2, memory = 6144, mac = "BC:24:11:00:01:AF" }
  }
}

resource "proxmox_virtual_environment_vm" "k8s" {
  for_each = local.k8s_nodes

  node_name   = each.value.node
  vm_id       = each.value.vm_id
  name        = each.key
  description = "Kubernetes lab - hand-built, see kubernetes-lab/RUNBOOK.md"
  tags        = ["kubernetes-lab"]
  pool_id     = proxmox_virtual_environment_pool.pools["kubernetes-lab"].pool_id

  started = false
  on_boot = false

  clone {
    vm_id = proxmox_virtual_environment_vm.debian_template[each.value.node].vm_id
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 32
    discard      = "on"
    ssd          = true
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "10.10.10.${each.value.vm_id}/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = ["10.10.10.104"]
    }

    user_account {
      username = "debian"
      keys     = local.guest_ssh_keys
    }

    vendor_data_file_id = proxmox_virtual_environment_file.cloud_init_vendor_data[each.value.node].id
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = each.value.mac
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    # Started/stopped by hand as the lab is used; do not fight that.
    ignore_changes = [started]
  }
}
