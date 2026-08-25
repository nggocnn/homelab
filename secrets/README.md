# secrets/

Everything in here is SOPS-encrypted with the age key named `pve.nggocnn.io`
(see `.sops.yaml` in the repo root for the recipient).

Encrypted files are safe to commit. Plaintext is not — `.gitignore` blocks the
usual accidents, but that is a backstop, not the rule.

    sops secrets/proxmox-token.sops.yaml      # edit in place
    sops -d secrets/proxmox-token.sops.yaml   # decrypt to stdout

The age PRIVATE key is not in this repo and never should be. It lives in
`~/.config/sops/age/keys.txt` on the workstation, with copies in a cloud password
manager and offline. Lose it and every file here is unrecoverable.
