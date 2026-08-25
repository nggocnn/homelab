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
