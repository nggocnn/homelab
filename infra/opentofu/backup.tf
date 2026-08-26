# PBS as a cluster storage, plus the backup jobs that fill it.
#
# Credentials come from secrets/pbs.sops.yaml, decrypted by ./tofu.sh into
# TF_VAR_* rather than living in state as plaintext literals.

resource "proxmox_storage_pbs" "pbs" {
  id        = "pbs"
  server    = var.pbs_server
  datastore = var.pbs_datastore
  username  = var.pbs_auth_id
  password  = var.pbs_token_secret

  # PBS uses a self-signed certificate; pinning its fingerprint is what makes
  # that safe rather than blind trust.
  fingerprint = var.pbs_fingerprint

  nodes   = keys(var.nodes)
  content = ["backup"]
}

# One nightly job covering every guest. `all = true` deliberately: a job that
# lists VMIDs silently stops protecting anything created after it was written.
resource "proxmox_backup_job" "nightly" {
  id       = "nightly-all"
  storage  = proxmox_storage_pbs.pbs.id
  schedule = "02:30"
  mode     = "snapshot"
  all      = true
  enabled  = true
  compress = "zstd"

  # Names each snapshot after the guest, so the PBS listing reads as names
  # rather than a wall of VMIDs.
  notes_template = "{{ guestname }}"

  # PBS deduplicates, so keeping 14 restore points costs far less than 14x the
  # guest size - which matters on a 120 GB datastore.
  prune_backups = {
    "keep-daily"   = "7"
    "keep-weekly"  = "4"
    "keep-monthly" = "3"
  }
}
