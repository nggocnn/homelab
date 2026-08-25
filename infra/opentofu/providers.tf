# Credentials come from the environment, injected by ./tofu.sh from
# secrets/tofu.sops.yaml. Nothing sensitive is committed here.
#
#   PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN,
#   PROXMOX_VE_INSECURE, PROXMOX_VE_SSH_USERNAME
provider "proxmox" {
  # The API token cannot do everything: some operations are root@pam-only, and
  # file uploads (ISOs, snippets, cloud-init) go over SSH. Hence the dedicated
  # automation user with passwordless sudo on every node.
  ssh {
    agent       = false
    private_key = file(var.ssh_private_key_path)

    dynamic "node" {
      for_each = var.nodes
      content {
        name    = node.key
        address = node.value
      }
    }
  }
}
