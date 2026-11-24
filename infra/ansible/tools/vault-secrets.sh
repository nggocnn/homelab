#!/bin/sh
# Encrypt every secret file in infra/ansible with ansible-vault, in place, so it can be
# committed: git then backs it up, and the vault password is the one thing to remember.
# Already-encrypted files are skipped. The roles read them with lookup('file') and copy,
# which decrypt on the fly, so no role changes.
#
#   tools/vault-secrets.sh            encrypt what is not yet encrypted
#   tools/vault-secrets.sh --check    exit 1 if any is still plaintext (the pre-commit hook)
set -eu
cd "$(dirname "$0")/.."
SECRETS="adguard-password.hash bastion-password.hash beszel-password blocked-sites grafana-password
kuma-password pihole-password pulse-password samba-password telegram-bot-token telegram-chat-id
vm-password netbird-setup-key"
for d in stacks/*/; do [ -f "${d}env" ] && SECRETS="$SECRETS ${d}env"; done

plain=0
for f in $SECRETS; do
    [ -f "$f" ] || continue
    if head -c 14 "$f" | grep -q '^\$ANSIBLE_VAULT'; then
        continue
    fi
    if [ "${1:-}" = "--check" ]; then
        echo "plaintext secret: infra/ansible/$f" >&2
        plain=1
    else
        ansible-vault encrypt "$f"
    fi
done
exit "$plain"
