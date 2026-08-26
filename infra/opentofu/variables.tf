variable "nodes" {
  description = "Cluster nodes and their addresses."
  type        = map(string)
  default = {
    "pve-01" = "10.10.10.11"
    "pve-02" = "10.10.10.12"
    "pve-03" = "10.10.10.13"
  }
}

variable "ssh_private_key_path" {
  description = "Private key for the automation SSH user."
  type        = string
  default     = "~/.ssh/automation.nggocnn.io"
}

variable "gateway" {
  description = "Default gateway for the flat /24."
  type        = string
  default     = "10.10.10.1"
}

variable "guest_ssh_public_key_path" {
  description = "Public key authorised for root inside guests."
  type        = string
  default     = "~/.ssh/pve.nggocnn.io.pub"
}

# --- PBS (supplied from SOPS by ./tofu.sh) -----------------------------------
variable "pbs_server" {
  type    = string
  default = ""
}
variable "pbs_datastore" {
  type    = string
  default = ""
}
variable "pbs_auth_id" {
  type    = string
  default = ""
}
variable "pbs_token_secret" {
  type      = string
  default   = ""
  sensitive = true
}
variable "pbs_fingerprint" {
  type    = string
  default = ""
}
