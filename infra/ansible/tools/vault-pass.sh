#!/bin/sh
# ansible.cfg's vault_password_file. The vault password from a local file, or asked on the
# terminal once per run. The file lives outside the repo and is never committed:
#   install -d -m 700 ~/.config/homelab
#   (umask 077; read -rsp 'Vault password: ' p && printf '%s\n' "$p" > ~/.config/homelab/vault-pass; unset p)
# Keep the same password in the password manager: with the CA keys, it is all a rebuild needs.
f="${HOMELAB_VAULT_PASS_FILE:-$HOME/.config/homelab/vault-pass}"
if [ -r "$f" ]; then
    exec cat "$f"
fi
printf 'Vault password: ' >/dev/tty
stty -echo </dev/tty
IFS= read -r p </dev/tty
stty echo </dev/tty
printf '\n' >/dev/tty
printf '%s\n' "$p"
