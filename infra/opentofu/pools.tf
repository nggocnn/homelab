# Resource pools mirror the IP/VMID blocks in README.md. Pools are what the
# per-function firewall security groups and permissions hang off later, so the
# boundaries here are the same ones used for access control.

locals {
  pools = {
    network = {
      comment = "10.10.10.100-119 | Edge and name resolution: cloudflared replicas, Pi-hole, AdGuard, Tailscale"
    }
    access = {
      comment = "10.10.10.120-139 | Human entry points: bastion, remote desktop, browser workspace"
    }
    infrastructure = {
      comment = "10.10.10.140-149 | Shared services: Traefik/Keycloak/ntfy, monitoring, Forgejo, PBS"
    }
    container-platform = {
      comment = "10.10.10.150-169 | Docker hosts and the container registry"
    }
    kubernetes-lab = {
      comment = "10.10.10.170-199 | Hand-built Kubernetes cluster, built on demand and torn down after"
    }
  }
}

resource "proxmox_virtual_environment_pool" "pools" {
  for_each = local.pools

  pool_id = each.key
  comment = each.value.comment
}
