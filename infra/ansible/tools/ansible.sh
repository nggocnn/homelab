#!/bin/sh
# Run any Ansible command inside the controller container (tools/Dockerfile), from anywhere:
#   infra/ansible/tools/ansible.sh ansible pve -m ping
#   infra/ansible/tools/ansible.sh ansible-playbook playbooks/00-host.yml --check --diff
#   infra/ansible/tools/ansible.sh ansible-galaxy collection install -r requirements.yml
#
# Mounted: the repo (read-write, so ./collections lands in it, gitignored), ~/.ssh (keys,
# certificates, known_hosts), the vault password file, and the ssh-agent socket, which the
# signing runs need (ssh-add -t 1h ~/.ssh/ca/user_ca ~/.ssh/ca/host_ca first).
set -eu
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
image="${HOMELAB_ANSIBLE_IMAGE:-homelab-ansible}"

if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker build -t "$image" "$repo/infra/ansible/tools"
fi

# "$@" is the command; the image goes in front of it, then each option in front of that.
set -- "$image" "$@"
set -- --rm -i \
    --user "$(id -u):$(id -g)" \
    --network host \
    -v "$repo:/work" \
    -w /work/infra/ansible \
    "$@"
[ -t 0 ] && set -- -t "$@"
[ -d "$HOME/.ssh" ] && set -- -v "$HOME/.ssh:/home/ansible/.ssh" "$@"
pass="${HOMELAB_VAULT_PASS_FILE:-$HOME/.config/homelab/vault-pass}"
[ -r "$pass" ] && set -- -v "$pass:/home/ansible/.config/homelab/vault-pass:ro" "$@"
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    set -- -v "$SSH_AUTH_SOCK:/run/ssh-agent.sock" -e SSH_AUTH_SOCK=/run/ssh-agent.sock "$@"
fi
[ -n "${TS_API_KEY:-}" ] && set -- -e TS_API_KEY "$@"

exec docker run "$@"
