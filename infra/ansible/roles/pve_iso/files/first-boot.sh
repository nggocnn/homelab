#!/bin/bash
# Runs once, on the first boot of a freshly installed node.
#
# Deliberately minimal: this exists to make the node reachable and safe enough
# for Ansible to take over, not to configure it. Everything else belongs in the
# pve_host role, which is idempotent and re-runnable.
set -euo pipefail
exec > >(tee -a /var/log/first-boot.log) 2>&1
echo "first-boot: starting $(date -Is)"

# The I219-LM offload workaround. Applied here rather than waiting for Ansible
# because a NIC hang before the first playbook run looks like a dead node.
NIC=$(ip -o link show | awk -F': ' '/nic[0-9]|en[a-z]/{print $2; exit}')
if [ -n "${NIC:-}" ]; then
    cat > /etc/systemd/system/pve-nic-offload.service <<EOF
[Unit]
Description=Disable e1000e offload and EEE on ${NIC} (bootstrap)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ethtool -K ${NIC} tso off gso off gro off
ExecStart=/usr/sbin/ethtool --set-eee ${NIC} eee off

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now pve-nic-offload.service || true
    echo "first-boot: offload workaround applied to ${NIC}"
fi

# Enterprise repos 401 without a subscription and break every apt run.
for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
    [ -f "$f" ] && sed -i 's/^Enabled:.*/Enabled: false/; $a Enabled: false' "$f" || true
done
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: true
EOF

echo "first-boot: done $(date -Is) - run playbooks/00-host.yml next"
