# LXC template, downloaded to every node ("local" is per-node, not shared).
#
# download.proxmox.com does not serve this path over HTTPS, so integrity comes
# from the SHA-512 published in Proxmox's signed appliance index
# (/var/lib/pve-manager/apl-info/download.proxmox.com-sha512sum) rather than
# from the transport.
resource "proxmox_download_file" "debian13_lxc" {
  for_each = var.nodes

  node_name          = each.key
  datastore_id       = "local"
  content_type       = "vztmpl"
  file_name          = "debian-13-standard_13.6-1_amd64.tar.zst"
  url                = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
  checksum           = "4c0c27ca6ceab5ef0b84db57825a00f26157ef1854bafe97297813e1cbe8ecb8cc9c453cab6b3b0efe1ba193a50c47ece1e41d950e411b8730b835b71e9e754b"
  checksum_algorithm = "sha512"
  overwrite          = false
}
