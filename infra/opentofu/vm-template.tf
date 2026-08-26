# Debian 13 cloud-init VM template, one per node.
#
# There is no shared storage, so a template on one node cannot be cloned
# cheaply onto another. Keeping a copy per node makes every clone local.
#
# Template VMIDs sit at 9001-9003, outside the .100-.254 guest range, because
# templates have no IP and so no place in the VMID-equals-last-octet convention.

locals {
  template_vmid = {
    "pve-01" = 9001
    "pve-02" = 9002
    "pve-03" = 9003
  }

  # Canonical URL, not the mirror it redirects to - mirrors rotate. Integrity
  # comes from the pinned SHA-512, so bump both together on a Debian refresh.
  debian_cloud_url    = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  debian_cloud_sha512 = "77429b411b39b43f914dc9d14bf34aa315489a1a12b5429f72e5b483bdda23c65698d33443c85d3f3ad7c3a0828ae60845406d6b99646342554d17abae29c2a3"
}

resource "proxmox_download_file" "debian13_cloud" {
  for_each = var.nodes

  node_name          = each.key
  datastore_id       = "local"
  content_type       = "import"
  file_name          = "debian-13-genericcloud-amd64.qcow2"
  url                = local.debian_cloud_url
  checksum           = local.debian_cloud_sha512
  checksum_algorithm = "sha512"
  overwrite          = false
}

# Cloud-init vendor-data, uploaded per node (snippets live on local storage,
# which is not shared). This is the file that installs qemu-guest-agent.
#
# Vendor-data, not user-data: user-data replaces the user/ssh-key config that
# Proxmox generates from the initialization block, which locks you out.
resource "proxmox_virtual_environment_file" "cloud_init_vendor_data" {
  for_each = var.nodes

  node_name    = each.key
  datastore_id = "local"
  content_type = "snippets"

  source_file {
    path      = "${path.module}/files/cloud-init-vendor-data.yaml"
    file_name = "debian-13-vendor-data.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "debian_template" {
  for_each = var.nodes

  node_name   = each.key
  vm_id       = local.template_vmid[each.key]
  name        = "debian-13-template"
  description = "Debian 13 cloud-init template - clone source for new VMs"
  tags        = ["template", "debian"]

  template = true
  started  = false

  # Cloud images expect a serial console; without it boot output is invisible
  # and some images fail to come up cleanly.
  serial_device {}

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = "local-lvm"
    import_from  = proxmox_download_file.debian13_cloud[each.key].id
    interface    = "scsi0"
    discard      = "on"
    ssd          = true
    size         = 8
  }

  scsi_hardware = "virtio-scsi-single"

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "debian"
      keys     = local.guest_ssh_keys
    }

    vendor_data_file_id = proxmox_virtual_environment_file.cloud_init_vendor_data[each.key].id
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }
}
